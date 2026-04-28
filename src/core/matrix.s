// =============================================================================
// src/core/matrix.s
// Modulo de gestion de descriptores de matrices A, B y R.
//
// Funciones exportadas:
//   matrix_init        : inicializar todos los descriptores a STATUS_FREE
//   matrix_load        : pedir dimensiones al usuario y reservar memoria (mmap)
//   matrix_resize      : liberar datos anteriores y reservar nueva memoria
//   matrix_free        : liberar la memoria de un descriptor especifico
//   matrix_free_all    : liberar A, B y R
//   matrix_copy_desc   : copiar descriptor (para mover R -> A o R -> B)
//   matrix_get_elem    : obtener el valor Q32.32 de A[i][j]
//   matrix_set_elem    : escribir un valor Q32.32 en A[i][j]
//   matrix_validate    : verificar que un descriptor es valido y activo
//
// MODELO DE MEMORIA:
//   Los descriptores (64 bytes cada uno) viven en memoria ESTATICA (.bss).
//   Los datos de la matriz viven en memoria DINAMICA (mmap), apuntada por DESC_DATA.
//   Esto separa "que es la matriz" (descriptor estatico) de "que contiene" (bloque dinamico).
// =============================================================================

.include "include/defines.inc"

.global matrix_init
.global matrix_load
.global matrix_resize
.global matrix_free
.global matrix_free_all
.global matrix_copy_desc
.global matrix_get_elem
.global matrix_set_elem
.global matrix_validate
.global mat_A
.global mat_B
.global mat_R

// Importar funciones de IO que usaremos para pedir datos al usuario
.extern io_print_str
.extern io_print_str_ln
.extern io_print_int
.extern io_print_nl
.extern io_print_matrix
.extern io_read_int

// -----------------------------------------------------------------------------
// Memoria estatica: los tres descriptores del sistema
// Se reservan 64 bytes por descriptor (DESC_SIZE), inicializados a 0 en .bss
// -----------------------------------------------------------------------------
.section .bss
    mat_A:  .skip DESC_SIZE        // descriptor de la matriz A (64 bytes, en cero)
    mat_B:  .skip DESC_SIZE        // descriptor de la matriz B (64 bytes, en cero)
    mat_R:  .skip DESC_SIZE        // descriptor del resultado R (64 bytes, en cero)

.section .data
    // --- Mueve tus mensajes aquí ---
    .msg_enter_rows:      .ascii "Ingrese filas: "
    .msg_enter_rows_len = . - .msg_enter_rows

    .msg_enter_cols:      .ascii "Ingrese columnas: "
    .msg_enter_cols_len = . - .msg_enter_cols

    .msg_enter_elem:      .ascii "Ingrese elemento ["
    .msg_enter_elem_len = . - .msg_enter_elem

    .msg_bracket:         .ascii "]["
    .msg_bracket_len = . - .msg_bracket

    .msg_eq:              .ascii "]: "
    .msg_eq_len = . - .msg_eq

    .msg_err_dim:         .ascii "Error: Dimensiones invalidas\n"
    .msg_err_dim_len = . - .msg_err_dim

    .msg_err_alloc:       .ascii "Error: Fallo asignacion de memoria\n"
    .msg_err_alloc_len = . - .msg_err_alloc

    .msg_loading:         .ascii "Cargando matriz...\n"
    .msg_loading_len = . - .msg_loading


.section .text

