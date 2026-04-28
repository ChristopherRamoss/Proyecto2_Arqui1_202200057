// =============================================================================
// src/gauss/gauss.s  —  Eliminacion gaussiana y operaciones avanzadas
//
// Funciones:
//   gauss_eliminate    Bareiss -> triangular superior en R
//   gauss_jordan       Gauss-Jordan -> forma reducida en R
//   gauss_determinant  det(A), resultado en R (1x1) y en x0 (Q32.32)
//   gauss_inverse      inv(A) via Gauss-Jordan aumentada [A|I] -> R
//   gauss_div          A / B = A * inv(B) -> R
//
// ALGORITMO DE BAREISS (gauss_eliminate):
//   Evita divisiones intermedias usando la formula:
//     M[i][j] = (pivot * M[i][j] - M[i][k] * M[k][j]) / pivot_anterior
//   donde pivot_anterior = 1 en el primer paso.
//   Mantiene los valores como enteros el mayor tiempo posible.
// =============================================================================

.include "include/defines.inc"

.global gauss_eliminate
.global gauss_jordan
.global gauss_determinant
.global gauss_inverse
.global gauss_div

.extern mat_A
.extern mat_B
.extern mat_R
.extern matrix_resize
.extern matrix_validate
.extern matrix_free
.extern matrix_copy_desc
.extern arith_mul
.extern io_print_str

// ─── descriptor temporal para copias de trabajo ────────────────────────────
.section .bss
.Gtemp:  .skip DESC_SIZE       // descriptor temporal (copia de A para operar)
.Gaug:   .skip DESC_SIZE       // descriptor para matriz aumentada [A|I]

// ─── mensajes ──────────────────────────────────────────────────────────────
.section .data
Gg_sq:  .ascii "Error: Gauss requiere matriz cuadrada\n"
Gg_sq_l = . - Gg_sq
Gg_em:  .ascii "Error: matriz sin datos\n"
Gg_em_l = . - Gg_em
Gg_sg:  .ascii "Error: matriz singular (det = 0)\n"
Gg_sg_l = . - Gg_sg

// ─── codigo ────────────────────────────────────────────────────────────────
.section .text

// ============================================================
// INTERNO: copiar bloque de datos de SRC a DST
// Ambos ya tienen memoria reservada del mismo tamano.
// IN: x0 = puntero datos DST   x1 = puntero datos SRC   x2 = ELEMS
// Usa: x3 x4 x5 (caller-saved)
// ============================================================
.Lcopy_data:
    mov  x3, #0
.Lcd_loop:
    cmp  x3, x2;  bge .Lcd_done
    lsl  x5, x3, #3
    ldr  x4, [x1, x5]
    str  x4, [x0, x5]
    add  x3, x3, #1;  b .Lcd_loop
.Lcd_done:
    ret

// ============================================================
// INTERNO: intercambiar fila A y fila B en un bloque de datos
// IN: x0 = datos   x1 = fila_a   x2 = fila_b   x3 = COLS
// Usa: x4-x8 (caller-saved)
// ============================================================
.Lswap_rows:
    cmp  x1, x2;  beq .Lsr_done
    mov  x4, #0                    // j = 0
.Lsr_col:
    cmp  x4, x3;  bge .Lsr_done
    // offset_a = (a*COLS + j)*8
    mul  x5, x1, x3;  add x5, x5, x4;  lsl x5, x5, #3
    // offset_b = (b*COLS + j)*8
    mul  x6, x2, x3;  add x6, x6, x4;  lsl x6, x6, #3
    ldr  x7, [x0, x5]
    ldr  x8, [x0, x6]
    str  x8, [x0, x5]
    str  x7, [x0, x6]
    add  x4, x4, #1;  b .Lsr_col
.Lsr_done:
    ret

// ============================================================
// INTERNO: q32_mul_inline  (macro-like helper)
// Multiplica xA * xB en Q32.32 y deja resultado en xRES.
// Usa x_tmp1 y x_tmp2 como temporales.
// EXPANSION: MUL + SMULH + LSR + LSL + ORR
// ============================================================
// (se usa inline con instrucciones directas en cada sitio)

