// =============================================================================
// src/arith/arith.s  —  Operaciones aritmeticas sobre matrices A/B -> R
//
// Funciones:
//   arith_identity   identidad de A (cuadrada) -> R
//   arith_transpose  A^T -> R
//   arith_add        A + B -> R
//   arith_sub        A - B -> R
//   arith_mul        A * B -> R  (producto matricial, Q32.32)
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

// ─── mensajes en .data ────────────────────────────────────────────────────
.section .data
    .align 3

Ea_sq:  .ascii "Error: A debe ser cuadrada para identidad\n"
Ea_sq_l = . - Ea_sq

Ea_em:  .ascii "Error: matriz(ces) sin datos\n"
Ea_em_l = . - Ea_em

Ea_dm:  .ascii "Error: dimensiones incompatibles\n"
Ea_dm_l = . - Ea_dm

// ─── codigo ───────────────────────────────────────────────────────────────
.section .text

// ============================================================
// arith_identity — genera identidad n×n de A en R
//
// La identidad tiene 1.0 en la diagonal y 0.0 en el resto.
// mmap ya inicializa en cero, por lo que SOLO escribimos los 1s.
//
// FIX: ya no llamamos io_print_int para los indices (eso causaba
//      el crash). El prompt de ingreso de datos NO es responsabilidad
//      de esta funcion; solo genera la matriz resultado.
//
// offset del elemento diagonal k: (k*n + k)*8 = k*(n+1)*8
//
// CALLEE-SAVED: x19(n) x20(datos_R) x21(k) x22(ONE_Q32)
// ============================================================
arith_identity:
    stp  x29, x30, [sp, #-48]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]

    // validar A
    adr  x0, mat_A
    bl   matrix_validate
    cmp  x0, #ERR_OK;  bne .aid_empty

    // verificar cuadrada: ROWS == COLS
    adr  x0, mat_A
    ldr  x19, [x0, #DESC_ROWS]    // x19 = n
    ldr  x1,  [x0, #DESC_COLS]
    cmp  x19, x1;  bne .aid_nosq

    // reservar R de n×n (mmap pone todo en cero automaticamente)
    adr  x0, mat_R
    mov  x1, x19
    mov  x2, x19
    bl   matrix_resize
    cmp  x0, #ERR_OK;  bne .aid_ret

    // obtener puntero a datos de R
    adr  x0, mat_R
    ldr  x20, [x0, #DESC_DATA]    // x20 = datos de R

    // preparar 1.0 en Q32.32: valor = 1 << 32
    mov  x22, #1
    lsl  x22, x22, #Q32_SHIFT     // x22 = 0x0000000100000000

    // escribir 1.0 en cada posicion diagonal R[k][k]
    mov  x21, #0                   // k = 0
.aid_loop:
    cmp  x21, x19;  bge .aid_ok   // k >= n -> terminar

    // offset = k*(n+1)*8
    // Calculo: idx = k*n + k = k*(n+1)
    add  x0, x19, #1               // x0 = n+1
    mul  x0, x21, x0               // x0 = k*(n+1)
    lsl  x0, x0, #3                // x0 = k*(n+1)*8  (offset en bytes)
    str  x22, [x20, x0]            // R[k][k] = 1.0 en Q32.32

    add  x21, x21, #1
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
    ldp  x21, x22, [sp, #32]
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #48
    ret

// ============================================================
// arith_transpose — A (m×n) -> R (n×m)
//
// Regla: R[j][i] = A[i][j]
//   offset_A = (i*n + j) * 8
//   offset_R = (j*m + i) * 8   <- R tiene m columnas (original COLS de A)
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

    adr  x0, mat_A
    bl   matrix_validate
    cmp  x0, #ERR_OK;  bne .atr_empty

    adr  x0, mat_A
    ldr  x20, [x0, #DESC_ROWS]    // m
    ldr  x21, [x0, #DESC_COLS]    // n
    ldr  x19, [x0, #DESC_DATA]    // datos de A

    // R es n×m (intercambiamos filas y columnas)
    adr  x0, mat_R
    mov  x1, x21                   // filas de R = n
    mov  x2, x20                   // cols de R  = m
    bl   matrix_resize
    cmp  x0, #ERR_OK;  bne .atr_ret

    adr  x0, mat_R
    ldr  x22, [x0, #DESC_DATA]    // datos de R

    mov  x23, #0                   // i = 0
.atr_i:
    cmp  x23, x20;  bge .atr_ok
    mov  x24, #0                   // j = 0
.atr_j:
    cmp  x24, x21;  bge .atr_ni

    // leer A[i][j]: offset = (i*n + j)*8
    mul  x25, x23, x21
    add  x25, x25, x24
    lsl  x25, x25, #3
    ldr  x0, [x19, x25]

    // escribir R[j][i]: offset = (j*m + i)*8  (R tiene m columnas)
    mul  x25, x24, x20
    add  x25, x25, x23
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
// arith_add / arith_sub — R[k] = A[k] +/- B[k]
//
// FIX DEL BUG: el modo se guardaba en [sp, #48] junto con x23,
// pero luego se leia de [sp, #56] (desplazamiento incorrecto).
// Ahora el modo se pasa como parametro interno via x9 y se
// preserva CORRECTAMENTE usando un registro callee-saved (x25)
// en lugar de intentar leerlo de la pila despues de otras llamadas.
//
// CALLEE-SAVED: x19(dA) x20(dB) x21(dR) x22(ELEMS)
//               x23(k) x24(filas_A) x25(MODO: 0=add 1=sub)
// ============================================================
arith_add:
    mov  x25, #0                   // x25 = modo SUMA
    b    .as_common
arith_sub:
    mov  x25, #1                   // x25 = modo RESTA

.as_common:
    stp  x29, x30, [sp, #-80]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    stp  x23, x24, [sp, #48]
    stp  x25, xzr, [sp, #64]      // x25 = MODO queda preservado en pila

    // validar A y B
    adr  x0, mat_A
    bl   matrix_validate
    cmp  x0, #ERR_OK;  bne .as_empty

    adr  x0, mat_B
    bl   matrix_validate
    cmp  x0, #ERR_OK;  bne .as_empty

    // leer dimensiones y datos de A
    adr  x0, mat_A
    ldr  x24, [x0, #DESC_ROWS]    // filas A
    ldr  x21, [x0, #DESC_COLS]    // cols A
    ldr  x22, [x0, #DESC_ELEMS]   // ELEMS A
    ldr  x19, [x0, #DESC_DATA]    // datos A

    // verificar B tiene mismas dimensiones
    adr  x0, mat_B
    ldr  x1, [x0, #DESC_ROWS]
    cmp  x1, x24;  bne .as_dim
    ldr  x1, [x0, #DESC_COLS]
    cmp  x1, x21;  bne .as_dim
    ldr  x20, [x0, #DESC_DATA]    // datos B

    // reservar R con mismas dimensiones que A
    adr  x0, mat_R
    mov  x1, x24                   // filas
    mov  x2, x21                   // cols
    bl   matrix_resize
    cmp  x0, #ERR_OK;  bne .as_ret

    adr  x0, mat_R
    ldr  x23, [x0, #DESC_DATA]    // datos R  (x23 = dR)

    // recuperar MODO de la pila (x25 fue guardado en [sp+64])
    // pero como hicimos stp, x25 ya fue preservado. Al restaurar
    // al final lo tendremos de vuelta. Para usarlo AHORA dentro del
    // bucle, lo recargamos del area de callee-saved en la pila:
    ldr  x25, [sp, #64]            // recargar MODO (0=add, 1=sub)

    // bucle lineal sobre todos los elementos
    mov  x0, #0                    // k = 0
.as_loop:
    cmp  x0, x22;  bge .as_ok

    lsl  x1, x0, #3               // offset = k*8
    ldr  x2, [x19, x1]            // A[k]
    ldr  x3, [x20, x1]            // B[k]

    cbnz x25, .as_do_sub
    add  x2, x2, x3               // A[k] + B[k]
    b    .as_store
.as_do_sub:
    sub  x2, x2, x3               // A[k] - B[k]
.as_store:
    str  x2, [x23, x1]            // R[k] = resultado

    add  x0, x0, #1
    b    .as_loop

.as_ok:
    mov  x0, #ERR_OK;  b .as_ret

.as_empty:
    adr  x0, Ea_em;  mov x1, #Ea_em_l;  bl io_print_str
    mov  x0, #ERR_EMPTY;  b .as_ret

.as_dim:
    adr  x0, Ea_dm;  mov x1, #Ea_dm_l;  bl io_print_str
    mov  x0, #ERR_DIM

.as_ret:
    ldp  x25, xzr, [sp, #64]
    ldp  x23, x24, [sp, #48]
    ldp  x21, x22, [sp, #32]
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #80
    ret

// ============================================================
// arith_mul — A (m×n) * B (n×p) -> R (m×p)
//
// R[i][j] = sum_{k=0}^{n-1}  A[i][k] * B[k][j]
//
// Multiplicacion Q32.32:
//   Dos valores Q32.32: a = A*2^32, b = B*2^32
//   Producto: a*b = A*B*2^64
//   Para Q32.32 necesitamos A*B*2^32: desplazamos 32 bits a la derecha
//     lo  = MUL  xa, xb   (bits 63..0 del producto de 128 bits)
//     hi  = SMULH xa, xb  (bits 127..64, con signo)
//     res = (hi << 32) | (lo >> 32)
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

    adr  x0, mat_A
    bl   matrix_validate
    cmp  x0, #ERR_OK;  bne .am_empty

    adr  x0, mat_B
    bl   matrix_validate
    cmp  x0, #ERR_OK;  bne .am_empty

    // dimensiones A: m×n
    adr  x0, mat_A
    ldr  x20, [x0, #DESC_ROWS]    // m
    ldr  x21, [x0, #DESC_COLS]    // n
    ldr  x19, [x0, #DESC_DATA]    // datos A

    // dimensiones B: n×p
    adr  x0, mat_B
    ldr  x23, [x0, #DESC_ROWS]    // debe ser == n
    ldr  x24, [x0, #DESC_COLS]    // p
    ldr  x22, [x0, #DESC_DATA]    // datos B

    // verificar compatibilidad: cols(A) == rows(B)
    cmp  x21, x23;  bne .am_dim

    // reservar R: m×p
    adr  x0, mat_R
    mov  x1, x20                   // filas = m
    mov  x2, x24                   // cols  = p
    bl   matrix_resize
    cmp  x0, #ERR_OK;  bne .am_ret

    adr  x0, mat_R
    ldr  x25, [x0, #DESC_DATA]    // datos R

    mov  x26, #0                   // i = 0
.am_i:
    cmp  x26, x20;  bge .am_ok
    mov  x27, #0                   // j = 0
.am_j:
    cmp  x27, x24;  bge .am_ni

    mov  x28, #0                   // acumulador = 0.0 en Q32.32
    mov  x9,  #0                   // k = 0
.am_k:
    cmp  x9, x21;  bge .am_store

    // leer A[i][k]: offset = (i*n + k)*8
    mul  x10, x26, x21
    add  x10, x10, x9
    lsl  x10, x10, #3
    ldr  x11, [x19, x10]          // A[i][k] en Q32.32

    // leer B[k][j]: offset = (k*p + j)*8
    mul  x12, x9,  x24
    add  x12, x12, x27
    lsl  x12, x12, #3
    ldr  x13, [x22, x12]          // B[k][j] en Q32.32

    // multiplicar A[i][k] * B[k][j] en Q32.32
    // resultado = (producto de 128 bits) >> 32
    mul   x14, x11, x13           // x14 = bits 63..0
    smulh x15, x11, x13           // x15 = bits 127..64 (signed)
    lsr   x14, x14, #32           // desplazar bits bajos
    lsl   x15, x15, #32           // posicionar bits altos
    orr   x14, x15, x14           // combinar -> resultado Q32.32

    add  x28, x28, x14            // acum += A[i][k]*B[k][j]
    add  x9,  x9,  #1;  b .am_k

.am_store:
    // guardar R[i][j]: offset = (i*p + j)*8
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