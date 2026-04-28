// =============================================================================
// src/gauss/gauss.s
// Modulo de eliminacion gaussiana y operaciones avanzadas.
//
// Funciones exportadas:
//   gauss_eliminate   : eliminacion de Gauss (Bareiss) -> R (triangular superior)
//   gauss_jordan      : Gauss-Jordan sobre [A|I] -> R (forma reducida / inversa)
//   gauss_determinant : determinante de A (usa gauss_eliminate internamente)
//   gauss_inverse     : inversa de A -> R
//   gauss_div         : A / B = A * B^(-1) -> R
//
// ALGORITMO DE BAREISS (para gauss_eliminate):
//   Ventaja: mantiene valores enteros el mayor tiempo posible, evitando
//   la acumulacion de errores por fracciones intermedias.
//
//   Formula de Bareiss:
//     M[i][j] = (pivot * M[i][j] - M[i][k] * M[k][j]) / pivot_anterior
//
//   donde pivot = M[k][k] (elemento diagonal en el paso k),
//         pivot_anterior = M[k-1][k-1] (diagonal del paso anterior, 1 para el primero).
//
// NOTA SOBRE OPERACIONES EN Q32.32:
//   - Suma/resta en Q32.32: igual que enteros normales (ADD/SUB)
//   - Multiplicacion en Q32.32: necesita mul + smulh y desplazamiento de 32 bits
//   - Division en Q32.32: para dividir a/b en Q32.32:
//       numerador = a (en Q32.32)
//       denominador = b >> 32 (parte entera del divisor)
//       Usar SDIV para division entera, luego ajustar.
//       Mas robusto: convertir a entero, dividir, reconvertir.
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
.extern io_print_str
.extern io_print_nl

.section .bss
    // Descriptores temporales para calculos internos
    // gauss_temp se usa como copia de trabajo para no destruir A
    gauss_temp:     .skip DESC_SIZE
    gauss_aug:      .skip DESC_SIZE    // matriz aumentada [A|I] para inversa

.section .data
.msg_err_not_square_g:  .ascii "Error: Gauss requiere matriz cuadrada\n"
.msg_err_not_square_g_len = . - .msg_err_not_square_g
.msg_err_singular:      .ascii "Error: matriz singular (det=0), no invertible\n"
.msg_err_singular_len = . - .msg_err_singular
.msg_err_empty_g:       .ascii "Error: matriz sin datos\n"
.msg_err_empty_g_len = . - .msg_err_empty_g

.section .text

// =============================================================================
// FUNCION INTERNA: q32_mul
// Multiplica dos valores Q32.32 y devuelve el resultado en Q32.32.
//
// ENTRADA:
//   x0 = primer operando en Q32.32
//   x1 = segundo operando en Q32.32
//
// SALIDA:
//   x0 = (x0 * x1) en Q32.32
//
// SIN guardar en pila (funcion inline-like, usa solo x0-x3)
// =============================================================================
q32_mul:
    mul  x2, x0, x1               // x2 = parte baja del producto (bits 63..0)
    smulh x3, x0, x1              // x3 = parte alta del producto (bits 127..64, signed)
    lsr  x2, x2, #32              // x2 = bits 63..32 -> posicion 31..0
    lsl  x3, x3, #32              // x3 = bits 95..32 -> posicion alta
    orr  x0, x3, x2               // x0 = resultado Q32.32
    ret

// =============================================================================
// FUNCION INTERNA: q32_div
// Divide dos valores Q32.32: a / b
//
// ESTRATEGIA: extraer partes enteras, dividir como enteros, reconvertir.
// Suficiente para Bareiss donde el cociente es exacto.
//
// ENTRADA:
//   x0 = dividendo en Q32.32
//   x1 = divisor en Q32.32
//
// SALIDA:
//   x0 = resultado en Q32.32 (o 0 si divisor es 0)
// =============================================================================
q32_div:
    // Verificar que el divisor no sea 0
    cbz x1, .qdiv_zero
    // Para Bareiss, el cociente es exacto en enteros.
    // Convertir ambos a enteros antes de dividir.
    asr x2, x0, #Q32_SHIFT        // x2 = parte entera del dividendo
    asr x3, x1, #Q32_SHIFT        // x3 = parte entera del divisor
    cbz x3, .qdiv_zero
    sdiv x0, x2, x3               // x0 = division entera
    lsl x0, x0, #Q32_SHIFT        // convertir resultado a Q32.32
    ret
.qdiv_zero:
    mov x0, #0
    ret