// ============================================================
// gauss_eliminate  —  eliminacion Bareiss de A -> R (triangular superior)
//
// OUT: x0 = ERR_OK o error
//      x1 = signo del determinante (+1 o -1, util para det)
//
// CALLEE-SAVED: x19-x28
// ============================================================
gauss_eliminate:
    stp  x29, x30, [sp, #-96]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    stp  x23, x24, [sp, #48]
    stp  x25, x26, [sp, #64]
    stp  x27, x28, [sp, #80]

    // validar A
    adr  x0, mat_A;  bl matrix_validate
    cmp  x0, #ERR_OK;  bne .ge_empty

    // verificar cuadrada
    adr  x19, mat_A
    ldr  x20, [x19, #DESC_ROWS]   // n
    ldr  x0,  [x19, #DESC_COLS]
    cmp  x20, x0;  bne .ge_nosq

    // copiar A a R para trabajar sobre R sin destruir A
    ldr  x21, [x19, #DESC_ELEMS]
    ldr  x19, [x19, #DESC_DATA]   // x19 = datos de A

    adr  x0, mat_R;  mov x1, x20;  mov x2, x20
    bl   matrix_resize
    cmp  x0, #ERR_OK;  bne .ge_ret

    adr  x22, mat_R;  ldr x22, [x22, #DESC_DATA]  // x22 = datos de R

    // copiar A -> R
    mov  x0, x22;  mov x1, x19;  mov x2, x21
    bl   .Lcopy_data

    // ── Bareiss: k = columna del pivote (0 .. n-1) ──
    mov  x23, #1;  lsl x23, x23, #Q32_SHIFT   // x23 = pivot_ant = 1.0
    mov  x24, #1                               // x24 = signo = +1
    mov  x25, #0                               // x25 = k

.ge_step:
    cmp  x25, x20;  bge .ge_final

    // leer pivote M[k][k]
    mul  x0, x25, x20;  add x0, x0, x25;  lsl x0, x0, #3
    ldr  x26, [x22, x0]                        // x26 = M[k][k]

    // si pivote == 0, buscar fila de intercambio
    asr  x0, x26, #Q32_SHIFT
    cbnz x0, .ge_have_piv

    mov  x27, x25;  add x27, x27, #1           // candidato = k+1
.ge_find:
    cmp  x27, x20;  bge .ge_singular

    mul  x0, x27, x20;  add x0, x0, x25;  lsl x0, x0, #3
    ldr  x26, [x22, x0]
    asr  x0, x26, #Q32_SHIFT
    cbnz x0, .ge_swap
    add  x27, x27, #1;  b .ge_find

.ge_swap:
    mov  x0, x22;  mov x1, x25;  mov x2, x27;  mov x3, x20
    bl   .Lswap_rows
    neg  x24, x24                              // cambiar signo
    // re-leer pivote
    mul  x0, x25, x20;  add x0, x0, x25;  lsl x0, x0, #3
    ldr  x26, [x22, x0]

.ge_have_piv:
    // eliminar debajo del pivote
    mov  x27, x25;  add x27, x27, #1          // i = k+1

.ge_elim_row:
    cmp  x27, x20;  bge .ge_next_step

    // M[i][k]
    mul  x0, x27, x20;  add x0, x0, x25;  lsl x0, x0, #3
    ldr  x28, [x22, x0]                       // x28 = M[i][k]

    // para cada columna j:
    mov  x9, #0
.ge_elim_col:
    cmp  x9, x20;  bge .ge_next_row_e

    // M[k][j]
    mul  x10, x25, x20;  add x10, x10, x9;  lsl x10, x10, #3
    ldr  x11, [x22, x10]                      // M[k][j]

    // M[i][j]
    mul  x12, x27, x20;  add x12, x12, x9;  lsl x12, x12, #3
    ldr  x13, [x22, x12]                      // M[i][j]

    // term1 = pivot * M[i][j]  (Q32.32 mul)
    mul   x14, x26, x13
    smulh x15, x26, x13
    lsr   x14, x14, #32;  lsl x15, x15, #32
    orr   x14, x15, x14                       // pivot * M[i][j]

    // term2 = M[i][k] * M[k][j]  (Q32.32 mul)
    mul   x15, x28, x11
    smulh x16, x28, x11
    lsr   x15, x15, #32;  lsl x16, x16, #32
    orr   x15, x16, x15                       // M[i][k] * M[k][j]

    sub  x14, x14, x15                        // term1 - term2

    // dividir por pivot_anterior (parte entera)
    asr  x15, x14, #Q32_SHIFT                 // numerador entero
    asr  x16, x23, #Q32_SHIFT                 // pivot_ant entero
    cmp  x16, #1;  beq .ge_skip_div
    cmp  x16, #0;  beq .ge_skip_div           // evitar div por 0
    sdiv x15, x15, x16
.ge_skip_div:
    lsl  x14, x15, #Q32_SHIFT                 // reconvertir a Q32.32

    str  x14, [x22, x12]                      // M[i][j] = nuevo valor

    add  x9, x9, #1;  b .ge_elim_col

.ge_next_row_e:
    add  x27, x27, #1;  b .ge_elim_row

.ge_next_step:
    mov  x23, x26                              // pivot_ant = pivot actual
    add  x25, x25, #1;  b .ge_step

.ge_final:
    mov  x0, #ERR_OK
    mov  x1, x24                               // signo del det
    b    .ge_ret

.ge_singular:
    adr  x0, Gg_sg;  mov x1, #Gg_sg_l;  bl io_print_str
    adr  x0, mat_R;  bl matrix_free
    mov  x0, #ERR_SINGULAR;  mov x1, #0;  b .ge_ret

.ge_empty:
    adr  x0, Gg_em;  mov x1, #Gg_em_l;  bl io_print_str
    mov  x0, #ERR_EMPTY;  mov x1, #0;  b .ge_ret

.ge_nosq:
    adr  x0, Gg_sq;  mov x1, #Gg_sq_l;  bl io_print_str
    mov  x0, #ERR_RANGE;  mov x1, #0

.ge_ret:
    ldp  x27, x28, [sp, #80]
    ldp  x25, x26, [sp, #64]
    ldp  x23, x24, [sp, #48]
    ldp  x21, x22, [sp, #32]
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #96
    ret

// ============================================================
// gauss_determinant  —  det(A) usando gauss_eliminate
//
// OUT: x0 = det Q32.32   x1 = ERR_OK o error
// ============================================================
gauss_determinant:
    stp  x29, x30, [sp, #-48]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]

    bl   gauss_eliminate           // mat_R = triangular superior
    cmp  x0, #ERR_OK;  bne .gdet_err
    mov  x19, x1                   // x19 = signo

    // cargar R para leer la diagonal
    adr  x20, mat_R
    ldr  x21, [x20, #DESC_ROWS]   // n
    ldr  x20, [x20, #DESC_DATA]

    // producto de la diagonal
    mov  x22, #1;  lsl x22, x22, #Q32_SHIFT   // acum = 1.0
    mov  x9, #0                                // k

.gdet_prod:
    cmp  x9, x21;  bge .gdet_sign
    mul  x10, x9, x21;  add x10, x10, x9;  lsl x10, x10, #3
    ldr  x11, [x20, x10]               // M[k][k]

    // acum = acum * M[k][k]  Q32.32
    mul   x12, x22, x11
    smulh x13, x22, x11
    lsr   x12, x12, #32;  lsl x13, x13, #32
    orr   x22, x13, x12

    add  x9, x9, #1;  b .gdet_prod

.gdet_sign:
    cmp  x19, #0;  bge .gdet_pos
    neg  x22, x22
.gdet_pos:
    // guardar det en R como 1x1
    adr  x0, mat_R;  mov x1, #1;  mov x2, #1
    bl   matrix_resize
    adr  x0, mat_R;  ldr x0, [x0, #DESC_DATA]
    str  x22, [x0]

    mov  x0, x22;  mov x1, #ERR_OK;  b .gdet_ret

.gdet_err:
    mov  x1, x0;  mov x0, #0

.gdet_ret:
    ldp  x21, x22, [sp, #32]
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #48
    ret

// ============================================================
// gauss_jordan  —  forma reducida por filas (RREF) de A en R
//
// CALLEE-SAVED: x19-x27
// ============================================================
gauss_jordan:
    stp  x29, x30, [sp, #-96]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    stp  x23, x24, [sp, #48]
    stp  x25, x26, [sp, #64]
    stp  x27, xzr, [sp, #80]

    adr  x0, mat_A;  bl matrix_validate
    cmp  x0, #ERR_OK;  bne .gj_empty

    adr  x19, mat_A
    ldr  x20, [x19, #DESC_ROWS]   // n (filas)
    ldr  x21, [x19, #DESC_COLS]   // m (columnas, puede ser >n)
    ldr  x22, [x19, #DESC_ELEMS]
    ldr  x19, [x19, #DESC_DATA]

    // copiar A -> R
    adr  x0, mat_R;  mov x1, x20;  mov x2, x21
    bl   matrix_resize
    cmp  x0, #ERR_OK;  bne .gj_ret

    adr  x23, mat_R;  ldr x23, [x23, #DESC_DATA]
    mov  x0, x23;  mov x1, x19;  mov x2, x22
    bl   .Lcopy_data

    // Gauss-Jordan sobre mat_R
    mov  x24, #0                   // k = columna pivote

.gj_col:
    cmp  x24, x20;  bge .gj_done

    // buscar pivote en columna k, fila >= k
    mov  x25, x24
.gj_find:
    cmp  x25, x20;  bge .gj_next_col   // no hay pivote, saltar columna

    mul  x0, x25, x21;  add x0, x0, x24;  lsl x0, x0, #3
    ldr  x0, [x23, x0]
    asr  x0, x0, #Q32_SHIFT
    cbnz x0, .gj_swap_norm
    add  x25, x25, #1;  b .gj_find

.gj_swap_norm:
    cmp  x25, x24;  beq .gj_norm
    mov  x0, x23;  mov x1, x24;  mov x2, x25;  mov x3, x21
    bl   .Lswap_rows

.gj_norm:
    // leer pivote R[k][k]
    mul  x0, x24, x21;  add x0, x0, x24;  lsl x0, x0, #3
    ldr  x26, [x23, x0]
    asr  x26, x26, #Q32_SHIFT      // x26 = parte entera del pivote

    // normalizar fila k: R[k][j] /= pivote  para todo j
    mov  x9, #0
.gj_norm_col:
    cmp  x9, x21;  bge .gj_elim
    mul  x10, x24, x21;  add x10, x10, x9;  lsl x10, x10, #3
    ldr  x11, [x23, x10]
    asr  x11, x11, #Q32_SHIFT     // parte entera
    cmp  x26, #1;  beq .gj_norm_skip
    sdiv x11, x11, x26
.gj_norm_skip:
    lsl  x11, x11, #Q32_SHIFT
    str  x11, [x23, x10]
    add  x9, x9, #1;  b .gj_norm_col

.gj_elim:
    // eliminar columna k en TODAS las otras filas (no solo abajo)
    mov  x25, #0                   // i
.gj_er:
    cmp  x25, x20;  bge .gj_next_col
    cmp  x25, x24;  beq .gj_er_skip   // saltar fila pivote

    // factor = R[i][k]
    mul  x0, x25, x21;  add x0, x0, x24;  lsl x0, x0, #3
    ldr  x27, [x23, x0]            // x27 = factor Q32.32
    asr  x0, x27, #Q32_SHIFT
    cbz  x0, .gj_er_skip           // si factor==0, nada que hacer

    // R[i][j] -= factor * R[k][j]  para todo j
    mov  x9, #0
.gj_ec:
    cmp  x9, x21;  bge .gj_er_skip
    // R[k][j]
    mul  x10, x24, x21;  add x10, x10, x9;  lsl x10, x10, #3
    ldr  x11, [x23, x10]
    // factor * R[k][j]
    mul   x12, x27, x11
    smulh x13, x27, x11
    lsr   x12, x12, #32;  lsl x13, x13, #32
    orr   x12, x13, x12
    // R[i][j]
    mul  x10, x25, x21;  add x10, x10, x9;  lsl x10, x10, #3
    ldr  x11, [x23, x10]
    sub  x11, x11, x12
    str  x11, [x23, x10]
    add  x9, x9, #1;  b .gj_ec

.gj_er_skip:
    add  x25, x25, #1;  b .gj_er

.gj_next_col:
    add  x24, x24, #1;  b .gj_col

.gj_done:
    mov  x0, #ERR_OK;  b .gj_ret
.gj_empty:
    adr  x0, Gg_em;  mov x1, #Gg_em_l;  bl io_print_str
    mov  x0, #ERR_EMPTY

.gj_ret:
    ldp  x27, xzr, [sp, #80]
    ldp  x25, x26, [sp, #64]
    ldp  x23, x24, [sp, #48]
    ldp  x21, x22, [sp, #32]
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #96
    ret

// ============================================================
// gauss_inverse  —  inv(A) via [A|I] Gauss-Jordan -> R
//
// Construye n×2n: [A | I]
// Aplica G-J hasta obtener [I | inv(A)]
// Extrae columnas n..2n-1 como mat_R
//
// CALLEE-SAVED: x19-x27
// ============================================================
gauss_inverse:
    stp  x29, x30, [sp, #-96]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    stp  x23, x24, [sp, #48]
    stp  x25, x26, [sp, #64]
    stp  x27, xzr, [sp, #80]

    adr  x0, mat_A;  bl matrix_validate
    cmp  x0, #ERR_OK;  bne .ginv_empty

    adr  x19, mat_A
    ldr  x20, [x19, #DESC_ROWS]   // n
    ldr  x0,  [x19, #DESC_COLS]
    cmp  x20, x0;  bne .ginv_nosq
    ldr  x19, [x19, #DESC_DATA]

    // construir [A|I] en .Gaug: n filas, 2n columnas
    lsl  x21, x20, #1              // 2n
    adr  x0, .Gaug;  mov x1, x20;  mov x2, x21
    bl   matrix_resize
    cmp  x0, #ERR_OK;  bne .ginv_ret

    adr  x22, .Gaug;  ldr x22, [x22, #DESC_DATA]

    // llenar [A|I]
    mov  x23, #0                   // i
.ginv_fill_r:
    cmp  x23, x20;  bge .ginv_fill_done
    mov  x24, #0                   // j
.ginv_fill_c:
    cmp  x24, x21;  bge .ginv_fill_nr

    mul  x25, x23, x21;  add x25, x25, x24;  lsl x25, x25, #3  // offset aug

    cmp  x24, x20;  bge .ginv_fill_I   // columna >= n -> parte identidad

    // parte A
    mul  x26, x23, x20;  add x26, x26, x24;  lsl x26, x26, #3
    ldr  x27, [x19, x26]
    str  x27, [x22, x25]
    b    .ginv_fill_nc

.ginv_fill_I:
    sub  x26, x24, x20             // j - n
    cmp  x23, x26                  // i == j-n ?
    bne  .ginv_fill_zero
    mov  x27, #1;  lsl x27, x27, #Q32_SHIFT
    str  x27, [x22, x25]
    b    .ginv_fill_nc
.ginv_fill_zero:
    str  xzr, [x22, x25]

.ginv_fill_nc:
    add  x24, x24, #1;  b .ginv_fill_c
.ginv_fill_nr:
    add  x23, x23, #1;  b .ginv_fill_r

.ginv_fill_done:
    // Gauss-Jordan sobre [A|I] (x22=datos, x20=n, x21=2n)
    mov  x24, #0                   // k

.ginv_gj:
    cmp  x24, x20;  bge .ginv_extract

    // buscar pivote
    mov  x25, x24
.ginv_find:
    cmp  x25, x20;  bge .ginv_singular
    mul  x0, x25, x21;  add x0, x0, x24;  lsl x0, x0, #3
    ldr  x0, [x22, x0]
    asr  x0, x0, #Q32_SHIFT
    cbnz x0, .ginv_swap
    add  x25, x25, #1;  b .ginv_find

.ginv_swap:
    cmp  x25, x24;  beq .ginv_norm2
    mov  x0, x22;  mov x1, x24;  mov x2, x25;  mov x3, x21
    bl   .Lswap_rows

.ginv_norm2:
    mul  x0, x24, x21;  add x0, x0, x24;  lsl x0, x0, #3
    ldr  x26, [x22, x0]
    asr  x26, x26, #Q32_SHIFT      // parte entera del pivote

    mov  x9, #0
.ginv_nm:
    cmp  x9, x21;  bge .ginv_elim2
    mul  x10, x24, x21;  add x10, x10, x9;  lsl x10, x10, #3
    ldr  x11, [x22, x10]
    asr  x11, x11, #Q32_SHIFT
    cmp  x26, #1;  beq .ginv_nm_sk
    cmp  x26, #0;  beq .ginv_nm_sk
    sdiv x11, x11, x26
.ginv_nm_sk:
    lsl  x11, x11, #Q32_SHIFT
    str  x11, [x22, x10]
    add  x9, x9, #1;  b .ginv_nm

.ginv_elim2:
    mov  x25, #0
.ginv_er2:
    cmp  x25, x20;  bge .ginv_next
    cmp  x25, x24;  beq .ginv_er2_sk

    mul  x0, x25, x21;  add x0, x0, x24;  lsl x0, x0, #3
    ldr  x27, [x22, x0]
    asr  x0, x27, #Q32_SHIFT
    cbz  x0, .ginv_er2_sk

    mov  x9, #0
.ginv_ec2:
    cmp  x9, x21;  bge .ginv_er2_sk
    mul  x10, x24, x21;  add x10, x10, x9;  lsl x10, x10, #3;  ldr x11, [x22, x10]
    mul  x12, x27, x11;  smulh x13, x27, x11
    lsr  x12, x12, #32;  lsl x13, x13, #32;  orr x12, x13, x12
    mul  x10, x25, x21;  add x10, x10, x9;  lsl x10, x10, #3
    ldr  x11, [x22, x10];  sub x11, x11, x12;  str x11, [x22, x10]
    add  x9, x9, #1;  b .ginv_ec2

.ginv_er2_sk:
    add  x25, x25, #1;  b .ginv_er2

.ginv_next:
    add  x24, x24, #1;  b .ginv_gj

.ginv_extract:
    // extraer columnas n..2n-1 de .Gaug -> mat_R
    adr  x0, mat_R;  mov x1, x20;  mov x2, x20
    bl   matrix_resize
    cmp  x0, #ERR_OK;  bne .ginv_ret

    adr  x24, mat_R;  ldr x24, [x24, #DESC_DATA]

    mov  x23, #0                   // i
.ginv_ext_r:
    cmp  x23, x20;  bge .ginv_ok
    mov  x25, #0                   // j
.ginv_ext_c:
    cmp  x25, x20;  bge .ginv_ext_nr

    // fuente: aug[i][j+n]
    add  x26, x25, x20             // j+n
    mul  x0, x23, x21;  add x0, x0, x26;  lsl x0, x0, #3
    ldr  x27, [x22, x0]

    // destino: R[i][j]
    mul  x0, x23, x20;  add x0, x0, x25;  lsl x0, x0, #3
    str  x27, [x24, x0]

    add  x25, x25, #1;  b .ginv_ext_c
.ginv_ext_nr:
    add  x23, x23, #1;  b .ginv_ext_r

.ginv_ok:
    adr  x0, .Gaug;  bl matrix_free
    mov  x0, #ERR_OK;  b .ginv_ret

.ginv_singular:
    adr  x0, Gg_sg;  mov x1, #Gg_sg_l;  bl io_print_str
    adr  x0, .Gaug;  bl matrix_free
    mov  x0, #ERR_SINGULAR;  b .ginv_ret

.ginv_empty:
    adr  x0, Gg_em;  mov x1, #Gg_em_l;  bl io_print_str
    mov  x0, #ERR_EMPTY;  b .ginv_ret

.ginv_nosq:
    adr  x0, Gg_sq;  mov x1, #Gg_sq_l;  bl io_print_str
    mov  x0, #ERR_RANGE

.ginv_ret:
    ldp  x27, xzr, [sp, #80]
    ldp  x25, x26, [sp, #64]
    ldp  x23, x24, [sp, #48]
    ldp  x21, x22, [sp, #32]
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #96
    ret

// ============================================================
// gauss_div  —  A / B = A * inv(B) -> R
//
// PROCESO:
//   1. Guardar descriptor de B en la pila
//   2. Calcular inv(B) via gauss_inverse (mat_A debe ser B)
//      Para lograrlo: copiar descriptor de B sobre mat_A temporalmente,
//      calcular inversa -> R, restaurar mat_A, copiar R -> mat_B,
//      multiplicar A * mat_B_nuevo -> R
//
// Esta funcion es compleja por la gestion de descriptores.
// Usa descriptores temporales en la pila (64 bytes cada uno).
// ============================================================
gauss_div:
    stp  x29, x30, [sp, #-160]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    // reservar espacio para dos descriptores temporales en la pila
    // [sp+64..sp+127] = copia del descriptor de A
    // [sp+128..sp+191] -- no, usaremos .Gtemp

    // validar A y B
    adr  x0, mat_A;  bl matrix_validate
    cmp  x0, #ERR_OK;  bne .gdiv_empty
    adr  x0, mat_B;  bl matrix_validate
    cmp  x0, #ERR_OK;  bne .gdiv_empty

    // ── copiar descriptor de A a .Gtemp ──
    adr  x19, mat_A
    adr  x20, .Gtemp
    // copiar 64 bytes (8 campos de 8 bytes)
    ldp  x21, x22, [x19, #0];   stp x21, x22, [x20, #0]
    ldp  x21, x22, [x19, #16];  stp x21, x22, [x20, #16]
    ldp  x21, x22, [x19, #32];  stp x21, x22, [x20, #32]
    ldp  x21, x22, [x19, #48];  stp x21, x22, [x20, #48]

    // ── poner B en mat_A (para que gauss_inverse calcule inv(B)) ──
    adr  x20, mat_B
    ldp  x21, x22, [x20, #0];   stp x21, x22, [x19, #0]
    ldp  x21, x22, [x20, #16];  stp x21, x22, [x19, #16]
    ldp  x21, x22, [x20, #32];  stp x21, x22, [x19, #32]
    ldp  x21, x22, [x20, #48];  stp x21, x22, [x19, #48]

    // ── calcular inv(mat_A=B) -> mat_R ──
    bl   gauss_inverse
    mov  x21, x0                  // x21 = resultado

    // ── restaurar mat_A desde .Gtemp ──
    adr  x19, mat_A
    adr  x20, .Gtemp
    ldp  x22, x23, [x20, #0];   stp x22, x23, [x19, #0]
    ldp  x22, x23, [x20, #16];  stp x22, x23, [x19, #16]
    ldp  x22, x23, [x20, #32];  stp x22, x23, [x19, #32]
    ldp  x22, x23, [x20, #48];  stp x22, x23, [x19, #48]
    // limpiar .Gtemp
    str  xzr, [x20, #DESC_STATUS]

    cmp  x21, #ERR_OK;  bne .gdiv_ret

    // ── mover R (=inv(B)) a mat_B ──
    // liberar mat_B actual
    adr  x0, mat_B;  bl matrix_free
    // matrix_copy_desc: DST=mat_B, SRC=mat_R
    adr  x0, mat_B
    adr  x1, mat_R
    bl   matrix_copy_desc

    // ── multiplicar A * mat_B(=inv(B)) -> mat_R ──
    bl   arith_mul
    // mat_B ahora tiene inv(B) pero arith_mul no lo modifica
    // Nota: mat_B queda apuntando a inv(B); el usuario puede liberarlo
    // con "Liberar memoria" del menu.

    b    .gdiv_ret

.gdiv_empty:
    adr  x0, Gg_em;  mov x1, #Gg_em_l;  bl io_print_str
    mov  x0, #ERR_EMPTY

.gdiv_ret:
    ldp  x21, x22, [sp, #32]
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #160
    ret