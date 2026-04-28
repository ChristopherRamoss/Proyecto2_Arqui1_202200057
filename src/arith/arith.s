// =============================================================================
// src/arith/arith.s
// Modulo de operaciones aritmeticas sobre matrices.
//
// Funciones exportadas:
//   arith_identity   : generar matriz identidad de A (cuadrada) -> R
//   arith_transpose  : transpuesta de A -> R
//   arith_add        : A + B -> R
//   arith_sub        : A - B -> R
//   arith_mul        : A * B -> R (producto matricial)
//
// CONVENCION DE ESTE MODULO:
//   Las operaciones leen de mat_A y/o mat_B y escriben el resultado en mat_R.
//   No modifican A ni B directamente.
//   Usan matrix_resize para preparar mat_R con las dimensiones correctas.
//
// NOTA SOBRE MULTIPLICACION Q32.32:
//   Para multiplicar dos valores Q32.32 (a * b):
//     1. mul  x_lo, xa, xb    -> parte baja de a*b (64 bits inferiores)
//     2. smulh x_hi, xa, xb  -> parte alta de a*b (64 bits superiores, con signo)
//   El resultado verdadero de 128 bits es: x_hi:x_lo
//   Para obtener el resultado en Q32.32, desplazamos 32 bits:
//     resultado = (x_hi << 32) | (x_lo >> 32)
//   Esto equivale a: resultado = (a * b) >> 32
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
.extern io_print_nl

.section .data
.msg_err_not_square:    .ascii "Error: la matriz no es cuadrada\n"
.msg_err_not_square_len = . - .msg_err_not_square
.msg_err_dim_add:       .ascii "Error: dimensiones incompatibles para suma/resta\n"
.msg_err_dim_add_len = . - .msg_err_dim_add
.msg_err_dim_mul:       .ascii "Error: columnas(A) != filas(B) para multiplicacion\n"
.msg_err_dim_mul_len = . - .msg_err_dim_mul
.msg_err_empty:         .ascii "Error: una o ambas matrices no tienen datos\n"
.msg_err_empty_len = . - .msg_err_empty

.section .text

