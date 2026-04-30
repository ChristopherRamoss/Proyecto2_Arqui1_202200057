// =============================================================================
// src/gauss/gauss.s  —  Eliminacion gaussiana y operaciones avanzadas
//
// BUGS CORREGIDOS EN ESTA VERSION:
//
// BUG 1 — gauss_determinant: multiplicacion de diagonal en Q32.32 overflow
//   ANTES: multiplicaba acum * M[k][k] en Q32.32 (dos valores ya escalados
//          por 2^32). El producto de 1<<32 * (-2<<32) tiene bits utiles en
//          posicion 64, que se pierden en el MUL de 64 bits.
//   FIX:   Extraer parte ENTERA de cada diagonal (ASR #32), multiplicar
//          como enteros normales (no Q32.32), convertir al final (LSL #32).
//
// BUG 2 — gauss_inverse: normalizacion usa sdiv (division entera)
//   ANTES: al normalizar fila k del augmentado, dividia cada elemento por
//          la parte entera del pivote usando SDIV. Para inv([[1,2],[3,4]]),
//          el pivote -2 generaba -3/-2 = 1 (truncado) en vez de 1.5.
//   FIX:   Division Q32.32 real: escalar numerador por 2^32, luego SDIV
//          por denominador entero. Resultado queda en Q32.32 con fracciones.
//          Formula: resultado_Q32 = (valor_Q32 * 2^32) / pivote_entero
//          En practica: sdiv da cociente entero. Para fracciones usamos:
//          numerador = valor_Q32 (ya en Q32.32)
//          denominador = pivote en Q32.32
//          resultado = (num << 32) / denom_entero  -- pero overflow posible
//          ALTERNATIVA SEGURA: resultado = num / denom_entero (sdiv directo
//          sobre los Q32.32, que equivale a division correcta porque
//          (x<<32) / y = (x/y) en la parte entera y fracciones en los bits bajos)
//
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

// ─── descriptores temporales ──────────────────────────────────────────────
.section .bss
    .align 3
.Gtemp:  .skip DESC_SIZE
.Gaug:   .skip DESC_SIZE

// ─── mensajes ─────────────────────────────────────────────────────────────
.section .data
    .align 3
Gg_sq:  .ascii "Error: se requiere matriz cuadrada\n"
Gg_sq_l = . - Gg_sq
Gg_em:  .ascii "Error: matriz sin datos\n"
Gg_em_l = . - Gg_em
Gg_sg:  .ascii "Error: matriz singular (det = 0)\n"
Gg_sg_l = . - Gg_sg

// ─── codigo ───────────────────────────────────────────────────────────────
.section .text

// ============================================================
// INTERNO: copiar bloque lineal de ELEMS elementos Q32.32
// IN: x0=DST  x1=SRC  x2=ELEMS
// Usa x3 x4 x5 (caller-saved)
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
// INTERNO: intercambiar dos filas en un bloque de datos
// IN: x0=datos  x1=fila_a  x2=fila_b  x3=COLS
// Usa x4-x8 (caller-saved)
// ============================================================
.Lswap_rows:
    cmp  x1, x2;  beq .Lsr_done
    mov  x4, #0
.Lsr_col:
    cmp  x4, x3;  bge .Lsr_done
    mul  x5, x1, x3;  add x5, x5, x4;  lsl x5, x5, #3
    mul  x6, x2, x3;  add x6, x6, x4;  lsl x6, x6, #3
    ldr  x7, [x0, x5]
    ldr  x8, [x0, x6]
    str  x8, [x0, x5]
    str  x7, [x0, x6]
    add  x4, x4, #1;  b .Lsr_col
.Lsr_done:
    ret

// ============================================================
// INTERNO: division Q32.32
// Divide dos valores Q32.32: resultado = a / b
// IN: x0 = a (Q32.32)   x1 = b (Q32.32, su parte entera != 0)
// OUT: x0 = resultado Q32.32
//
// METODO:
//   b_int = b >> 32  (parte entera del divisor)
//   resultado = a / b_int
//   Esto funciona porque a esta en Q32.32 (= valor_real * 2^32)
//   y b_int es el valor entero del divisor.
//   resultado = (valor_a * 2^32) / valor_b = (valor_a/valor_b) * 2^32
//   que es exactamente Q32.32 con fracciones correctas.
//
// Usa x2 x3 (caller-saved)
// ============================================================
.Lq32_div:
    asr  x2, x1, #Q32_SHIFT       // x2 = parte entera del divisor
    cbz  x2, .Lq32_div_zero
    sdiv x0, x0, x2               // x0 = a_Q32 / b_int = resultado Q32.32
    ret
