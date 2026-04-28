// =============================================================================
// src/arith/arith.s  —  Operaciones aritmeticas sobre matrices A/B -> R
//
// Funciones:
//   arith_identity   identidad de A (cuadrada) -> R
//   arith_transpose  A^T -> R
//   arith_add        A + B -> R
//   arith_sub        A - B -> R
//   arith_mul        A * B -> R  (producto matricial, Q32.32)
//
// NOTA Q32.32:
//   Cada elemento es un int64 donde bits[63..32] = parte entera
//   y bits[31..0] = parte fraccionaria.
//   Suma/resta: igual que enteros (ADD/SUB, el formato es lineal).
//   Multiplicacion: (a * b) >> 32  usando MUL + SMULH.
// =============================================================================

.include "include/defines.inc"

.global arith_identity
.global arith_transpose
.global arith_add
.global arith_sub
.global arith_mul

.extern mat_A
.extern mat_B
.extern mat_R
.extern matrix_resize
.extern matrix_validate
.extern io_print_str

// ─── mensajes de error ─────────────────────────────────────────────────────
.section .data

Ea_sq:  .ascii "Error: A debe ser cuadrada para identidad\n"
Ea_sq_l = . - Ea_sq

Ea_em:  .ascii "Error: matriz(ces) sin datos\n"
Ea_em_l = . - Ea_em

Ea_dm:  .ascii "Error: dimensiones incompatibles\n"
Ea_dm_l = . - Ea_dm

// ─── codigo ────────────────────────────────────────────────────────────────
.section .text

