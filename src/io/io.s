// =============================================================================
// src/io/io.s
// Modulo de Entrada/Salida
//
// Funciones exportadas:
//   io_print_str   : imprime una cadena (puntero + longitud)
//   io_print_int   : imprime un entero con signo (parte entera de Q32.32)
//   io_read_int    : lee un entero desde stdin, devuelve valor en Q32.32
//   io_print_nl    : imprime un salto de linea
//   io_print_matrix: imprime una matriz completa con formato visual
//   io_print_char  : imprime un solo caracter
//
// NINGUNA funcion de este modulo usa printf, scanf, malloc ni free.
// Todo se hace via syscalls Linux directamente.
// =============================================================================

.include "include/defines.inc"

// Exportar simbolos para que otros archivos los vean
.global io_print_str
.global io_print_int
.global io_read_int
.global io_print_nl
.global io_print_matrix
.global io_print_char
.global io_print_str_ln

// -----------------------------------------------------------------------------
// Datos locales: buffer temporal para conversion de enteros a texto
// -----------------------------------------------------------------------------
.section .bss
    io_buf:     .skip IO_BUF_SIZE   // buffer para conversion int->string
    io_in_buf:  .skip IO_BUF_SIZE   // buffer para leer desde stdin

.section .text

// =============================================================================
// io_print_str
// Imprime una cadena de texto en stdout usando syscall write.
//
// ENTRADA:
//   x0 = puntero al inicio de la cadena (direccion en memoria)
//   x1 = longitud de la cadena en bytes
//
// SALIDA: ninguna (no modifica registros preservados)
//
// REGISTROS USADOS (caller-saved, no necesitan preservarse):
//   x0 = fd (stdout=1), luego apuntador
//   x1 = longitud
//   x2 = longitud (copia)
//   x8 = numero de syscall (SYS_WRITE=64)
// =============================================================================
io_print_str:
    // Guardar LR porque no llamamos a nadie mas, pero si lo llaman anidado necesitamos
    stp x29, x30, [sp, #-16]!      // guardar frame pointer y link register en la pila
    mov x29, sp                     // actualizar frame pointer

    mov x2, x1                      // x2 = longitud de la cadena
    mov x1, x0                      // x1 = puntero a la cadena (argumento 2 de write)
    mov x0, #FD_STDOUT              // x0 = 1 (stdout, argumento 1 de write)
    mov x8, #SYS_WRITE              // x8 = 64 (numero de syscall write)
    svc #0                          // llamar al kernel: write(stdout, ptr, len)
    // El kernel devuelve en x0 el numero de bytes escritos (ignoramos)

    ldp x29, x30, [sp], #16        // restaurar frame pointer y link register
    ret                             // volver al llamador

// =============================================================================
// io_print_str_ln
// Igual que io_print_str pero agrega un salto de linea al final.
//
// ENTRADA:
//   x0 = puntero a la cadena
//   x1 = longitud
// =============================================================================
io_print_str_ln:
    stp x29, x30, [sp, #-16]!
    mov x29, sp

    bl io_print_str                 // imprimir la cadena
    bl io_print_nl                  // imprimir salto de linea

    ldp x29, x30, [sp], #16
    ret

// =============================================================================
// io_print_nl
// Imprime un salto de linea ('\n') en stdout.
//
// ENTRADA: ninguna
// SALIDA: ninguna
// =============================================================================
io_print_nl:
    stp x29, x30, [sp, #-16]!
    mov x29, sp

    adr x1, .nl_char               // x1 = direccion del caracter '\n'
    mov x2, #1                     // x2 = longitud = 1 byte
    mov x0, #FD_STDOUT             // x0 = stdout
    mov x8, #SYS_WRITE             // syscall write
    svc #0

    ldp x29, x30, [sp], #16
    ret

.nl_char:
    .byte '\n'

// =============================================================================
// io_print_char
// Imprime un solo caracter en stdout.
//
// ENTRADA:
//   x0 = el caracter a imprimir (como entero, solo se usa el byte bajo)
// =============================================================================
io_print_char:
    stp x29, x30, [sp, #-32]!      // -32 para alinear a 16 y tener espacio
    mov x29, sp

    // Guardar el caracter en la pila temporalmente
    strb w0, [sp, #16]             // escribir 1 byte en la pila (en espacio alineado)
    add x1, sp, #16                // x1 = direccion del byte en pila
    mov x2, #1                     // x2 = longitud = 1 byte
    mov x0, #FD_STDOUT
    mov x8, #SYS_WRITE
    svc #0

    ldp x29, x30, [sp], #32
    ret

// =============================================================================
// io_print_int
// Imprime un entero con signo. El valor de entrada esta en formato Q32.32,
// por lo que primero extraemos la parte entera (bits 63..32).
//
// ENTRADA:
//   x0 = valor en formato Q32.32
//
// SALIDA: ninguna (imprime en stdout)
//
// COMO FUNCIONA LA CONVERSION INT -> TEXTO:
//   1. Extraer parte entera con ASR #32
//   2. Si es negativo, imprimir '-' y negar el numero
//   3. Dividir repetidamente entre 10, el residuo es el digito (en orden inverso)
//   4. Guardar digitos en buffer, luego imprimir en orden correcto
//
// REGISTROS:
//   x19 = valor absoluto del entero (preservado)
//   x20 = puntero al final del buffer (vamos llenando de atras hacia adelante)
//   x21 = residuo de la division (digito actual)
//   x22 = cociente de la division
// =============================================================================
io_print_int:
    // Preservar registros callee-saved que vamos a usar
    stp x29, x30, [sp, #-48]!      // guardar FP y LR
    mov x29, sp
    stp x19, x20, [sp, #16]        // guardar x19, x20
    stp x21, x22, [sp, #32]        // guardar x21, x22

    // PASO 1: extraer parte entera del valor Q32.32
    // ASR = Arithmetic Shift Right (preserva el bit de signo)
    asr x19, x0, #Q32_SHIFT        // x19 = parte entera con signo

    // PASO 2: preparar el buffer de salida
    // Llenamos el buffer de ATRAS hacia ADELANTE (porque los digitos salen al reves)
    adr x20, io_buf                 // x20 = inicio del buffer
    add x20, x20, #IO_BUF_SIZE     // x20 apunta AL FINAL del buffer (pasado el ultimo byte)
    sub x20, x20, #1               // x20 = ultimo byte del buffer (guardamos nulo o primer char)

    // Caso especial: si x19 == 0, imprimir "0" directamente
    cbnz x19, .pint_nonzero        // si x19 != 0, saltar a conversion
    mov x0, #'0'
    bl io_print_char
    b .pint_done

.pint_nonzero:
    // PASO 3: manejar el signo
    // tbz = Test Bit and branch if Zero
    // el bit 63 es el signo en complemento a 2
    tbz x19, #63, .pint_positive   // si bit 63 = 0, es positivo
    // Es negativo:
    neg x19, x19                   // x19 = abs(x19) = -x19
    // Imprimimos el signo despues, al inicio de la cadena

.pint_positive:
    // PASO 4: convertir a digitos ASCII en el buffer (de atras hacia adelante)
    // Dividimos x19 entre 10 repetidamente
    // La instruccion UDIV calcula cociente, luego MSUB calcula residuo
    mov x22, #10                   // x22 = divisor

.pint_loop:
    // udiv xDest, xNum, xDiv -> xDest = xNum / xDiv (division sin signo)
    udiv x21, x19, x22             // x21 = x19 / 10 (cociente)
    // msub xDest, xA, xB, xC -> xDest = xC - (xA * xB)
    msub x19, x21, x22, x19       // x19 = x19 - (x21 * 10) = residuo = digito actual
    add x19, x19, #'0'             // convertir digito [0-9] a ASCII ['0'-'9']
    strb w19, [x20]                // guardar el caracter ASCII en el buffer
    sub x20, x20, #1               // mover el puntero una posicion hacia atras
    mov x19, x21                   // x19 = cociente (siguiente numero a dividir)
    cbnz x19, .pint_loop           // si quedan digitos, continuar

    // PASO 5: si era negativo, agregar el signo '-' al inicio
    // Revisar si el valor original era negativo (bit 63 de x0)
    tbz x0, #63, .pint_print       // si el original era positivo, saltar a imprimir
    mov x0, #'-'
    bl io_print_char                // imprimir el signo negativo

.pint_print:
    // PASO 6: imprimir los digitos del buffer (de x20+1 hasta el final)
    add x0, x20, #1                // x0 = primer digito (x20 apunta antes del primero)
    adr x1, io_buf
    add x1, x1, #IO_BUF_SIZE      // x1 = justo despues del buffer
    sub x1, x1, x0                 // x1 = longitud = fin - inicio
    bl io_print_str                 // imprimir la cadena de digitos

.pint_done:
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #48
    ret

// =============================================================================
// io_read_int
// Lee un entero con signo desde stdin.
// Devuelve el valor convertido a formato Q32.32.
//
// ENTRADA: ninguna
//
// SALIDA:
//   x0 = valor leido en formato Q32.32  (ej: si el usuario escribe 5, devuelve 5 << 32)
//   x1 = ERR_OK (0) si tuvo exito, ERR_INVALID (-1) si no pudo leer
//
// ALGORITMO:
//   1. Leer bytes de stdin hasta encontrar '\n' o EOF
//   2. Saltar espacios iniciales
//   3. Detectar signo opcional '-' o '+'
//   4. Convertir digitos ASCII a numero: n = n*10 + (char - '0')
//   5. Convertir a Q32.32 y devolver
//
// REGISTROS PRESERVADOS: x19-x25
// =============================================================================
io_read_int:
    stp x29, x30, [sp, #-64]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]

    // PASO 1: leer bytes desde stdin al buffer io_in_buf
    adr x1, io_in_buf              // x1 = buffer destino
    mov x2, #IO_BUF_SIZE           // x2 = maximo de bytes a leer
    mov x0, #FD_STDIN              // x0 = stdin
    mov x8, #SYS_READ              // syscall read
    svc #0
    // x0 = numero de bytes leidos (negativo si error)
    mov x19, x0                    // x19 = bytes leidos
    cmp x19, #0
    ble .rdi_error                 // si 0 o negativo, error de lectura

    // PASO 2: inicializar
    adr x20, io_in_buf             // x20 = puntero actual en el buffer
    mov x21, #0                    // x21 = valor acumulado (resultado)
    mov x22, #1                    // x22 = signo (1 = positivo, -1 = negativo)
    mov x23, #0                    // x23 = indice de bytes leidos

    // Saltar espacios y tabulaciones iniciales
.rdi_skip_space:
    cmp x23, x19
    bge .rdi_error                 // llegamos al fin sin encontrar digito
    ldrb w24, [x20, x23]           // x24 = caracter actual
    cmp x24, #' '
    beq .rdi_next_skip
    cmp x24, #'\t'
    beq .rdi_next_skip
    b .rdi_check_sign
.rdi_next_skip:
    add x23, x23, #1
    b .rdi_skip_space

    // PASO 3: detectar signo
.rdi_check_sign:
    cmp x24, #'-'
    bne .rdi_check_plus
    mov x22, #-1                   // negativo
    add x23, x23, #1               // avanzar al siguiente caracter
    b .rdi_digits

.rdi_check_plus:
    cmp x24, #'+'
    bne .rdi_digits
    add x23, x23, #1               // ignorar '+', ya asumimos positivo

    // PASO 4: procesar digitos
.rdi_digits:
    cmp x23, x19
    bge .rdi_finalize              // fin del buffer
    ldrb w24, [x20, x23]           // caracter actual
    cmp x24, #'\n'
    beq .rdi_finalize              // fin de linea
    cmp x24, #'\r'
    beq .rdi_finalize
    sub x24, x24, #'0'             // convertir ASCII a valor numerico
    cmp x24, #0
    blt .rdi_finalize              // caracter no es digito, terminar
    cmp x24, #9
    bgt .rdi_finalize

    // x21 = x21 * 10 + digito
    mov x0, #10
    mul x21, x21, x0              // x21 = x21 * 10
    add x21, x21, x24             // x21 += digito
    add x23, x23, #1
    b .rdi_digits

.rdi_finalize:
    // PASO 5: aplicar signo
    mul x21, x21, x22             // x21 = valor con signo

    // PASO 6: convertir a Q32.32 (desplazar 32 bits a la izquierda)
    lsl x0, x21, #Q32_SHIFT       // x0 = valor en Q32.32

    mov x1, #ERR_OK
    b .rdi_done

.rdi_error:
    mov x0, #0
    mov x1, #ERR_INVALID

.rdi_done:
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #64
    ret

// =============================================================================
// io_print_matrix
// Imprime una matriz completa en formato visual de filas y columnas.
//
// Formato de salida (ejemplo para 2x3):
//   [ 1  2  3 ]
//   [ 4  5  6 ]
//
// ENTRADA:
//   x0 = puntero al descriptor de la matriz (ver defines.inc)
//
// SALIDA: ninguna
//
// ACCESO A ELEMENTO A[i][j] con row-major:
//   indice = i * COLS + j
//   offset = indice * 8   (cada elemento ocupa 8 bytes en Q32.32)
//   direccion = DATA + offset
//
// REGISTROS PRESERVADOS: x19-x27
// =============================================================================
io_print_matrix:
    stp x29, x30, [sp, #-80]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    stp x25, x26, [sp, #64]

    // x19 = puntero al descriptor (lo preservamos durante todo el recorrido)
    mov x19, x0

    // Verificar que el descriptor sea valido (STATUS debe ser USED)
    ldr x20, [x19, #DESC_STATUS]   // x20 = STATUS
    cmp x20, #STATUS_USED
    bne .pm_empty                  // si no esta activo, reportar matriz vacia

    // Cargar dimensiones del descriptor
    ldr x20, [x19, #DESC_ROWS]     // x20 = numero de filas
    ldr x21, [x19, #DESC_COLS]     // x21 = numero de columnas
    ldr x22, [x19, #DESC_DATA]     // x22 = puntero al bloque de datos

    // i = 0 (indice de fila actual)
    mov x23, #0                    // x23 = i (fila)

.pm_row_loop:
    cmp x23, x20                   // i >= ROWS?
    bge .pm_done                   // si, terminamos

    // Imprimir "[ " al inicio de la fila
    adr x0, .pm_bracket_open
    mov x1, #2
    bl io_print_str

    // j = 0 (indice de columna actual)
    mov x24, #0                    // x24 = j (columna)

.pm_col_loop:
    cmp x24, x21                   // j >= COLS?
    bge .pm_end_col                // si, cerrar la fila

    // Calcular offset del elemento A[i][j] en row-major:
    // indice = i * COLS + j
    // offset = indice * 8 (LSL #3)
    mul x25, x23, x21              // x25 = i * COLS
    add x25, x25, x24             // x25 = i * COLS + j
    lsl x25, x25, #3               // x25 = (i * COLS + j) * 8 (offset en bytes)
    ldr x0, [x22, x25]             // x0 = A[i][j] en Q32.32

    // Imprimir el valor (io_print_int extrae la parte entera)
    bl io_print_int

    // Si no es el ultimo elemento de la fila, imprimir separador
    add x26, x24, #1               // x26 = j + 1
    cmp x26, x21                   // (j+1) >= COLS?
    bge .pm_no_sep
    adr x0, .pm_sep
    mov x1, #2
    bl io_print_str                 // imprimir "  " (dos espacios)

.pm_no_sep:
    add x24, x24, #1               // j++
    b .pm_col_loop

.pm_end_col:
    // Imprimir " ]" al final de la fila y salto de linea
    adr x0, .pm_bracket_close
    mov x1, #2
    bl io_print_str
    bl io_print_nl

    add x23, x23, #1               // i++
    b .pm_row_loop

.pm_empty:
    adr x0, .pm_empty_msg
    mov x1, #16
    bl io_print_str_ln
    b .pm_done

.pm_done:
    ldp x25, x26, [sp, #64]
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #80
    ret

// Datos de cadenas para io_print_matrix
.pm_bracket_open:   .ascii "[ "
.pm_bracket_close:  .ascii " ]"
.pm_sep:            .ascii "  "
.pm_empty_msg:      .ascii "(sin datos)     "