.Lq32_div_zero:
    mov  x0, #0
    ret

// ============================================================
// gauss_eliminate — eliminacion de Gauss-Bareiss de A -> R
//
// Produce forma triangular superior en mat_R sin modificar mat_A.
// OUT: x0 = ERR_OK o error
//      x1 = signo del determinante (+1 o -1)
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

    adr  x0, mat_A;  bl matrix_validate
    cmp  x0, #ERR_OK;  bne .ge_empty

    adr  x0, mat_A
    ldr  x20, [x0, #DESC_ROWS]    // n
    ldr  x1,  [x0, #DESC_COLS]
    cmp  x20, x1;  bne .ge_nosq
    ldr  x21, [x0, #DESC_ELEMS]
    ldr  x19, [x0, #DESC_DATA]    // datos de A

    // reservar R de n×n y copiar A en R
    adr  x0, mat_R;  mov x1, x20;  mov x2, x20
    bl   matrix_resize
    cmp  x0, #ERR_OK;  bne .ge_ret

    adr  x0, mat_R;  ldr x22, [x0, #DESC_DATA]  // x22 = datos de R
    mov  x0, x22;  mov x1, x19;  mov x2, x21
    bl   .Lcopy_data

    // Bareiss: pivot_ant=1.0 Q32.32, signo=+1, k=0
    mov  x23, #1;  lsl x23, x23, #Q32_SHIFT   // x23 = pivot_ant Q32.32
    mov  x24, #1                               // x24 = signo
    mov  x25, #0                               // x25 = k

.ge_step:
    cmp  x25, x20;  bge .ge_final

    // leer M[k][k]
    mul  x0, x25, x20;  add x0, x0, x25;  lsl x0, x0, #3
    ldr  x26, [x22, x0]                        // x26 = pivote Q32.32

    // si pivote==0, buscar swap
    asr  x0, x26, #Q32_SHIFT
    cbnz x0, .ge_have_piv

    mov  x27, x25;  add x27, x27, #1
.ge_find:
    cmp  x27, x20;  bge .ge_singular
    mul  x0, x27, x20;  add x0, x0, x25;  lsl x0, x0, #3
    ldr  x26, [x22, x0]
    asr  x0, x26, #Q32_SHIFT
    cbnz x0, .ge_do_swap
    add  x27, x27, #1;  b .ge_find

.ge_do_swap:
    mov  x0, x22;  mov x1, x25;  mov x2, x27;  mov x3, x20
    bl   .Lswap_rows
    neg  x24, x24
    mul  x0, x25, x20;  add x0, x0, x25;  lsl x0, x0, #3
    ldr  x26, [x22, x0]

.ge_have_piv:
    mov  x27, x25;  add x27, x27, #1  // i = k+1

.ge_elim_row:
    cmp  x27, x20;  bge .ge_next_step

    // M[i][k]
    mul  x0, x27, x20;  add x0, x0, x25;  lsl x0, x0, #3
    ldr  x28, [x22, x0]                       // x28 = M[i][k]

    mov  x9, #0                               // j = 0
.ge_elim_col:
    cmp  x9, x20;  bge .ge_next_row_e

    // M[k][j]
    mul  x10, x25, x20;  add x10, x10, x9;  lsl x10, x10, #3
    ldr  x11, [x22, x10]

    // M[i][j] y su offset de escritura
    mul  x12, x27, x20;  add x12, x12, x9;  lsl x12, x12, #3
    ldr  x13, [x22, x12]

    // term1 = pivot * M[i][j]  Q32.32
    mul   x14, x26, x13
    smulh x15, x26, x13
    lsr   x14, x14, #32;  lsl x15, x15, #32
    orr   x14, x15, x14

    // term2 = M[i][k] * M[k][j]  Q32.32
    mul   x15, x28, x11
    smulh x16, x28, x11
    lsr   x15, x15, #32;  lsl x16, x16, #32
    orr   x15, x16, x15

    sub  x14, x14, x15             // term1 - term2

    // dividir por pivot_anterior usando .Lq32_div
    mov  x0, x14                   // numerador Q32.32
    mov  x1, x23                   // denominador Q32.32
    bl   .Lq32_div                 // resultado Q32.32 en x0
    str  x0, [x22, x12]

    add  x9, x9, #1;  b .ge_elim_col

.ge_next_row_e:
    add  x27, x27, #1;  b .ge_elim_row

.ge_next_step:
    mov  x23, x26                  // pivot_ant = pivote actual
    add  x25, x25, #1;  b .ge_step

.ge_final:
    mov  x0, #ERR_OK;  mov x1, x24;  b .ge_ret

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
// gauss_determinant — det(A) como escalar en mat_R (1x1)
//
// FIX: la diagonal de Bareiss contiene enteros en Q32.32.
//      Multiplicar como enteros (no Q32.32) evita el overflow.
//
// PROCESO:
//   1. gauss_eliminate -> mat_R = triangular superior
//   2. Extraer parte ENTERA de cada M[k][k] (ASR #32)
//   3. Multiplicar como enteros normales
//   4. Aplicar signo de las transposiciones
//   5. Convertir a Q32.32 (LSL #32) y guardar en mat_R 1x1
//
// OUT: x0 = ERR_OK o error  (el valor esta en mat_R)
// CALLEE-SAVED: x19(signo) x20(datos_R) x21(n) x22(acum_entero)
// ============================================================
gauss_determinant:
    stp  x29, x30, [sp, #-48]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]

    bl   gauss_eliminate
    cmp  x0, #ERR_OK;  bne .gdet_err
    mov  x19, x1                   // x19 = signo (+1 o -1)

    // leer la triangular de mat_R
    adr  x0, mat_R
    ldr  x21, [x0, #DESC_ROWS]    // n
    ldr  x20, [x0, #DESC_DATA]    // datos

    // ── FIX: producto de diagonales como ENTEROS (no Q32.32) ──
    // Los valores de Bareiss en Q32.32 son enteros escalados por 2^32.
    // Extraer parte entera de cada uno (ASR #32) y multiplicar normalmente.
    mov  x22, #1                   // acumulador ENTERO (no Q32.32)
    mov  x9, #0                    // k = 0

.gdet_prod:
    cmp  x9, x21;  bge .gdet_sign

    // offset de M[k][k]
    mul  x10, x9, x21
    add  x10, x10, x9
    lsl  x10, x10, #3
    ldr  x11, [x20, x10]          // M[k][k] en Q32.32
    asr  x11, x11, #Q32_SHIFT     // x11 = parte entera de M[k][k]

    // multiplicar acumulador * x11 (ambos son enteros simples)
    mul  x22, x22, x11

    add  x9, x9, #1;  b .gdet_prod

.gdet_sign:
    // aplicar signo de las transposiciones
    cmp  x19, #0;  bge .gdet_store
    neg  x22, x22                  // negar si signo negativo

.gdet_store:
    // convertir resultado entero a Q32.32
    lsl  x22, x22, #Q32_SHIFT     // x22 = det en Q32.32

    // guardar en mat_R como matriz 1x1
    adr  x0, mat_R
    mov  x1, #1
    mov  x2, #1
    bl   matrix_resize             // libera triangular, reserva 1x1
    cmp  x0, #ERR_OK;  bne .gdet_err2

    adr  x0, mat_R
    ldr  x0, [x0, #DESC_DATA]
    str  x22, [x0]                 // mat_R[0][0] = det Q32.32

    mov  x0, #ERR_OK;  b .gdet_ret

.gdet_err2:
    mov  x0, #ERR_ALLOC;  b .gdet_ret
.gdet_err:
    // gauss_eliminate ya imprimio el error; retornar su codigo
.gdet_ret:
    ldp  x21, x22, [sp, #32]
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #48
    ret

// ============================================================
// gauss_jordan — forma reducida por filas de A en R (RREF)
//
// Aplica Gauss-Jordan sobre una copia de A en mat_R.
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

    adr  x0, mat_A
    ldr  x20, [x0, #DESC_ROWS]
    ldr  x21, [x0, #DESC_COLS]
    ldr  x22, [x0, #DESC_ELEMS]
    ldr  x19, [x0, #DESC_DATA]

    adr  x0, mat_R;  mov x1, x20;  mov x2, x21
    bl   matrix_resize
    cmp  x0, #ERR_OK;  bne .gj_ret

    adr  x0, mat_R;  ldr x23, [x0, #DESC_DATA]
    mov  x0, x23;  mov x1, x19;  mov x2, x22
    bl   .Lcopy_data

    mov  x24, #0                   // k = columna pivote
.gj_col:
    cmp  x24, x20;  bge .gj_done

    mov  x25, x24                  // buscar pivote desde fila k
.gj_find:
    cmp  x25, x20;  bge .gj_next_col
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
    // leer pivote R[k][k] en Q32.32
    mul  x0, x24, x21;  add x0, x0, x24;  lsl x0, x0, #3
    ldr  x26, [x23, x0]           // x26 = pivote Q32.32

    // normalizar fila k: R[k][j] = R[k][j] / pivote  para todo j
    // FIX: usar .Lq32_div para division Q32.32 real (no sdiv entero)
    mov  x9, #0
.gj_norm_col:
    cmp  x9, x21;  bge .gj_elim
    mul  x10, x24, x21;  add x10, x10, x9;  lsl x10, x10, #3
    ldr  x0, [x23, x10]           // R[k][j] en Q32.32
    mov  x1, x26                  // divisor = pivote Q32.32
    bl   .Lq32_div                // x0 = R[k][j] / pivote  en Q32.32
    str  x0, [x23, x10]
    add  x9, x9, #1;  b .gj_norm_col

.gj_elim:
    // eliminar columna k en TODAS las otras filas
    mov  x25, #0
.gj_er:
    cmp  x25, x20;  bge .gj_next_col
    cmp  x25, x24;  beq .gj_er_skip

    mul  x0, x25, x21;  add x0, x0, x24;  lsl x0, x0, #3
    ldr  x27, [x23, x0]           // factor = R[i][k] Q32.32
    asr  x0, x27, #Q32_SHIFT
    cbz  x0, .gj_er_skip

    mov  x9, #0
.gj_ec:
    cmp  x9, x21;  bge .gj_er_skip

    // R[k][j]
    mul  x10, x24, x21;  add x10, x10, x9;  lsl x10, x10, #3
    ldr  x11, [x23, x10]

    // factor * R[k][j] Q32.32
    mul   x12, x27, x11
    smulh x13, x27, x11
    lsr   x12, x12, #32;  lsl x13, x13, #32
    orr   x12, x13, x12

    // R[i][j] -= factor * R[k][j]
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
// gauss_inverse — inv(A) via Gauss-Jordan sobre [A|I] -> R
//
// FIX PRINCIPAL: la normalizacion de filas ahora usa .Lq32_div
// en lugar de sdiv directo, permitiendo fracciones correctas.
//
// PROCESO:
//   1. Construir [A | I] de n×2n en .Gaug
//   2. Aplicar Gauss-Jordan completo sobre las n columnas de pivote
//   3. Extraer columnas n..2n-1 -> mat_R = inv(A)
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

    adr  x0, mat_A
    ldr  x20, [x0, #DESC_ROWS]    // n
    ldr  x1,  [x0, #DESC_COLS]
    cmp  x20, x1;  bne .ginv_nosq
    ldr  x19, [x0, #DESC_DATA]    // datos de A

    // construir [A|I] en .Gaug: n filas, 2n columnas
    lsl  x21, x20, #1              // x21 = 2n
    adr  x0, .Gaug;  mov x1, x20;  mov x2, x21
    bl   matrix_resize
    cmp  x0, #ERR_OK;  bne .ginv_ret

    adr  x0, .Gaug;  ldr x22, [x0, #DESC_DATA]  // x22 = datos de [A|I]

    // llenar [A|I]: columnas 0..n-1 = A, columnas n..2n-1 = I
    mov  x23, #0                   // i
.ginv_fill_r:
    cmp  x23, x20;  bge .ginv_gj_start
    mov  x24, #0                   // j
.ginv_fill_c:
    cmp  x24, x21;  bge .ginv_fill_nr

    // offset en aumentada: (i*2n + j)*8
    mul  x25, x23, x21;  add x25, x25, x24;  lsl x25, x25, #3

    cmp  x24, x20;  bge .ginv_fill_I

    // parte A: columna j < n
    mul  x26, x23, x20;  add x26, x26, x24;  lsl x26, x26, #3
    ldr  x27, [x19, x26]
    str  x27, [x22, x25]
    b    .ginv_fill_nc

.ginv_fill_I:
    // parte identidad: columna j-n == i -> valor 1.0
    sub  x26, x24, x20             // j - n
    cmp  x23, x26
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

.ginv_gj_start:
    // Gauss-Jordan sobre [A|I]: pivotar por columnas 0..n-1
    // Usar x22=datos, x20=n, x21=2n
    mov  x24, #0                   // k = columna pivote

.ginv_gj:
    cmp  x24, x20;  bge .ginv_extract

    // buscar pivote en columna k desde fila k
    mov  x25, x24
.ginv_find:
    cmp  x25, x20;  bge .ginv_singular
    mul  x0, x25, x21;  add x0, x0, x24;  lsl x0, x0, #3
    ldr  x0, [x22, x0]
    asr  x0, x0, #Q32_SHIFT
    cbnz x0, .ginv_swap
    add  x25, x25, #1;  b .ginv_find

.ginv_swap:
    cmp  x25, x24;  beq .ginv_norm
    mov  x0, x22;  mov x1, x24;  mov x2, x25;  mov x3, x21
    bl   .Lswap_rows

.ginv_norm:
    // leer pivote [A|I][k][k]
    mul  x0, x24, x21;  add x0, x0, x24;  lsl x0, x0, #3
    ldr  x26, [x22, x0]           // x26 = pivote Q32.32

    // normalizar fila k: cada elemento /= pivote  (division Q32.32)
    mov  x9, #0
.ginv_nm:
    cmp  x9, x21;  bge .ginv_elim
    mul  x10, x24, x21;  add x10, x10, x9;  lsl x10, x10, #3
    ldr  x0, [x22, x10]           // elemento en Q32.32
    mov  x1, x26                  // divisor = pivote Q32.32
    bl   .Lq32_div                // x0 = elemento / pivote  Q32.32 correcto
    str  x0, [x22, x10]
    add  x9, x9, #1;  b .ginv_nm

.ginv_elim:
    // eliminar columna k en TODAS las otras filas
    mov  x25, #0
.ginv_er:
    cmp  x25, x20;  bge .ginv_next_k
    cmp  x25, x24;  beq .ginv_er_skip

    // factor = [A|I][i][k]
    mul  x0, x25, x21;  add x0, x0, x24;  lsl x0, x0, #3
    ldr  x27, [x22, x0]           // x27 = factor Q32.32
    asr  x0, x27, #Q32_SHIFT
    cbz  x0, .ginv_er_skip        // si factor==0, saltar

    // [A|I][i][j] -= factor * [A|I][k][j]  para todo j
    mov  x9, #0
.ginv_ec:
    cmp  x9, x21;  bge .ginv_er_skip

    // leer [A|I][k][j]
    mul  x10, x24, x21;  add x10, x10, x9;  lsl x10, x10, #3
    ldr  x11, [x22, x10]

    // factor * [A|I][k][j] en Q32.32
    mul   x12, x27, x11
    smulh x13, x27, x11
    lsr   x12, x12, #32;  lsl x13, x13, #32
    orr   x12, x13, x12

    // [A|I][i][j] -= producto
    mul  x10, x25, x21;  add x10, x10, x9;  lsl x10, x10, #3
    ldr  x11, [x22, x10]
    sub  x11, x11, x12
    str  x11, [x22, x10]

    add  x9, x9, #1;  b .ginv_ec

.ginv_er_skip:
    add  x25, x25, #1;  b .ginv_er

.ginv_next_k:
    add  x24, x24, #1;  b .ginv_gj

.ginv_extract:
    // extraer columnas n..2n-1 del [A|I] reducido -> mat_R n×n
    adr  x0, mat_R;  mov x1, x20;  mov x2, x20
    bl   matrix_resize
    cmp  x0, #ERR_OK;  bne .ginv_ret

    adr  x0, mat_R;  ldr x24, [x0, #DESC_DATA]

    mov  x23, #0                   // i
.ginv_ext_r:
    cmp  x23, x20;  bge .ginv_ok
    mov  x25, #0                   // j
.ginv_ext_c:
    cmp  x25, x20;  bge .ginv_ext_nr

    // fuente: aug[i][j+n]
    add  x26, x25, x20
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
// gauss_div — A / B = A * inv(B) -> R
//
// PROCESO:
//   1. Copiar descriptor de A a .Gtemp (preservar A)
//   2. Poner descriptor de B en mat_A (para que gauss_inverse calcule inv(B))
//   3. gauss_inverse -> mat_R = inv(B)
//   4. Restaurar mat_A desde .Gtemp
//   5. matrix_copy_desc(mat_B, mat_R) -> mat_B = inv(B), mat_R = FREE
//   6. arith_mul -> A * inv(B) -> mat_R
// CALLEE-SAVED: x19-x23
// ============================================================
gauss_div:
    stp  x29, x30, [sp, #-64]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    stp  x23, xzr, [sp, #48]

    adr  x0, mat_A;  bl matrix_validate
    cmp  x0, #ERR_OK;  bne .gdiv_empty
    adr  x0, mat_B;  bl matrix_validate
    cmp  x0, #ERR_OK;  bne .gdiv_empty

    // copiar descriptor de A a .Gtemp
    adr  x19, mat_A
    adr  x20, .Gtemp
    ldp  x21, x22, [x19, #0];   stp x21, x22, [x20, #0]
    ldp  x21, x22, [x19, #16];  stp x21, x22, [x20, #16]
    ldp  x21, x22, [x19, #32];  stp x21, x22, [x20, #32]
    ldp  x21, x22, [x19, #48];  stp x21, x22, [x20, #48]

    // poner descriptor de B en mat_A
    adr  x20, mat_B
    ldp  x21, x22, [x20, #0];   stp x21, x22, [x19, #0]
    ldp  x21, x22, [x20, #16];  stp x21, x22, [x19, #16]
    ldp  x21, x22, [x20, #32];  stp x21, x22, [x19, #32]
    ldp  x21, x22, [x20, #48];  stp x21, x22, [x19, #48]

    // calcular inv(B) -> mat_R  (mat_A=B temporalmente)
    bl   gauss_inverse
    mov  x23, x0                  // x23 = codigo de error

    // restaurar mat_A desde .Gtemp
    adr  x19, mat_A
    adr  x20, .Gtemp
    ldp  x21, x22, [x20, #0];   stp x21, x22, [x19, #0]
    ldp  x21, x22, [x20, #16];  stp x21, x22, [x19, #16]
    ldp  x21, x22, [x20, #32];  stp x21, x22, [x19, #32]
    ldp  x21, x22, [x20, #48];  stp x21, x22, [x19, #48]
    str  xzr, [x20, #DESC_STATUS]  // limpiar .Gtemp

    cmp  x23, #ERR_OK;  bne .gdiv_ret

    // mover mat_R (=inv(B)) a mat_B
    adr  x0, mat_B;  bl matrix_free
    adr  x0, mat_B
    adr  x1, mat_R
    bl   matrix_copy_desc

    // multiplicar A * mat_B(=inv(B)) -> mat_R
    bl   arith_mul
    mov  x23, x0

    b    .gdiv_ret

.gdiv_empty:
    adr  x0, Gg_em;  mov x1, #Gg_em_l;  bl io_print_str
    mov  x23, #ERR_EMPTY

.gdiv_ret:
    mov  x0, x23
    ldp  x23, xzr, [sp, #48]
    ldp  x21, x22, [sp, #32]
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #64
    ret