// ============================================================
// arith_identity  —  genera identidad n×n de A en R
//
// La identidad tiene 1 en la diagonal y 0 en el resto.
// Como mmap inicializa en cero, solo escribimos los 1s.
//
// offset diagonal: A[k][k] = (k*n + k) * 8 = k*(n+1) * 8
//
// CALLEE-SAVED: x19(desc) x20(n) x21(datos_R) x22(k) x23(ONE)
// ============================================================
arith_identity:
    stp  x29, x30, [sp, #-64]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    stp  x23, xzr, [sp, #48]

    // validar A
    adr  x0, mat_A;  bl matrix_validate
    cmp  x0, #ERR_OK;  bne .aid_empty

    // verificar cuadrada
    adr  x19, mat_A
    ldr  x20, [x19, #DESC_ROWS]    // n = filas
    ldr  x0,  [x19, #DESC_COLS]    // cols
    cmp  x20, x0;  bne .aid_nosq

    // reservar R de n×n
    adr  x0, mat_R;  mov x1, x20;  mov x2, x20
    bl   matrix_resize
    cmp  x0, #ERR_OK;  bne .aid_ret

    adr  x21, mat_R
    ldr  x21, [x21, #DESC_DATA]   // x21 = datos de R (todos en cero)

    // 1.0 en Q32.32 = 1 << 32
    mov  x23, #1;  lsl x23, x23, #Q32_SHIFT

    mov  x22, #0                   // k = 0
.aid_loop:
    cmp  x22, x20;  bge .aid_ok
    // offset = k*(n+1)*8
    add  x0, x20, #1               // n+1
    mul  x0, x22, x0               // k*(n+1)
    lsl  x0, x0, #3                // *8
    str  x23, [x21, x0]            // R[k][k] = 1.0
    add  x22, x22, #1
    b    .aid_loop

.aid_ok:
    mov  x0, #ERR_OK;  b .aid_ret
.aid_empty:
    adr  x0, Ea_em;  mov x1, #Ea_em_l;  bl io_print_str
    mov  x0, #ERR_EMPTY;  b .aid_ret
.aid_nosq:
    adr  x0, Ea_sq;  mov x1, #Ea_sq_l;  bl io_print_str
    mov  x0, #ERR_RANGE

.aid_ret:
    ldp  x23, xzr, [sp, #48]
    ldp  x21, x22, [sp, #32]
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #64
    ret

// ============================================================
// arith_transpose  —  A (m×n) -> R (n×m)
//
// Regla: R[j][i] = A[i][j]
//   offset_A = (i*n + j) * 8
//   offset_R = (j*m + i) * 8   (R tiene m columnas)
//
// CALLEE-SAVED: x19(dA) x20(m) x21(n) x22(dR) x23(i) x24(j) x25(off)
// ============================================================
arith_transpose:
    stp  x29, x30, [sp, #-80]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    stp  x23, x24, [sp, #48]
    stp  x25, xzr, [sp, #64]

    adr  x0, mat_A;  bl matrix_validate
    cmp  x0, #ERR_OK;  bne .atr_empty

    adr  x19, mat_A
    ldr  x20, [x19, #DESC_ROWS]   // m
    ldr  x21, [x19, #DESC_COLS]   // n
    ldr  x19, [x19, #DESC_DATA]

    // R es n×m
    adr  x0, mat_R;  mov x1, x21;  mov x2, x20
    bl   matrix_resize
    cmp  x0, #ERR_OK;  bne .atr_ret

    adr  x22, mat_R;  ldr x22, [x22, #DESC_DATA]

    mov  x23, #0                   // i
.atr_i:
    cmp  x23, x20;  bge .atr_ok
    mov  x24, #0                   // j
.atr_j:
    cmp  x24, x21;  bge .atr_ni

    // leer A[i][j]
    mul  x25, x23, x21             // i*n
    add  x25, x25, x24             // +j
    lsl  x25, x25, #3
    ldr  x0, [x19, x25]

    // escribir R[j][i]  (R tiene m columnas)
    mul  x25, x24, x20             // j*m
    add  x25, x25, x23             // +i
    lsl  x25, x25, #3
    str  x0, [x22, x25]

    add  x24, x24, #1;  b .atr_j
.atr_ni:
    add  x23, x23, #1;  b .atr_i

.atr_ok:
    mov  x0, #ERR_OK;  b .atr_ret
.atr_empty:
    adr  x0, Ea_em;  mov x1, #Ea_em_l;  bl io_print_str
    mov  x0, #ERR_EMPTY

.atr_ret:
    ldp  x25, xzr, [sp, #64]
    ldp  x23, x24, [sp, #48]
    ldp  x21, x22, [sp, #32]
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #80
    ret

// ============================================================
// arith_add / arith_sub  —  R[k] = A[k] ± B[k]
//
// Como A y B estan en row-major, la suma/resta es un bucle
// lineal sobre los ELEMS elementos (no necesitamos i,j).
//
// CALLEE-SAVED: x19(dA) x20(dB) x21(dR) x22(ELEMS) x23(k) x9(modo)
// ============================================================
arith_add:
    mov  x9, #0;  b .as_common    // modo 0 = suma
arith_sub:
    mov  x9, #1                   // modo 1 = resta

.as_common:
    stp  x29, x30, [sp, #-80]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    stp  x23, x9,  [sp, #48]     // guardar modo en pila
    stp  x24, xzr, [sp, #64]

    // validar A y B
    adr  x0, mat_A;  bl matrix_validate
    cmp  x0, #ERR_OK;  bne .as_empty
    adr  x0, mat_B;  bl matrix_validate
    cmp  x0, #ERR_OK;  bne .as_empty

    // cargar dimensiones A
    adr  x19, mat_A
    ldr  x20, [x19, #DESC_ROWS]
    ldr  x21, [x19, #DESC_COLS]
    ldr  x22, [x19, #DESC_ELEMS]
    ldr  x19, [x19, #DESC_DATA]

    // verificar que B tiene las mismas dimensiones
    adr  x24, mat_B
    ldr  x0, [x24, #DESC_ROWS]
    cmp  x0, x20;  bne .as_dim
    ldr  x0, [x24, #DESC_COLS]
    cmp  x0, x21;  bne .as_dim
    ldr  x20, [x24, #DESC_DATA]   // reusar x20 para datos de B
    // ahora: x19=dA  x20=dB  x21=cols  x22=ELEMS

    // reservar R
    // primero recuperar filas de A (las habiamos guardado antes de reusar x20)
    // recalcular: filas = ELEMS / cols
    // mas simple: re-leer del descriptor
    adr  x0, mat_A
    ldr  x24, [x0, #DESC_ROWS]    // x24 = filas de A
    adr  x0, mat_R
    mov  x1, x24
    mov  x2, x21
    bl   matrix_resize
    cmp  x0, #ERR_OK;  bne .as_ret

    adr  x21, mat_R;  ldr x21, [x21, #DESC_DATA]

    // recuperar modo
    ldr  x9, [sp, #56]            // modo estaba en x9 guardado en offset 56

    mov  x23, #0                   // k
.as_loop:
    cmp  x23, x22;  bge .as_ok
    lsl  x0, x23, #3              // offset = k*8
    ldr  x1, [x19, x0]            // A[k]
    ldr  x2, [x20, x0]            // B[k]
    cbnz x9, .as_sub
    add  x1, x1, x2               // A[k] + B[k]
    b    .as_store
.as_sub:
    sub  x1, x1, x2               // A[k] - B[k]
.as_store:
    str  x1, [x21, x0]            // R[k]
    add  x23, x23, #1;  b .as_loop

.as_ok:
    mov  x0, #ERR_OK;  b .as_ret
.as_empty:
    adr  x0, Ea_em;  mov x1, #Ea_em_l;  bl io_print_str
    mov  x0, #ERR_EMPTY;  b .as_ret
.as_dim:
    adr  x0, Ea_dm;  mov x1, #Ea_dm_l;  bl io_print_str
    mov  x0, #ERR_DIM

.as_ret:
    ldp  x24, xzr, [sp, #64]
    ldp  x23, x9,  [sp, #48]
    ldp  x21, x22, [sp, #32]
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #80
    ret

// ============================================================
// arith_mul  —  A (m×n) * B (n×p) -> R (m×p)
//
// R[i][j] = sum_{k=0}^{n-1} A[i][k] * B[k][j]
//
// Multiplicacion Q32.32:
//   (a * 2^32) * (b * 2^32) = (a*b) * 2^64
//   Para obtener (a*b) * 2^32: desplazar 32 bits
//     lo = MUL  xa, xb  (bits 63..0)
//     hi = SMULH xa, xb (bits 127..64, signed)
//     resultado = (hi << 32) | (lo >> 32)
//
// CALLEE-SAVED: x19-x28
// ============================================================
arith_mul:
    stp  x29, x30, [sp, #-96]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    stp  x23, x24, [sp, #48]
    stp  x25, x26, [sp, #64]
    stp  x27, x28, [sp, #80]

    adr  x0, mat_A;  bl matrix_validate
    cmp  x0, #ERR_OK;  bne .am_empty
    adr  x0, mat_B;  bl matrix_validate
    cmp  x0, #ERR_OK;  bne .am_empty

    // dimensiones A: m×n
    adr  x19, mat_A
    ldr  x20, [x19, #DESC_ROWS]   // m
    ldr  x21, [x19, #DESC_COLS]   // n
    ldr  x19, [x19, #DESC_DATA]

    // dimensiones B: n×p
    adr  x22, mat_B
    ldr  x23, [x22, #DESC_ROWS]   // debe == n
    ldr  x24, [x22, #DESC_COLS]   // p
    ldr  x22, [x22, #DESC_DATA]

    // verificar compatibilidad
    cmp  x21, x23;  bne .am_dim

    // reservar R: m×p
    adr  x0, mat_R;  mov x1, x20;  mov x2, x24
    bl   matrix_resize
    cmp  x0, #ERR_OK;  bne .am_ret

    adr  x25, mat_R;  ldr x25, [x25, #DESC_DATA]

    // triple bucle i, j, k
    mov  x26, #0                   // i
.am_i:
    cmp  x26, x20;  bge .am_ok
    mov  x27, #0                   // j
.am_j:
    cmp  x27, x24;  bge .am_ni
    mov  x28, #0                   // acumulador = 0
    mov  x9, #0                    // k
.am_k:
    cmp  x9, x21;  bge .am_store

    // A[i][k]: offset = (i*n + k)*8
    mul  x10, x26, x21
    add  x10, x10, x9
    lsl  x10, x10, #3
    ldr  x11, [x19, x10]

    // B[k][j]: offset = (k*p + j)*8
    mul  x12, x9,  x24
    add  x12, x12, x27
    lsl  x12, x12, #3
    ldr  x13, [x22, x12]

    // A[i][k] * B[k][j] en Q32.32
    mul   x14, x11, x13            // bits bajos
    smulh x15, x11, x13            // bits altos (signed)
    lsr   x14, x14, #32
    lsl   x15, x15, #32
    orr   x14, x15, x14           // resultado Q32.32

    add  x28, x28, x14            // acumular
    add  x9,  x9,  #1;  b .am_k

.am_store:
    // R[i][j]: offset = (i*p + j)*8
    mul  x10, x26, x24
    add  x10, x10, x27
    lsl  x10, x10, #3
    str  x28, [x25, x10]

    add  x27, x27, #1;  b .am_j
.am_ni:
    add  x26, x26, #1;  b .am_i

.am_ok:
    mov  x0, #ERR_OK;  b .am_ret
.am_empty:
    adr  x0, Ea_em;  mov x1, #Ea_em_l;  bl io_print_str
    mov  x0, #ERR_EMPTY;  b .am_ret
.am_dim:
    adr  x0, Ea_dm;  mov x1, #Ea_dm_l;  bl io_print_str
    mov  x0, #ERR_DIM

.am_ret:
    ldp  x27, x28, [sp, #80]
    ldp  x25, x26, [sp, #64]
    ldp  x23, x24, [sp, #48]
    ldp  x21, x22, [sp, #32]
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #96
    ret