// =============================================================================
// matrix_init
// Inicializa los tres descriptores poniendolos todos en STATUS_FREE.
// Se debe llamar UNA VEZ al inicio del programa (desde _start o main).
//
// ENTRADA: ninguna
// SALIDA:  ninguna
//
// IMPLEMENTACION: simplemente escribimos 0 en el campo STATUS de cada descriptor.
// Como .bss ya viene en 0, esto es redundante pero explicito y seguro.
// =============================================================================
matrix_init:
    stp x29, x30, [sp, #-16]!
    mov x29, sp

    // Poner STATUS_FREE (=0) en los tres descriptores
    adr x0, mat_A
    str xzr, [x0, #DESC_STATUS]   // mat_A.STATUS = 0
    adr x0, mat_B
    str xzr, [x0, #DESC_STATUS]   // mat_B.STATUS = 0
    adr x0, mat_R
    str xzr, [x0, #DESC_STATUS]   // mat_R.STATUS = 0

    ldp x29, x30, [sp], #16
    ret

// =============================================================================
// matrix_load
// Pide al usuario filas, columnas y cada elemento. Reserva memoria con mmap.
// Si el descriptor ya tenia datos, los libera primero (matrix_resize).
//
// ENTRADA:
//   x0 = puntero al descriptor (mat_A, mat_B o mat_R)
//   x1 = puntero al nombre de la matriz (cadena ASCII, ej: "A")
//   x2 = longitud del nombre
//
// SALIDA:
//   x0 = ERR_OK si exito, codigo de error si fallo
//
// REGISTROS PRESERVADOS: x19-x26
// =============================================================================
matrix_load:
    stp x29, x30, [sp, #-80]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    stp x25, x26, [sp, #64]

    mov x19, x0                    // x19 = puntero al descriptor
    mov x20, x1                    // x20 = puntero al nombre
    mov x21, x2                    // x21 = longitud del nombre

    // PASO 1: Pedir numero de filas
    adr x0, .msg_enter_rows
    mov x1, #.msg_enter_rows_len
    bl io_print_str

    bl io_read_int                 // leer entero -> x0 = valor Q32.32, x1 = error
    cmp x1, #ERR_OK
    bne .ml_err_invalid

    asr x22, x0, #Q32_SHIFT        // x22 = filas (extraer parte entera)

    // Validar filas: 1 <= filas <= MAX_ROWS
    cmp x22, #1
    blt .ml_err_range
    cmp x22, #MAX_ROWS
    bgt .ml_err_range

    // PASO 2: Pedir numero de columnas
    adr x0, .msg_enter_cols
    mov x1, #.msg_enter_cols_len
    bl io_print_str

    bl io_read_int
    cmp x1, #ERR_OK
    bne .ml_err_invalid

    asr x23, x0, #Q32_SHIFT        // x23 = columnas

    // Validar columnas
    cmp x23, #1
    blt .ml_err_range
    cmp x23, #MAX_COLS
    bgt .ml_err_range

    // PASO 3: Reservar memoria para los datos
    // Llamar matrix_resize para manejar la posible liberacion de datos anteriores
    mov x0, x19                    // x0 = descriptor
    mov x1, x22                    // x1 = filas
    mov x2, x23                    // x2 = columnas
    bl matrix_resize               // reservar memoria y actualizar descriptor
    cmp x0, #ERR_OK
    bne .ml_err_alloc

    // PASO 4: Pedir valores de cada celda
    adr x0, .msg_loading
    mov x1, #.msg_loading_len
    bl io_print_str

    ldr x24, [x19, #DESC_DATA]     // x24 = puntero al bloque de datos
    mov x25, #0                    // x25 = i (fila actual)

.ml_row_loop:
    cmp x25, x22                   // i >= filas?
    bge .ml_done

    mov x26, #0                    // x26 = j (columna actual)

.ml_col_loop:
    cmp x26, x23                   // j >= columnas?
    bge .ml_next_row

    // Imprimir prompt: "a[i][j] = "
    adr x0, .msg_enter_elem
    mov x1, #.msg_enter_elem_len
    bl io_print_str

    // Imprimir i
    lsl x0, x25, #Q32_SHIFT        // convertir i a Q32.32 para io_print_int
    bl io_print_int

    adr x0, .msg_bracket
    mov x1, #.msg_bracket_len
    bl io_print_str

    // Imprimir j
    lsl x0, x26, #Q32_SHIFT
    bl io_print_int

    adr x0, .msg_eq
    mov x1, #.msg_eq_len
    bl io_print_str

    // Leer el valor del usuario
    bl io_read_int
    cmp x1, #ERR_OK
    bne .ml_err_invalid

    // Guardar en A[i][j]: indice = i * COLS + j, offset = indice * 8
    mul x1, x25, x23               // x1 = i * COLS
    add x1, x1, x26                // x1 = i * COLS + j
    lsl x1, x1, #3                 // x1 = offset en bytes (* 8)
    str x0, [x24, x1]              // guardar valor Q32.32 en el bloque de datos

    add x26, x26, #1               // j++
    b .ml_col_loop

.ml_next_row:
    add x25, x25, #1               // i++
    b .ml_row_loop

.ml_done:
    mov x0, #ERR_OK
    b .ml_ret

.ml_err_invalid:
    mov x0, #ERR_INVALID
    b .ml_ret

.ml_err_range:
    adr x0, .msg_err_dim
    mov x1, #.msg_err_dim_len
    bl io_print_str
    mov x0, #ERR_RANGE
    b .ml_ret

.ml_err_alloc:
    adr x0, .msg_err_alloc
    mov x1, #.msg_err_alloc_len
    bl io_print_str
    mov x0, #ERR_ALLOC
    b .ml_ret

.ml_ret:
    ldp x25, x26, [sp, #64]
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #80
    ret


// =============================================================================
// matrix_resize
// Libera el bloque de datos anterior (si existe) y reserva uno nuevo con mmap.
// Actualiza todos los campos del descriptor.
//
// ENTRADA:
//   x0 = puntero al descriptor
//   x1 = nuevas filas
//   x2 = nuevas columnas
//
// SALIDA:
//   x0 = ERR_OK si exito, ERR_ALLOC si fallo mmap
//
// LOGICA:
//   Si STATUS == USED, llamar munmap para liberar el bloque anterior.
//   Luego calcular nuevo tamano, llamar mmap, y actualizar el descriptor.
//
// NOTA SOBRE MMAP:
//   mmap(addr=0, size, prot=RW, flags=PRIVATE|ANON, fd=-1, offset=0)
//   Si el kernel no puede dar memoria, devuelve un valor >= 0xFFFFFFFFFFFFF000
//   que se interpreta como negativo en entero con signo.
// =============================================================================
matrix_resize:
    stp x29, x30, [sp, #-64]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]

    mov x19, x0                    // x19 = descriptor
    mov x20, x1                    // x20 = filas
    mov x21, x2                    // x21 = columnas

    // PASO 1: si habia datos, liberar con munmap
    ldr x22, [x19, #DESC_STATUS]   // x22 = STATUS
    cmp x22, #STATUS_USED
    bne .mr_alloc                  // si no habia datos, saltar directo a reservar

    // Hay datos previos: liberar con munmap(DATA, BYTES)
    ldr x0, [x19, #DESC_DATA]      // x0 = puntero al bloque anterior
    ldr x1, [x19, #DESC_BYTES]     // x1 = tamano del bloque anterior
    mov x8, #SYS_MUNMAP            // syscall munmap
    svc #0
    // Ignoramos el valor de retorno de munmap (limpiamos igual)

.mr_alloc:
    // PASO 2: calcular el tamano del nuevo bloque
    // ELEMS = filas * columnas
    // BYTES = ELEMS * 8 (cada elemento Q32.32 ocupa 8 bytes)
    mul x22, x20, x21              // x22 = ELEMS = filas * columnas
    lsl x23, x22, #3               // x23 = BYTES = ELEMS * 8

    // PASO 3: reservar nuevo bloque con mmap
    // mmap(addr=0, size=BYTES, prot=PROT_RW, flags=PRIVATE|ANON, fd=-1, offset=0)
    mov x0, #0                     // addr = 0 (el kernel elige la direccion)
    mov x1, x23                    // size = BYTES
    mov x2, #MMAP_PROT_RW          // prot = PROT_READ | PROT_WRITE
    mov x3, #MMAP_FLAGS            // flags = MAP_PRIVATE | MAP_ANONYMOUS
    mov x4, #-1                    // fd = -1 (sin archivo)
    mov x5, #0                     // offset = 0
    mov x8, #SYS_MMAP              // syscall mmap
    svc #0
    // x0 = nueva direccion (o valor negativo si fallo)

    // Verificar si mmap fallo (resultado negativo en complemento a 2)
    tbnz x0, #63, .mr_err_alloc    // si bit 63 = 1, mmap fallo

    // PASO 4: actualizar el descriptor con los nuevos valores
    mov x24, x0                    // x24 = nueva direccion (DATA)

    str xzr, [x19, #DESC_RSVD1]   // limpiar campo reservado
    str xzr, [x19, #DESC_RSVD2]   // limpiar campo reservado
    mov x0, #STATUS_USED
    str x0,  [x19, #DESC_STATUS]  // STATUS = USED (descriptor activo)
    str x20, [x19, #DESC_ROWS]    // ROWS = filas
    str x21, [x19, #DESC_COLS]    // COLS = columnas
    str x22, [x19, #DESC_ELEMS]   // ELEMS = filas * columnas
    str x23, [x19, #DESC_BYTES]   // BYTES = ELEMS * 8
    str x24, [x19, #DESC_DATA]    // DATA = puntero al nuevo bloque mmap
    // NOTA: mmap con MAP_ANONYMOUS garantiza que el bloque viene en cero,
    // por lo que todos los elementos ya son 0 en Q32.32 (= 0.0).

    mov x0, #ERR_OK
    b .mr_done

.mr_err_alloc:
    // Marcar descriptor como libre porque no tenemos memoria
    str xzr, [x19, #DESC_STATUS]  // STATUS = FREE
    str xzr, [x19, #DESC_DATA]    // DATA = 0 (puntero invalido)
    mov x0, #ERR_ALLOC

.mr_done:
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #64
    ret

// =============================================================================
// matrix_free
// Libera el bloque de datos de un descriptor y lo marca como FREE.
//
// ENTRADA:
//   x0 = puntero al descriptor
//
// SALIDA: ninguna
// =============================================================================
matrix_free:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    stp x19, x20, [sp, #16]

    mov x19, x0                    // x19 = descriptor

    // Verificar si tiene datos
    ldr x20, [x19, #DESC_STATUS]
    cmp x20, #STATUS_USED
    bne .mf_done                   // si ya es FREE, no hacer nada

    // Llamar munmap para liberar el bloque de datos
    ldr x0, [x19, #DESC_DATA]      // x0 = puntero al bloque
    ldr x1, [x19, #DESC_BYTES]     // x1 = tamano del bloque
    mov x8, #SYS_MUNMAP
    svc #0

    // Limpiar todos los campos del descriptor
    str xzr, [x19, #DESC_STATUS]
    str xzr, [x19, #DESC_ROWS]
    str xzr, [x19, #DESC_COLS]
    str xzr, [x19, #DESC_ELEMS]
    str xzr, [x19, #DESC_BYTES]
    str xzr, [x19, #DESC_DATA]

.mf_done:
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

// =============================================================================
// matrix_free_all
// Libera A, B y R.
// =============================================================================
matrix_free_all:
    stp x29, x30, [sp, #-16]!
    mov x29, sp

    adr x0, mat_A
    bl matrix_free
    adr x0, mat_B
    bl matrix_free
    adr x0, mat_R
    bl matrix_free

    ldp x29, x30, [sp], #16
    ret

// =============================================================================
// matrix_copy_desc
// Copia el DESCRIPTOR COMPLETO de src a dst.
// IMPORTANTE: NO se duplica el bloque de datos; dst.DATA apuntara al mismo bloque.
// Esto se usa para mover R -> A o R -> B:
//   1. Si dst tenia datos propios, liberar con munmap primero.
//   2. Copiar todos los campos del descriptor src a dst.
//   3. Marcar src como FREE (para que no duplique la responsabilidad del bloque).
//
// ENTRADA:
//   x0 = puntero al descriptor DESTINO (ej: mat_A)
//   x1 = puntero al descriptor FUENTE  (ej: mat_R)
//
// SALIDA: ninguna
// =============================================================================
matrix_copy_desc:
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]

    mov x19, x0                    // x19 = destino
    mov x20, x1                    // x20 = fuente

    // PASO 1: si el destino ya tiene datos, liberarlos con munmap
    ldr x21, [x19, #DESC_STATUS]
    cmp x21, #STATUS_USED
    bne .mcd_copy

    ldr x0, [x19, #DESC_DATA]      // liberar bloque anterior del destino
    ldr x1, [x19, #DESC_BYTES]
    mov x8, #SYS_MUNMAP
    svc #0

.mcd_copy:
    // PASO 2: copiar campo por campo del descriptor fuente al destino
    // Copiamos los 64 bytes usando 8 cargas/almacenes de 8 bytes
    ldr x21, [x20, #DESC_STATUS]
    str x21, [x19, #DESC_STATUS]
    ldr x21, [x20, #DESC_ROWS]
    str x21, [x19, #DESC_ROWS]
    ldr x21, [x20, #DESC_COLS]
    str x21, [x19, #DESC_COLS]
    ldr x21, [x20, #DESC_ELEMS]
    str x21, [x19, #DESC_ELEMS]
    ldr x21, [x20, #DESC_BYTES]
    str x21, [x19, #DESC_BYTES]
    ldr x21, [x20, #DESC_DATA]
    str x21, [x19, #DESC_DATA]     // ahora AMBOS apuntan al mismo bloque
    ldr x21, [x20, #DESC_RSVD1]
    str x21, [x19, #DESC_RSVD1]
    ldr x21, [x20, #DESC_RSVD2]
    str x21, [x19, #DESC_RSVD2]

    // PASO 3: marcar el descriptor fuente como FREE (transfiere la propiedad)
    // Esto evita que el bloque de datos sea liberado dos veces.
    str xzr, [x20, #DESC_STATUS]
    str xzr, [x20, #DESC_ROWS]
    str xzr, [x20, #DESC_COLS]
    str xzr, [x20, #DESC_ELEMS]
    str xzr, [x20, #DESC_BYTES]
    str xzr, [x20, #DESC_DATA]    // fuente ya no "posee" el bloque

    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #48
    ret

// =============================================================================
// matrix_get_elem
// Obtiene el valor Q32.32 del elemento A[i][j].
//
// ENTRADA:
//   x0 = puntero al descriptor
//   x1 = i (fila, base 0)
//   x2 = j (columna, base 0)
//
// SALIDA:
//   x0 = valor A[i][j] en Q32.32
//   x1 = ERR_OK o ERR_RANGE si (i,j) esta fuera de rango
// =============================================================================
matrix_get_elem:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    stp x19, x20, [sp, #16]

    mov x19, x0                    // x19 = descriptor

    // Validar que i < ROWS y j < COLS
    ldr x20, [x19, #DESC_ROWS]
    cmp x1, x20
    bge .mge_err_range
    ldr x20, [x19, #DESC_COLS]
    cmp x2, x20
    bge .mge_err_range

    // Calcular offset: (i * COLS + j) * 8
    mul x20, x1, x20               // x20 = i * COLS
    add x20, x20, x2               // x20 = i * COLS + j
    lsl x20, x20, #3               // x20 = offset en bytes

    ldr x0, [x19, #DESC_DATA]      // x0 = puntero base de datos
    ldr x0, [x0, x20]              // x0 = A[i][j]
    mov x1, #ERR_OK
    b .mge_done

.mge_err_range:
    mov x0, #0
    mov x1, #ERR_RANGE

.mge_done:
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

// =============================================================================
// matrix_set_elem
// Escribe un valor Q32.32 en la posicion A[i][j].
//
// ENTRADA:
//   x0 = puntero al descriptor
//   x1 = i (fila)
//   x2 = j (columna)
//   x3 = valor Q32.32 a escribir
//
// SALIDA:
//   x0 = ERR_OK o ERR_RANGE
// =============================================================================
matrix_set_elem:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    stp x19, x20, [sp, #16]

    mov x19, x0

    ldr x20, [x19, #DESC_ROWS]
    cmp x1, x20
    bge .mse_err_range
    ldr x20, [x19, #DESC_COLS]
    cmp x2, x20
    bge .mse_err_range

    mul x20, x1, x20               // i * COLS
    add x20, x20, x2               // + j
    lsl x20, x20, #3               // * 8
    ldr x0, [x19, #DESC_DATA]
    str x3, [x0, x20]              // A[i][j] = valor
    mov x0, #ERR_OK
    b .mse_done

.mse_err_range:
    mov x0, #ERR_RANGE

.mse_done:
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

// =============================================================================
// matrix_validate
// Verifica que un descriptor es valido: no nulo y STATUS == USED.
//
// ENTRADA:
//   x0 = puntero al descriptor
//
// SALIDA:
//   x0 = ERR_OK si valido, ERR_EMPTY si no tiene datos, ERR_INVALID si puntero nulo
// =============================================================================
matrix_validate:
    cbz x0, .mv_null               // si x0 == 0, puntero nulo
    ldr x1, [x0, #DESC_STATUS]
    cmp x1, #STATUS_USED
    bne .mv_empty
    mov x0, #ERR_OK
    ret
.mv_null:
    mov x0, #ERR_INVALID
    ret
.mv_empty:
    mov x0, #ERR_EMPTY
    ret