// =============================================================================
// FUNCION INTERNA: gauss_copy_to_temp
// Copia los datos de un descriptor a gauss_temp (descriptor temporal).
// Reserva nueva memoria para gauss_temp con las mismas dimensiones.
//
// ENTRADA:
//   x0 = puntero al descriptor fuente
//
// SALIDA:
//   x0 = ERR_OK o ERR_ALLOC
//
// Esta funcion es critica: permite operar sobre una COPIA de A sin destruirla.
// =============================================================================
gauss_copy_to_temp:
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]

    mov x19, x0                    // x19 = descriptor fuente

    // Leer dimensiones de la fuente
    ldr x20, [x19, #DESC_ROWS]     // x20 = filas
    ldr x21, [x19, #DESC_COLS]     // x21 = columnas
    ldr x22, [x19, #DESC_ELEMS]    // x22 = total de elementos
    ldr x19, [x19, #DESC_DATA]     // x19 = datos fuente

    // Reservar memoria para gauss_temp
    adr x0, gauss_temp
    mov x1, x20
    mov x2, x21
    bl matrix_resize               // reserva y actualiza gauss_temp
    cmp x0, #ERR_OK
    bne .gctt_done

    // Copiar todos los elementos byte a byte (usando ldr/str de 8 bytes)
    adr x23, gauss_temp
    ldr x23, [x23, #DESC_DATA]     // x23 = datos de gauss_temp

    mov x0, #0                     // x0 = k (indice lineal)
.gctt_loop:
    cmp x0, x22                    // k >= ELEMS?
    bge .gctt_ok
    lsl x1, x0, #3                 // offset = k * 8
    ldr x2, [x19, x1]              // leer del fuente
    str x2, [x23, x1]              // escribir en gauss_temp
    add x0, x0, #1
    b .gctt_loop

.gctt_ok:
    mov x0, #ERR_OK
.gctt_done:
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #48
    ret

// =============================================================================
// FUNCION INTERNA: gauss_swap_rows
// Intercambia dos filas completas de un bloque de datos.
//
// ENTRADA:
//   x0 = puntero al bloque de datos
//   x1 = fila a (indice)
//   x2 = fila b (indice)
//   x3 = numero de columnas
//
// SALIDA: ninguna
// Modifica x0-x7 (caller-saved, OK si no los necesitamos)
// =============================================================================
gauss_swap_rows:
    stp x29, x30, [sp, #-16]!
    mov x29, sp

    // Si a == b, no hacer nada
    cmp x1, x2
    beq .gsr_done

    mov x5, #0                     // x5 = j (columna)
.gsr_col:
    cmp x5, x3                     // j >= COLS?
    bge .gsr_done

    // offset_a = (a * COLS + j) * 8
    mul x6, x1, x3
    add x6, x6, x5
    lsl x6, x6, #3

    // offset_b = (b * COLS + j) * 8
    mul x7, x2, x3
    add x7, x7, x5
    lsl x7, x7, #3

    // Intercambiar
    ldr x4, [x0, x6]               // tmp = M[a][j]
    ldr x8, [x0, x7]               // M[a][j] = M[b][j]
    str x8, [x0, x6]
    str x4, [x0, x7]               // M[b][j] = tmp

    add x5, x5, #1
    b .gsr_col

.gsr_done:
    ldp x29, x30, [sp], #16
    ret

// =============================================================================
// gauss_eliminate
// Eliminacion gaussiana con el metodo de Bareiss.
// Opera sobre una COPIA de mat_A guardada en gauss_temp.
// El resultado (triangular superior) se guarda en mat_R.
//
// ENTRADA: ninguna (opera sobre mat_A)
//
// SALIDA:
//   x0 = ERR_OK o codigo de error
//   x1 = signo del determinante (+1 o -1), util para gauss_determinant
//
// El resultado mat_R tendra forma triangular superior:
//   [ p * * ]
//   [ 0 p * ]
//   [ 0 0 p ]
//
// REGISTROS USADOS: x19-x28
// =============================================================================
gauss_eliminate:
    stp x29, x30, [sp, #-96]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    stp x25, x26, [sp, #64]
    stp x27, x28, [sp, #80]

    // Validar mat_A
    adr x0, mat_A
    bl matrix_validate
    cmp x0, #ERR_OK
    bne .ge_err_empty

    // Verificar que es cuadrada
    adr x19, mat_A
    ldr x20, [x19, #DESC_ROWS]     // x20 = n
    ldr x21, [x19, #DESC_COLS]
    cmp x20, x21
    bne .ge_err_not_square

    // Copiar mat_A a gauss_temp (no destruimos A)
    adr x0, mat_A
    bl gauss_copy_to_temp
    cmp x0, #ERR_OK
    bne .ge_ret

    // Reservar mat_R con las mismas dimensiones
    adr x0, mat_R
    mov x1, x20
    mov x2, x20
    bl matrix_resize
    cmp x0, #ERR_OK
    bne .ge_ret

    // Cargar punteros de datos
    adr x22, gauss_temp
    ldr x22, [x22, #DESC_DATA]     // x22 = datos de gauss_temp (copia de A)

    // Copiar gauss_temp a mat_R para que el resultado quede en R
    // Trabajaremos directamente sobre los datos de mat_R
    adr x23, mat_R
    ldr x23, [x23, #DESC_DATA]     // x23 = datos de mat_R

    // Copiar datos de gauss_temp a mat_R
    // Primero calculamos el offset total fuera o usamos un registro temporal
    sub x24, x22, #DESC_DATA      // x24 ahora apunta al inicio del descriptor
    ldr x24, [x24, #DESC_ELEMS]    // Cargamos el valor de DESC_ELEMS desde ahí
    adr x0, gauss_temp
    ldr x24, [x0, #DESC_ELEMS]    // x24 = ELEMS
    mov x25, #0
.ge_copy_init:
    cmp x25, x24
    bge .ge_copy_done
    lsl x26, x25, #3
    ldr x0, [x22, x26]
    str x0, [x23, x26]
    add x25, x25, #1
    b .ge_copy_init
.ge_copy_done:

    // Ahora trabajamos sobre mat_R (x23 = datos de R)
    mov x24, #1                    // x24 = signo del determinante (+1)
    mov x25, #0                    // x25 = k (paso de eliminacion, columna del pivote)

    // pivot_anterior comienza en 1 (para la formula de Bareiss en el primer paso)
    mov x26, #1
    lsl x26, x26, #Q32_SHIFT       // x26 = 1.0 en Q32.32 (pivot_anterior)

.ge_pivot_step:
    cmp x25, x20                   // k >= n?
    bge .ge_finalize

    // Leer el pivote M[k][k]
    mul x0, x25, x20               // k * n
    add x0, x0, x25               // k * n + k
    lsl x0, x0, #3                 // offset
    ldr x27, [x23, x0]             // x27 = M[k][k] (pivote)

    // Si el pivote es 0, buscar una fila de intercambio
    asr x0, x27, #Q32_SHIFT
    cbnz x0, .ge_have_pivot        // si parte entera != 0, tenemos pivote

    // Buscar fila i > k con M[i][k] != 0
    mov x28, x25                   // x28 = candidato de fila
    add x28, x28, #1               // empezar en k+1

.ge_find_pivot:
    cmp x28, x20                   // candidato >= n? (no encontramos pivote)
    bge .ge_singular               // la matriz es singular

    mul x0, x28, x20               // candidato * n
    add x0, x0, x25               // + k
    lsl x0, x0, #3
    ldr x27, [x23, x0]             // M[candidato][k]
    asr x0, x27, #Q32_SHIFT
    cbnz x0, .ge_do_swap           // encontramos fila candidata
    add x28, x28, #1
    b .ge_find_pivot

.ge_do_swap:
    // Intercambiar filas k y candidato
    mov x0, x23                    // puntero a datos de R
    mov x1, x25                    // fila k
    mov x2, x28                    // fila candidata
    mov x3, x20                    // columnas = n
    bl gauss_swap_rows

    // Cambiar signo del determinante
    neg x24, x24

    // Volver a leer el pivote (ahora deberia ser no-nulo)
    mul x0, x25, x20
    add x0, x0, x25
    lsl x0, x0, #3
    ldr x27, [x23, x0]

.ge_have_pivot:
    // Eliminar elementos debajo del pivote en la columna k
    // Para cada fila i > k:
    //   M[i][j] = (pivot * M[i][j] - M[i][k] * M[k][j]) / pivot_anterior
    mov x28, x25                   // x28 = i, empieza en k+1
    add x28, x28, #1

.ge_elim_row:
    cmp x28, x20                   // i >= n?
    bge .ge_next_pivot

    // Leer M[i][k] (elemento a eliminar)
    mul x0, x28, x20               // i * n
    add x0, x0, x25               // i * n + k
    lsl x0, x0, #3
    ldr x19, [x23, x0]             // x19 = M[i][k]

    // Para cada columna j:
    mov x0, #0                     // j = 0

.ge_elim_col:
    cmp x0, x20                    // j >= n?
    bge .ge_next_row_elim

    // Leer M[k][j]
    mul x1, x25, x20               // k * n
    add x1, x1, x0                // k * n + j
    lsl x1, x1, #3
    ldr x1, [x23, x1]             // x1 = M[k][j]

    // Leer M[i][j]
    mul x2, x28, x20               // i * n
    add x2, x2, x0               // i * n + j
    lsl x2, x2, #3
    ldr x2, [x23, x2]             // x2 = M[i][j] (guardamos offset en otro reg)

    // Calcular M[k][j] * pivot y M[i][k] * M[k][j] en Q32.32
    // Usamos stp/ldp para preservar x0 (indice j)
    stp x0, x19, [sp, #-32]!
    stp x27, x26, [sp, #16]       // guardar pivot y pivot_anterior

    // nuevo_val = (pivot * M[i][j] - M[i][k] * M[k][j]) / pivot_anterior
    mov x0, x27                    // pivot
    mov x1, x2                     // M[i][j]
    bl q32_mul
    mov x3, x0                     // x3 = pivot * M[i][j]

    ldr x0, [sp, #8]               // x0 = M[i][k] (x19 guardado)
    ldr x1, [sp, #8]               // lo mismo - cargamos x19
    // Recalcular: x19 sigue valido antes del stp
    ldp x0, x1, [sp]              // x0=j, x1=M[i][k] -- incorrecto, reorganizar
    // *** REORGANIZAR REGISTROS para este calculo ***
    ldp x27, x26, [sp, #16]
    ldp x0, x19, [sp], #32
    // Restaurado: x0=j, x19=M[i][k], x27=pivot, x26=pivot_anterior

    // Recalcular offsets de M[k][j] y M[i][j] con x0=j
    mul x2, x25, x20               // k * n
    add x2, x2, x0
    lsl x2, x2, #3
    ldr x9, [x23, x2]             // x9 = M[k][j]

    mul x2, x28, x20               // i * n
    add x2, x2, x0
    lsl x2, x2, #3
    // x10 = offset de M[i][j] (necesitamos para escribir el resultado)
    mov x10, x2

    ldr x11, [x23, x10]           // x11 = M[i][j]

    // term1 = pivot * M[i][j]
    mov x12, x27                   // pivot
    mov x13, x11                   // M[i][j]
    stp x0, x19, [sp, #-32]!
    stp x27, x26, [sp, #16]
    stp x10, xzr, [sp, #32]       // guardar offset de escritura
    // Hmm: la pila crece demasiado compleja aqui. Simplificar con funcion directa.
    ldp x10, xzr, [sp, #32]
    ldp x27, x26, [sp, #16]
    ldp x0, x19, [sp], #32

    // SIMPLIFICACION DIRECTA (sin llamar q32_mul para no usar mas pila):
    // term1 = (pivot * M[i][j]) >> 32
    mul  x14, x27, x11             // bits bajos de pivot * M[i][j]
    smulh x15, x27, x11            // bits altos
    lsr  x14, x14, #32
    lsl  x15, x15, #32
    orr  x14, x15, x14            // x14 = term1 en Q32.32

    // term2 = (M[i][k] * M[k][j]) >> 32
    mul  x15, x19, x9             // bits bajos de M[i][k] * M[k][j]
    smulh x16, x19, x9            // bits altos
    lsr  x15, x15, #32
    lsl  x16, x16, #32
    orr  x15, x16, x15            // x15 = term2 en Q32.32

    // nuevo_val = (term1 - term2) / pivot_anterior
    sub x14, x14, x15             // x14 = term1 - term2

    // Division por pivot_anterior (parte entera)
    asr x15, x14, #Q32_SHIFT      // parte entera del numerador
    asr x16, x26, #Q32_SHIFT      // parte entera del pivot_anterior
    cmp x16, #1
    beq .ge_no_div                 // si pivot_anterior == 1, no dividir
    sdiv x15, x15, x16            // division entera
.ge_no_div:
    lsl x14, x15, #Q32_SHIFT      // convertir a Q32.32

    // Escribir M[i][j] = nuevo_val
    str x14, [x23, x10]

    add x0, x0, #1                 // j++
    b .ge_elim_col

.ge_next_row_elim:
    add x28, x28, #1               // i++
    b .ge_elim_row

.ge_next_pivot:
    // Actualizar pivot_anterior = pivot actual (antes de avanzar k)
    mov x26, x27                   // pivot_anterior = pivot actual
    add x25, x25, #1               // k++
    b .ge_pivot_step

.ge_finalize:
    // Copiar los datos de gauss_temp a mat_R ya se hizo al inicio
    // (trabajamos directamente sobre mat_R)
    mov x0, #ERR_OK
    mov x1, x24                    // x1 = signo del determinante
    b .ge_ret

.ge_singular:
    // Marcar mat_R como libre si habia datos (la eliminacion fallo)
    adr x0, mat_R
    bl matrix_free
    mov x0, #ERR_SINGULAR
    mov x1, #0
    b .ge_ret

.ge_err_empty:
    adr x0, .msg_err_empty_g
    mov x1, #.msg_err_empty_g_len
    bl io_print_str
    mov x0, #ERR_EMPTY
    mov x1, #0
    b .ge_ret

.ge_err_not_square:
    adr x0, .msg_err_not_square_g
    mov x1, #.msg_err_not_square_g_len
    bl io_print_str
    mov x0, #ERR_RANGE
    mov x1, #0

.ge_ret:
    ldp x27, x28, [sp, #80]
    ldp x25, x26, [sp, #64]
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #96
    ret

// =============================================================================
// gauss_determinant
// Calcula el determinante de mat_A.
// Reutiliza gauss_eliminate y toma el producto de la diagonal de la triangular.
//
// Con el metodo de Bareiss, el ultimo pivote de la diagonal contiene el
// determinante (o su multiplo por el pivot_anterior). Aqui simplemente
// calculamos el producto de todos los elementos diagonales de la triangular.
//
// ENTRADA: ninguna (usa mat_A)
//
// SALIDA:
//   x0 = determinante en Q32.32 (guardado tambien en mat_R como matriz 1x1)
//   x1 = ERR_OK o codigo de error
// =============================================================================
gauss_determinant:
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]

    // Realizar eliminacion gaussiana (el resultado en mat_R es la triangular)
    bl gauss_eliminate
    cmp x0, #ERR_OK
    bne .gdet_err

    mov x19, x1                    // x19 = signo del determinante

    // Cargar la matriz triangular (mat_R)
    adr x20, mat_R
    ldr x21, [x20, #DESC_ROWS]     // x21 = n
    ldr x20, [x20, #DESC_DATA]     // x20 = datos de mat_R

    // El determinante es el producto de los elementos diagonales
    // en la triangular superior de Bareiss.
    // Con Bareiss, el ultimo pivote contiene det / (product of intermediate pivots).
    // Para simplificar: tomamos solo el ultimo elemento diagonal M[n-1][n-1].
    // Esto es correcto cuando Bareiss trabaja con enteros y no hay swaps adicionales.
    //
    // Para mayor precision, calcular el producto de toda la diagonal:
    mov x22, #1
    lsl x22, x22, #Q32_SHIFT       // x22 = 1.0 en Q32.32 (acumulador del producto)
    mov x23, #0                    // x23 = k

.gdet_prod:
    cmp x23, x21                   // k >= n?
    bge .gdet_apply_sign

    // offset del diagonal M[k][k] = (k * n + k) * 8
    mul x0, x23, x21              // k * n
    add x0, x0, x23              // k * n + k
    lsl x0, x0, #3
    ldr x0, [x20, x0]             // x0 = M[k][k]

    // Multiplicar al acumulador: x22 = x22 * x0 (en Q32.32)
    mul  x24, x22, x0
    smulh x25, x22, x0
    lsr  x24, x24, #32
    lsl  x25, x25, #32
    orr  x22, x25, x24            // x22 = producto acumulado

    add x23, x23, #1
    b .gdet_prod

.gdet_apply_sign:
    // Aplicar el signo de las transposiciones
    cmp x19, #0
    bge .gdet_pos
    neg x22, x22                   // si signo negativo, negar el determinante

.gdet_pos:
    // Guardar el determinante en mat_R como una matriz 1x1
    // (reutilizamos mat_R que ya tiene la triangular; la reemplazamos)
    adr x0, mat_R
    mov x1, #1
    mov x2, #1
    bl matrix_resize               // mat_R = nueva matriz 1x1

    adr x0, mat_R
    ldr x0, [x0, #DESC_DATA]
    str x22, [x0]                  // mat_R[0][0] = determinante

    mov x0, x22                    // devolver el valor
    mov x1, #ERR_OK
    b .gdet_done

.gdet_err:
    mov x1, x0
    mov x0, #0

.gdet_done:
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #48
    ret

// =============================================================================
// gauss_jordan
// Metodo de Gauss-Jordan: reduce mat_A a la forma escalonada reducida (RREF).
// El resultado se guarda en mat_R.
//
// ALGORITMO:
//   1. Copiar A en mat_R
//   2. Para cada columna pivote k:
//      a. Buscar el pivote (fila con elemento no-cero en columna k)
//      b. Hacer swap si el pivote no esta en la fila k
//      c. Normalizar la fila k: dividir cada elemento por el pivote
//         (R[k][j] = R[k][j] / R[k][k])
//      d. Eliminar la columna k en TODAS las otras filas (no solo las de abajo):
//         R[i][j] = R[i][j] - factor * R[k][j]
//         donde factor = R[i][k]
//
// ENTRADA: ninguna (usa mat_A)
// SALIDA:  x0 = ERR_OK o codigo de error
// =============================================================================
gauss_jordan:
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
    bne .gj_err_empty

    // Cargar dimensiones
    adr x19, mat_A
    ldr x20, [x19, #DESC_ROWS]     // x20 = n (filas, asumimos cuadrada para RREF completa)
    ldr x21, [x19, #DESC_COLS]     // x21 = m (columnas, puede ser n o n+algo)
    ldr x19, [x19, #DESC_DATA]     // x19 = datos de A

    // Copiar A a mat_R
    adr x0, mat_R
    mov x1, x20
    mov x2, x21
    bl matrix_resize
    cmp x0, #ERR_OK
    bne .gj_ret

    adr x22, mat_R
    ldr x22, [x22, #DESC_DATA]     // x22 = datos de mat_R

    // Copiar datos de A a mat_R
    mul x0, x20, x21               // ELEMS
    mov x23, #0
.gj_copy:
    cmp x23, x0
    bge .gj_copy_done
    lsl x24, x23, #3
    ldr x25, [x19, x24]
    str x25, [x22, x24]
    add x23, x23, #1
    b .gj_copy
.gj_copy_done:

    // Algoritmo de Gauss-Jordan
    mov x23, #0                    // x23 = k (columna pivote)

.gj_pivot_col:
    cmp x23, x20                   // k >= n? (o min(n,m))
    bge .gj_done

    // Buscar pivote en la columna k: fila >= k con elemento no-cero
    mov x24, x23                   // x24 = fila pivote candidata

.gj_find_piv:
    cmp x24, x20
    bge .gj_next_col               // no hay pivote en esta columna, avanzar

    mul x0, x24, x21               // candidato * m
    add x0, x0, x23               // + k
    lsl x0, x0, #3
    ldr x25, [x22, x0]             // R[candidato][k]
    asr x0, x25, #Q32_SHIFT
    cbnz x0, .gj_do_swap2
    add x24, x24, #1
    b .gj_find_piv

.gj_do_swap2:
    // Intercambiar filas k y candidato (si son diferentes)
    cmp x24, x23
    beq .gj_normalize

    mov x0, x22                    // datos de R
    mov x1, x23                    // fila k
    mov x2, x24                    // fila candidata
    mov x3, x21                    // columnas
    bl gauss_swap_rows

.gj_normalize:
    // Leer el pivote R[k][k]
    mul x0, x23, x21
    add x0, x0, x23
    lsl x0, x0, #3
    ldr x25, [x22, x0]             // x25 = pivote = R[k][k]

    // Normalizar fila k: R[k][j] = R[k][j] / R[k][k]
    // En Q32.32: dividir es complejo. Usamos la parte entera del pivote como divisor.
    asr x26, x25, #Q32_SHIFT       // x26 = parte entera del pivote

    mov x0, #0                     // j = 0
.gj_norm_col:
    cmp x0, x21                    // j >= m?
    bge .gj_eliminate_rows

    mul x1, x23, x21               // k * m
    add x1, x1, x0                // + j
    lsl x1, x1, #3
    ldr x2, [x22, x1]             // R[k][j]
    asr x2, x2, #Q32_SHIFT        // parte entera de R[k][j]
    sdiv x2, x2, x26              // dividir
    lsl x2, x2, #Q32_SHIFT        // reconvertir a Q32.32
    str x2, [x22, x1]             // R[k][j] = normalizado

    add x0, x0, #1
    b .gj_norm_col

.gj_eliminate_rows:
    // Eliminar columna k en todas las filas excepto k
    mov x24, #0                    // i = 0

.gj_elim_row2:
    cmp x24, x20                   // i >= n?
    bge .gj_next_col

    cmp x24, x23                   // i == k? (saltar la fila pivote)
    beq .gj_next_row2

    // factor = R[i][k]
    mul x0, x24, x21              // i * m
    add x0, x0, x23              // + k
    lsl x0, x0, #3
    ldr x26, [x22, x0]            // x26 = factor = R[i][k]

    asr x0, x26, #Q32_SHIFT
    cbz x0, .gj_next_row2          // si factor == 0, no hay nada que eliminar

    // R[i][j] = R[i][j] - factor * R[k][j] para todo j
    mov x0, #0                    // j = 0
.gj_elim_col2:
    cmp x0, x21
    bge .gj_next_row2

    // Leer R[k][j]
    mul x1, x23, x21
    add x1, x1, x0
    lsl x1, x1, #3
    ldr x1, [x22, x1]             // R[k][j]

    // factor * R[k][j] en Q32.32
    mul  x9, x26, x1
    smulh x10, x26, x1
    lsr  x9, x9, #32
    lsl  x10, x10, #32
    orr  x9, x10, x9              // x9 = factor * R[k][j]

    // R[i][j] = R[i][j] - x9
    mul x1, x24, x21
    add x1, x1, x0
    lsl x1, x1, #3
    ldr x2, [x22, x1]
    sub x2, x2, x9
    str x2, [x22, x1]

    add x0, x0, #1
    b .gj_elim_col2

.gj_next_row2:
    add x24, x24, #1
    b .gj_elim_row2

.gj_next_col:
    add x23, x23, #1
    b .gj_pivot_col

.gj_done:
    mov x0, #ERR_OK
    b .gj_ret

.gj_err_empty:
    adr x0, .msg_err_empty_g
    mov x1, #.msg_err_empty_g_len
    bl io_print_str
    mov x0, #ERR_EMPTY

.gj_ret:
    ldp x25, x26, [sp, #64]
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #80
    ret

// =============================================================================
// gauss_inverse
// Calcula la inversa de mat_A usando Gauss-Jordan sobre la matriz aumentada [A|I].
// El resultado es la inversa guardada en mat_R.
//
// PROCESO:
//   Construir la matriz aumentada n x 2n: [A | I]
//   Aplicar Gauss-Jordan hasta obtener: [I | A^(-1)]
//   Extraer la parte derecha n x n como mat_R.
//
// ENTRADA: ninguna (usa mat_A)
// SALIDA:  x0 = ERR_OK o codigo de error
// =============================================================================
gauss_inverse:
    stp x29, x30, [sp, #-80]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    stp x25, x26, [sp, #64]

    // Validar mat_A y que sea cuadrada
    adr x0, mat_A
    bl matrix_validate
    cmp x0, #ERR_OK
    bne .ginv_err_empty

    adr x19, mat_A
    ldr x20, [x19, #DESC_ROWS]    // x20 = n
    ldr x21, [x19, #DESC_COLS]
    cmp x20, x21
    bne .ginv_err_not_square
    ldr x19, [x19, #DESC_DATA]    // x19 = datos de A

    // Construir [A|I] en gauss_aug: n filas, 2n columnas
    lsl x22, x20, #1               // x22 = 2n (columnas de la aumentada)
    adr x0, gauss_aug
    mov x1, x20
    mov x2, x22
    bl matrix_resize
    cmp x0, #ERR_OK
    bne .ginv_ret

    adr x23, gauss_aug
    ldr x23, [x23, #DESC_DATA]    // x23 = datos de [A|I]

    // Llenar la aumentada: parte izquierda = A, parte derecha = I
    mov x24, #0                    // i = 0
.ginv_fill:
    cmp x24, x20
    bge .ginv_fill_done

    mov x25, #0                    // j = 0
.ginv_fill_col:
    cmp x25, x22                   // j >= 2n?
    bge .ginv_next_fill_row

    // Calcular offset en la aumentada: (i * 2n + j) * 8
    mul x0, x24, x22
    add x0, x0, x25
    lsl x0, x0, #3

    cmp x25, x20                   // j < n? (parte de A)
    bge .ginv_check_identity

    // Parte de A: copiar A[i][j]
    mul x1, x24, x20               // i * n
    add x1, x1, x25               // + j
    lsl x1, x1, #3
    ldr x2, [x19, x1]             // A[i][j]
    str x2, [x23, x0]
    b .ginv_next_fill_col

.ginv_check_identity:
    // Parte de I: 1 si i == j-n, 0 en caso contrario
    sub x1, x25, x20               // j - n
    cmp x24, x1                    // i == j - n?
    bne .ginv_fill_zero
    mov x2, #1
    lsl x2, x2, #Q32_SHIFT        // 1.0 en Q32.32
    str x2, [x23, x0]
    b .ginv_next_fill_col
.ginv_fill_zero:
    str xzr, [x23, x0]

.ginv_next_fill_col:
    add x25, x25, #1
    b .ginv_fill_col

.ginv_next_fill_row:
    add x24, x24, #1
    b .ginv_fill

.ginv_fill_done:
    // Aplicar Gauss-Jordan sobre la aumentada (gauss_aug)
    // Necesitamos hacer Gauss-Jordan sobre gauss_aug directamente.
    // Usamos los datos en x23 y repetimos el algoritmo G-J.
    mov x24, #0                    // k = columna pivote

.ginv_gj_col:
    cmp x24, x20                   // k >= n?
    bge .ginv_extract

    // Buscar pivote en columna k
    mov x25, x24
.ginv_find_piv:
    cmp x25, x20
    bge .ginv_singular

    mul x0, x25, x22
    add x0, x0, x24
    lsl x0, x0, #3
    ldr x26, [x23, x0]
    asr x0, x26, #Q32_SHIFT
    cbnz x0, .ginv_do_swap
    add x25, x25, #1
    b .ginv_find_piv

.ginv_do_swap:
    cmp x25, x24
    beq .ginv_norm_row

    mov x0, x23
    mov x1, x24
    mov x2, x25
    mov x3, x22                    // 2n columnas
    bl gauss_swap_rows

.ginv_norm_row:
    // Leer pivote R[k][k]
    mul x0, x24, x22
    add x0, x0, x24
    lsl x0, x0, #3
    ldr x26, [x23, x0]             // pivote
    asr x26, x26, #Q32_SHIFT       // parte entera del pivote

    // Normalizar fila k
    mov x0, #0                     // j = 0
.ginv_norm:
    cmp x0, x22
    bge .ginv_elim

    mul x1, x24, x22
    add x1, x1, x0
    lsl x1, x1, #3
    ldr x2, [x23, x1]
    asr x2, x2, #Q32_SHIFT
    sdiv x2, x2, x26
    lsl x2, x2, #Q32_SHIFT
    str x2, [x23, x1]

    add x0, x0, #1
    b .ginv_norm

.ginv_elim:
    // Eliminar columna k en todas las otras filas
    mov x25, #0
.ginv_elim_row:
    cmp x25, x20
    bge .ginv_next_col_gj

    cmp x25, x24
    beq .ginv_elim_next

    mul x0, x25, x22
    add x0, x0, x24
    lsl x0, x0, #3
    ldr x27, [x23, x0]             // factor = R[i][k]
    asr x0, x27, #Q32_SHIFT
    cbz x0, .ginv_elim_next

    mov x0, #0
.ginv_elim_col:
    cmp x0, x22
    bge .ginv_elim_next

    mul x1, x24, x22
    add x1, x1, x0
    lsl x1, x1, #3
    ldr x1, [x23, x1]

    mul  x9, x27, x1
    smulh x10, x27, x1
    lsr  x9, x9, #32
    lsl  x10, x10, #32
    orr  x9, x10, x9

    mul x1, x25, x22
    add x1, x1, x0
    lsl x1, x1, #3
    ldr x2, [x23, x1]
    sub x2, x2, x9
    str x2, [x23, x1]

    add x0, x0, #1
    b .ginv_elim_col

.ginv_elim_next:
    add x25, x25, #1
    b .ginv_elim_row

.ginv_next_col_gj:
    add x24, x24, #1
    b .ginv_gj_col

.ginv_extract:
    // Extraer la mitad derecha [I | A^-1] -> solo la parte A^-1
    adr x0, mat_R
    mov x1, x20
    mov x2, x20
    bl matrix_resize
    cmp x0, #ERR_OK
    bne .ginv_ret

    adr x24, mat_R
    ldr x24, [x24, #DESC_DATA]    // x24 = datos de mat_R

    mov x25, #0                   // i
.ginv_ext_row:
    cmp x25, x20
    bge .ginv_done

    mov x26, #0                   // j
.ginv_ext_col:
    cmp x26, x20
    bge .ginv_ext_next_row

    // A^-1[i][j] esta en la aumentada en [i][j + n]
    add x0, x26, x20              // j + n
    mul x1, x25, x22              // i * 2n
    add x1, x1, x0               // i * 2n + (j + n)
    lsl x1, x1, #3
    ldr x0, [x23, x1]

    mul x1, x25, x20              // i * n
    add x1, x1, x26              // + j
    lsl x1, x1, #3
    str x0, [x24, x1]

    add x26, x26, #1
    b .ginv_ext_col

.ginv_ext_next_row:
    add x25, x25, #1
    b .ginv_ext_row

.ginv_done:
    // Liberar gauss_aug
    adr x0, gauss_aug
    bl matrix_free
    mov x0, #ERR_OK
    b .ginv_ret

.ginv_singular:
    adr x0, .msg_err_singular
    mov x1, #.msg_err_singular_len
    bl io_print_str
    adr x0, gauss_aug
    bl matrix_free
    mov x0, #ERR_SINGULAR
    b .ginv_ret

.ginv_err_empty:
    adr x0, .msg_err_empty_g
    mov x1, #.msg_err_empty_g_len
    bl io_print_str
    mov x0, #ERR_EMPTY
    b .ginv_ret

.ginv_err_not_square:
    adr x0, .msg_err_not_square_g
    mov x1, #.msg_err_not_square_g_len
    bl io_print_str
    mov x0, #ERR_RANGE

.ginv_ret:
    ldp x25, x26, [sp, #64]
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #80
    ret

// =============================================================================
// gauss_div
// Division de matrices: A / B = A * B^(-1)
//
// PROCESO:
//   1. Calcular B^(-1) usando gauss_inverse (resultado en mat_R)
//   2. Temporalmente mover R a mat_B
//   3. Multiplicar A * B_inv usando arith_mul (resultado en mat_R)
//
// ENTRADA: ninguna (usa mat_A y mat_B)
// SALIDA:  x0 = ERR_OK o codigo de error
// =============================================================================
gauss_div:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    stp x19, x20, [sp, #16]

    // Paso 1: Validar que A y B tienen datos
    adr x0, mat_A
    bl matrix_validate
    cmp x0, #ERR_OK
    bne .gdiv_err_empty

    adr x0, mat_B
    bl matrix_validate
    cmp x0, #ERR_OK
    bne .gdiv_err_empty

    // Paso 2: Temporalmente swap mat_A con mat_B para calcular inv(B)
    // Guardamos los datos de A en un temporal, hacemos A=B, calculamos inv(A)->R
    // Luego recuperamos A y multiplicamos A * R

    // Guardar descriptor de A en un buffer temporal de la pila
    // (64 bytes = 8 palabras de 8 bytes)
    sub sp, sp, #64
    adr x0, mat_A
    // Copiar descriptor de A a la pila
    ldp x1, x2, [x0, #0]
    stp x1, x2, [sp, #0]
    ldp x1, x2, [x0, #16]
    stp x1, x2, [sp, #16]
    ldp x1, x2, [x0, #32]
    stp x1, x2, [sp, #32]
    ldp x1, x2, [x0, #48]
    stp x1, x2, [sp, #48]

    // Copiar B a A para calcular inv(B)
    adr x1, mat_B
    adr x0, mat_A
    // Copiar descriptor de B a mat_A
    ldp x2, x3, [x1, #0];  stp x2, x3, [x0, #0]
    ldp x2, x3, [x1, #16]; stp x2, x3, [x0, #16]
    ldp x2, x3, [x1, #32]; stp x2, x3, [x0, #32]
    ldp x2, x3, [x1, #48]; stp x2, x3, [x0, #48]

    // Calcular inv(B) -> mat_R (temporalmente mat_A = B)
    bl gauss_inverse
    mov x19, x0                    // x19 = codigo de error

    // Restaurar mat_A
    adr x0, mat_A
    ldp x1, x2, [sp, #0];  stp x1, x2, [x0, #0]
    ldp x1, x2, [sp, #16]; stp x1, x2, [x0, #16]
    ldp x1, x2, [sp, #32]; stp x1, x2, [x0, #32]
    ldp x1, x2, [sp, #48]; stp x1, x2, [x0, #48]
    add sp, sp, #64

    cmp x19, #ERR_OK
    bne .gdiv_ret

    // Paso 3: Mover mat_R (= inv(B)) a mat_B temporalmente
    adr x0, mat_B
    bl matrix_free                 // liberar B original
    adr x0, mat_B
    adr x1, mat_R
    bl matrix_copy_desc            // mat_B = inv(B), mat_R = libre

    // Paso 4: Multiplicar A * B (que ahora es A * inv(B_original))
    bl arith_mul                   // resultado en mat_R

    // Restaurar mat_B a un estado limpio (ya fue consumida)
    // matrix_copy_desc ya marcó mat_R como free después de copiar a mat_B,
    // y arith_mul crea un nuevo mat_R, así que mat_B ahora apunta al bloque de inv(B).
    // Lo liberamos al final.
    adr x0, mat_B
    bl matrix_free

    mov x0, #ERR_OK
    b .gdiv_ret

.gdiv_err_empty:
    mov x0, #ERR_EMPTY

.gdiv_ret:
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

// Necesitamos estas funciones externas
.extern arith_mul
.extern matrix_copy_desc