// =============================================================================
// arith_identity
// Genera la matriz identidad de dimension n x n donde n = filas de A.
// Almacena el resultado en mat_R.
//
// La matriz identidad tiene 1 en la diagonal principal y 0 en el resto.
// Optimizacion: mmap ya inicializa la memoria a 0, por lo que solo
// necesitamos escribir los 1s en la diagonal.
//
// ENTRADA: ninguna (opera sobre mat_A)
//
// SALIDA:
//   x0 = ERR_OK o codigo de error
//
// REGISTROS: x19-x25
// =============================================================================
arith_identity:
    stp x29, x30, [sp, #-64]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]

    // PASO 1: validar que mat_A tiene datos
    adr x0, mat_A
    bl matrix_validate
    cmp x0, #ERR_OK
    bne .aid_err_empty

    // PASO 2: verificar que mat_A es cuadrada (ROWS == COLS)
    adr x19, mat_A
    ldr x20, [x19, #DESC_ROWS]     // x20 = n (filas)
    ldr x21, [x19, #DESC_COLS]     // x21 = columnas
    cmp x20, x21                   // filas == columnas?
    bne .aid_err_not_square

    // PASO 3: reservar mat_R de dimension n x n
    adr x0, mat_R
    mov x1, x20                    // filas = n
    mov x2, x20                    // columnas = n (cuadrada)
    bl matrix_resize               // mat_R queda con memoria nueva en cero
    cmp x0, #ERR_OK
    bne .aid_ret

    // PASO 4: escribir los 1s en la diagonal
    // La diagonal es el conjunto de elementos A[k][k] para k = 0, 1, ..., n-1
    // indice de A[k][k] = k * n + k = k * (n + 1)
    // offset = indice * 8
    adr x22, mat_R
    ldr x22, [x22, #DESC_DATA]     // x22 = puntero base del bloque de mat_R

    // Preparar el valor 1 en Q32.32: 1 << 32
    mov x23, #1
    lsl x23, x23, #Q32_SHIFT       // x23 = 1.0 en Q32.32

    // x24 = k (contador de la diagonal), va de 0 a n-1
    mov x24, #0

.aid_loop:
    cmp x24, x20                   // k >= n?
    bge .aid_done

    // offset = (k * (n + 1)) * 8
    // Primero: k * n + k = k * (n+1)
    add x25, x20, #1               // x25 = n + 1 (temporal)
    mul x25, x24, x25              // NO: incorrecto si n != n+1
    // Correcto: k * n + k
    mul x25, x24, x20              // x25 = k * n
    add x25, x25, x24              // x25 = k * n + k (= k*(n+1))
    lsl x25, x25, #3               // x25 = offset en bytes

    str x23, [x22, x25]            // mat_R[k][k] = 1.0 en Q32.32

    add x24, x24, #1               // k++
    b .aid_loop

.aid_done:
    mov x0, #ERR_OK
    b .aid_ret

.aid_err_empty:
    adr x0, .msg_err_empty
    mov x1, #.msg_err_empty_len
    bl io_print_str
    mov x0, #ERR_EMPTY
    b .aid_ret

.aid_err_not_square:
    adr x0, .msg_err_not_square
    mov x1, #.msg_err_not_square_len
    bl io_print_str
    mov x0, #ERR_RANGE

.aid_ret:
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #64
    ret

// =============================================================================
// arith_transpose
// Calcula la transpuesta de mat_A y la guarda en mat_R.
//
// Si A es m x n, entonces A^T es n x m.
// La regla de transposicion: R[j][i] = A[i][j]
//
// Por que no podemos hacer esto in-place para matrices rectangulares:
// Si A es 2x3 y calculamos la transpuesta 3x2, los indices cambian
// de interpretacion. Un bloque de 6 elementos se reinterpreta de diferente
// manera. Por eso creamos un nuevo bloque para R.
//
// REGISTROS: x19-x28
// =============================================================================
arith_transpose:
    stp x29, x30, [sp, #-80]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    stp x25, x26, [sp, #64]

    // Validar mat_A
    adr x0, mat_A
    bl matrix_validate
    cmp x0, #ERR_OK
    bne .atr_err_empty

    // Cargar dimensiones de A
    adr x19, mat_A
    ldr x20, [x19, #DESC_ROWS]     // x20 = m (filas de A)
    ldr x21, [x19, #DESC_COLS]     // x21 = n (columnas de A)
    ldr x22, [x19, #DESC_DATA]     // x22 = datos de A

    // Reservar R de dimension n x m (filas y columnas intercambiadas)
    adr x0, mat_R
    mov x1, x21                    // filas de R = columnas de A
    mov x2, x20                    // columnas de R = filas de A
    bl matrix_resize
    cmp x0, #ERR_OK
    bne .atr_ret

    // Cargar puntero de datos de R
    adr x23, mat_R
    ldr x23, [x23, #DESC_DATA]     // x23 = datos de R

    // Doble bucle: para cada A[i][j], escribir en R[j][i]
    // A[i][j]: offset_A = (i * n + j) * 8
    // R[j][i]: offset_R = (j * m + i) * 8  (porque R tiene m columnas = m filas de A)
    mov x24, #0                    // x24 = i

.atr_outer:
    cmp x24, x20                   // i >= m?
    bge .atr_done

    mov x25, #0                    // x25 = j

.atr_inner:
    cmp x25, x21                   // j >= n?
    bge .atr_next_i

    // Leer A[i][j]
    // offset_A = (i * n + j) * 8
    mul x26, x24, x21              // x26 = i * n
    add x26, x26, x25             // x26 = i * n + j
    lsl x26, x26, #3               // x26 = offset_A en bytes
    ldr x0, [x22, x26]             // x0 = A[i][j]

    // Escribir R[j][i]
    // offset_R = (j * m + i) * 8
    mul x26, x25, x20              // x26 = j * m
    add x26, x26, x24             // x26 = j * m + i
    lsl x26, x26, #3               // x26 = offset_R en bytes
    str x0, [x23, x26]             // R[j][i] = A[i][j]

    add x25, x25, #1               // j++
    b .atr_inner

.atr_next_i:
    add x24, x24, #1               // i++
    b .atr_outer

.atr_done:
    mov x0, #ERR_OK
    b .atr_ret

.atr_err_empty:
    adr x0, .msg_err_empty
    mov x1, #.msg_err_empty_len
    bl io_print_str
    mov x0, #ERR_EMPTY

.atr_ret:
    ldp x25, x26, [sp, #64]
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #80
    ret

// =============================================================================
// arith_add / arith_sub
// Suma o resta elemento por elemento: R[k] = A[k] + B[k] (o A[k] - B[k])
//
// RESTRICCION: A y B deben tener exactamente las mismas dimensiones.
//
// OPTIMIZACION: como ambas matrices estan en row-major (bloque contiguo),
// la suma/resta es un bucle lineal simple sobre todos los ELEMS elementos.
// No necesitamos indices i,j separados.
//
// ENTRADA:
//   arith_add: ninguna (usa mat_A y mat_B)
//   arith_sub: ninguna (usa mat_A y mat_B)
// =============================================================================
arith_add:
    mov x9, #0                     // x9 = modo 0 = suma
    b .addsub_common

arith_sub:
    mov x9, #1                     // x9 = modo 1 = resta

.addsub_common:
    stp x29, x30, [sp, #-64]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x9,  x23, [sp, #48]        // guardar modo tambien

    // Validar que A y B tienen datos
    adr x0, mat_A
    bl matrix_validate
    cmp x0, #ERR_OK
    bne .as_err_empty

    adr x0, mat_B
    bl matrix_validate
    cmp x0, #ERR_OK
    bne .as_err_empty

    // Cargar dimensiones
    adr x19, mat_A
    ldr x20, [x19, #DESC_ROWS]     // x20 = filas de A
    ldr x21, [x19, #DESC_COLS]     // x21 = columnas de A
    ldr x22, [x19, #DESC_ELEMS]    // x22 = total de elementos de A
    ldr x19, [x19, #DESC_DATA]     // x19 = datos de A

    adr x23, mat_B
    ldr x0, [x23, #DESC_ROWS]
    cmp x0, x20                    // filas A == filas B?
    bne .as_err_dim
    ldr x0, [x23, #DESC_COLS]
    cmp x0, x21                    // columnas A == columnas B?
    bne .as_err_dim
    ldr x23, [x23, #DESC_DATA]     // x23 = datos de B

    // Reservar R con las mismas dimensiones que A
    adr x0, mat_R
    mov x1, x20
    mov x2, x21
    bl matrix_resize
    cmp x0, #ERR_OK
    bne .as_ret

    // Cargar datos de R
    adr x0, mat_R
    ldr x24, [x0, #DESC_DATA]      // x24 = datos de R

    // Leer modo que guardamos en la pila
    ldr x9, [sp, #48]

    // Bucle lineal sobre todos los elementos
    mov x25, #0                    // x25 = k (indice lineal)

.as_loop:
    cmp x25, x22                   // k >= ELEMS?
    bge .as_done

    lsl x26, x25, #3               // x26 = offset = k * 8
    ldr x0, [x19, x26]             // x0 = A[k]
    ldr x1, [x23, x26]             // x1 = B[k]

    cbnz x9, .as_do_sub            // si modo=1, hacer resta
    add x0, x0, x1                 // x0 = A[k] + B[k]
    b .as_store

.as_do_sub:
    sub x0, x0, x1                 // x0 = A[k] - B[k]

.as_store:
    str x0, [x24, x26]             // R[k] = resultado
    add x25, x25, #1               // k++
    b .as_loop

.as_done:
    mov x0, #ERR_OK
    b .as_ret

.as_err_empty:
    adr x0, .msg_err_empty
    mov x1, #.msg_err_empty_len
    bl io_print_str
    mov x0, #ERR_EMPTY
    b .as_ret

.as_err_dim:
    adr x0, .msg_err_dim_add
    mov x1, #.msg_err_dim_add_len
    bl io_print_str
    mov x0, #ERR_DIM

.as_ret:
    ldp x9,  x23, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #64
    ret

// =============================================================================
// arith_mul
// Multiplicacion matricial A (m x n) * B (n x p) -> R (m x p).
//
// RESTRICCION: columnas(A) == filas(B)
//
// FORMULA: R[i][j] = suma_{k=0}^{n-1} (A[i][k] * B[k][j])
//
// MULTIPLICACION Q32.32:
//   Ambos operandos ya estan escalados por 2^32.
//   (a * 2^32) * (b * 2^32) = (a*b) * 2^64
//   Para obtener (a*b) * 2^32 (resultado en Q32.32), dividimos por 2^32 (desplazamos 32 bits).
//   En ARM64:
//     mul   xlo, xa, xb  -> bits 63..0  de xa*xb
//     smulh xhi, xa, xb  -> bits 127..64 de xa*xb (con signo)
//   Resultado Q32.32 = (xhi:xlo) >> 32 = (xhi << 32) | (xlo >> 32)
//
// REGISTROS: x9-x17, x19-x28 (muchos registros para i, j, k, datos de A, B, C)
// =============================================================================
arith_mul:
    stp x29, x30, [sp, #-96]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    stp x25, x26, [sp, #64]
    stp x27, x28, [sp, #80]

    // Validar A y B
    adr x0, mat_A
    bl matrix_validate
    cmp x0, #ERR_OK
    bne .amul_err_empty

    adr x0, mat_B
    bl matrix_validate
    cmp x0, #ERR_OK
    bne .amul_err_empty

    // Cargar dimensiones
    adr x19, mat_A
    ldr x20, [x19, #DESC_ROWS]     // x20 = m (filas de A)
    ldr x21, [x19, #DESC_COLS]     // x21 = n (columnas de A = filas de B)
    ldr x19, [x19, #DESC_DATA]     // x19 = datos de A

    adr x22, mat_B
    ldr x23, [x22, #DESC_ROWS]     // x23 = filas de B (debe == n)
    ldr x24, [x22, #DESC_COLS]     // x24 = p (columnas de B)
    ldr x22, [x22, #DESC_DATA]     // x22 = datos de B

    // Verificar compatibilidad: columnas(A) == filas(B)
    cmp x21, x23
    bne .amul_err_dim

    // Reservar R de dimension m x p
    adr x0, mat_R
    mov x1, x20                    // filas de R = m
    mov x2, x24                    // columnas de R = p
    bl matrix_resize
    cmp x0, #ERR_OK
    bne .amul_ret

    adr x25, mat_R
    ldr x25, [x25, #DESC_DATA]     // x25 = datos de R

    // Triple bucle: i, j, k
    mov x26, #0                    // x26 = i (fila de A y R)

.amul_i:
    cmp x26, x20                   // i >= m?
    bge .amul_done

    mov x27, #0                    // x27 = j (columna de B y R)

.amul_j:
    cmp x27, x24                   // j >= p?
    bge .amul_next_i

    // Acumular el producto punto de la fila i de A con la columna j de B
    mov x28, #0                    // x28 = acumulador = 0 (en Q32.32 esto es 0.0)
    mov x9, #0                     // x9 = k

.amul_k:
    cmp x9, x21                    // k >= n?
    bge .amul_store

    // Leer A[i][k]: offset = (i * n + k) * 8
    mul x10, x26, x21              // x10 = i * n
    add x10, x10, x9               // x10 = i * n + k
    lsl x10, x10, #3               // x10 = offset_A
    ldr x11, [x19, x10]            // x11 = A[i][k]

    // Leer B[k][j]: offset = (k * p + j) * 8
    mul x12, x9, x24               // x12 = k * p
    add x12, x12, x27             // x12 = k * p + j
    lsl x12, x12, #3               // x12 = offset_B
    ldr x13, [x22, x12]            // x13 = B[k][j]

    // Multiplicar A[i][k] * B[k][j] en Q32.32
    // Obtenemos 128 bits del producto y tomamos los bits 95..32 (desplazamos 32)
    mul  x14, x11, x13             // x14 = parte baja del producto (bits 63..0)
    smulh x15, x11, x13            // x15 = parte alta del producto (bits 127..64, signed)

    // Recombinar: resultado = (x15 << 32) | (x14 >> 32)
    lsr x14, x14, #32              // x14 = bits 63..32 del producto -> bits 31..0
    lsl x15, x15, #32              // x15 = bits 127..64 -> bits 95..32 -> en posicion alta
    orr x14, x15, x14             // x14 = resultado en Q32.32

    // Acumular: acumulador += A[i][k] * B[k][j]
    add x28, x28, x14

    add x9, x9, #1                 // k++
    b .amul_k

.amul_store:
    // Calcular offset de R[i][j]: (i * p + j) * 8
    mul x10, x26, x24              // i * p
    add x10, x10, x27             // i * p + j
    lsl x10, x10, #3               // offset_R
    str x28, [x25, x10]            // R[i][j] = acumulador

    add x27, x27, #1               // j++
    b .amul_j

.amul_next_i:
    add x26, x26, #1               // i++
    b .amul_i

.amul_done:
    mov x0, #ERR_OK
    b .amul_ret

.amul_err_empty:
    adr x0, .msg_err_empty
    mov x1, #.msg_err_empty_len
    bl io_print_str
    mov x0, #ERR_EMPTY
    b .amul_ret

.amul_err_dim:
    adr x0, .msg_err_dim_mul
    mov x1, #.msg_err_dim_mul_len
    bl io_print_str
    mov x0, #ERR_DIM

.amul_ret:
    ldp x27, x28, [sp, #80]
    ldp x25, x26, [sp, #64]
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #96
    ret