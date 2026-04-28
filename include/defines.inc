// =============================================================================
// include/defines.inc
// Constantes globales del sistema: syscalls, errores, descriptores y formato.
//
// CONVENCION DE REGISTROS ARM64 (AArch64 Procedure Call Standard - AAPCS64):
//   x0-x7   : argumentos de entrada / valores de retorno (caller-saved)
//   x8      : numero de syscall Linux
//   x9-x15  : registros temporales (caller-saved, la funcion llamada puede pisar)
//   x16-x17 : uso interno del linker (IP0, IP1)
//   x18     : reservado (platform register)
//   x19-x28 : registros preservados entre llamadas (callee-saved: DEBES guardar/restaurar)
//   x29     : frame pointer (FP) - apunta al marco de pila actual
//   x30     : link register (LR) - guarda la direccion de retorno
//   sp      : stack pointer - siempre alineado a 16 bytes
//   xzr     : registro cero (siempre lee 0, escrituras se descartan)
//
// NOTA SOBRE LA PILA (STACK):
//   - Crece hacia abajo en ARM64.
//   - SIEMPRE debe estar alineada a 16 bytes antes de cualquier llamada (bl).
//   - Para guardar x29 y x30: stp x29, x30, [sp, #-16]!
//   - Para restaurar:         ldp x29, x30, [sp], #16
// =============================================================================

// -----------------------------------------------------------------------------
// NUMEROS DE SYSCALL LINUX PARA AArch64
// Se colocan en x8 antes de ejecutar "svc #0"
// -----------------------------------------------------------------------------
.equ SYS_READ,    63        // leer desde descriptor de archivo (stdin=0)
.equ SYS_WRITE,   64        // escribir a descriptor de archivo (stdout=1)
.equ SYS_MMAP,    222       // reservar paginas de memoria dinamica
.equ SYS_MUNMAP,  215       // liberar paginas de memoria dinamica
.equ SYS_EXIT,    93        // terminar el proceso

// Descriptores de archivo estandar
.equ FD_STDIN,    0         // entrada estandar
.equ FD_STDOUT,   1         // salida estandar

// -----------------------------------------------------------------------------
// PARAMETROS PARA MMAP
// mmap(addr=0, size, prot, flags, fd=-1, offset=0) -> nueva direccion
// -----------------------------------------------------------------------------
.equ MMAP_PROT_RW,    3     // PROT_READ | PROT_WRITE (leer y escribir)
.equ MMAP_FLAGS,      34    // MAP_PRIVATE | MAP_ANONYMOUS (memoria privada, sin archivo)

// -----------------------------------------------------------------------------
// FORMATO Q32.32 (PUNTO FIJO)
// Cada numero se guarda en un entero de 64 bits:
//   bits 63..32 = parte entera con signo (signed integer)
//   bits 31..0  = parte fraccionaria (fraccion binaria)
//
// Ejemplo: el numero 5 se guarda como (5 << 32) = 5 * 2^32
// Para convertir entero -> Q32.32: lsl xN, xN, #32
// Para extraer parte entera:       asr xN, xN, #32
// Para multiplicar dos Q32.32:     usar mul + smulh y desplazar 32 bits
// -----------------------------------------------------------------------------
.equ Q32_SHIFT,   32        // bits de desplazamiento para conversion

// -----------------------------------------------------------------------------
// ESTRUCTURA DEL DESCRIPTOR DE MATRIZ (64 bytes por descriptor)
// Cada descriptor vive en memoria estatica (.bss) y describe UNA matriz.
// El campo DATA apunta al bloque de memoria dinamica (mmap) con los valores.
//
// Layout del descriptor (offsets en bytes):
//   +0  STATUS  : 8 bytes - 0=libre/invalido, 1=activo/tiene datos
//   +8  ROWS    : 8 bytes - numero de filas
//   +16 COLS    : 8 bytes - numero de columnas
//   +24 ELEMS   : 8 bytes - total de elementos (ROWS * COLS)
//   +32 BYTES   : 8 bytes - bytes totales del bloque de datos (ELEMS * 8)
//   +40 DATA    : 8 bytes - puntero al bloque de datos (mmap)
//   +48 RSVD1   : 8 bytes - reservado para uso futuro
//   +56 RSVD2   : 8 bytes - reservado para uso futuro
// Total: 64 bytes (8 campos * 8 bytes cada uno)
// -----------------------------------------------------------------------------
.equ DESC_SIZE,   64        // tamano total del descriptor en bytes
.equ DESC_STATUS, 0         // offset: estado del descriptor
.equ DESC_ROWS,   8         // offset: filas
.equ DESC_COLS,   16        // offset: columnas
.equ DESC_ELEMS,  24        // offset: total de elementos
.equ DESC_BYTES,  32        // offset: bytes del bloque de datos
.equ DESC_DATA,   40        // offset: puntero al bloque mmap
.equ DESC_RSVD1,  48        // offset: reservado
.equ DESC_RSVD2,  56        // offset: reservado

// Valores del campo STATUS
.equ STATUS_FREE, 0         // descriptor libre (sin datos)
.equ STATUS_USED, 1         // descriptor activo (tiene datos en DATA)

// -----------------------------------------------------------------------------
// CODIGOS DE ERROR
// Las funciones devuelven el estado en x1 (convencion de este proyecto).
// x0 = resultado principal (puntero o valor)
// x1 = codigo de error (0 = exito, negativo = error)
// -----------------------------------------------------------------------------
.equ ERR_OK,          0     // exito, sin error
.equ ERR_INVALID,    -1     // argumento invalido (null, tipo incorrecto)
.equ ERR_RANGE,      -2     // dimension invalida (0, negativa, no cuadrada si se requiere)
.equ ERR_ALLOC,      -3     // fallo al reservar memoria (mmap devolvio error)
.equ ERR_SINGULAR,   -4     // matriz singular (determinante = 0, no invertible)
.equ ERR_DIM,        -5     // dimensiones incompatibles para la operacion
.equ ERR_EMPTY,      -6     // descriptor sin datos (STATUS_FREE)

// -----------------------------------------------------------------------------
// LIMITES DEL SISTEMA
// -----------------------------------------------------------------------------
.equ MAX_ROWS,    32        // maximo de filas permitidas al ingresar
.equ MAX_COLS,    32        // maximo de columnas permitidas
.equ IO_BUF_SIZE, 64        // tamano del buffer temporal para leer/imprimir texto

// -----------------------------------------------------------------------------
// OPCIONES DEL MENU PRINCIPAL
// Se compara el caracter leido con estos valores
// -----------------------------------------------------------------------------
.equ MENU_LOAD_A,     '1'   // cargar/redimensionar matriz A
.equ MENU_LOAD_B,     '2'   // cargar/redimensionar matriz B
.equ MENU_SHOW,       '3'   // mostrar A, B y R
.equ MENU_OPERATE,    '4'   // submenu de operaciones
.equ MENU_MOVE_R_A,   '5'   // copiar resultado R -> A
.equ MENU_MOVE_R_B,   '6'   // copiar resultado R -> B
.equ MENU_FREE,       '7'   // liberar toda la memoria
.equ MENU_EXIT,       '8'   // salir del programa

// Opciones del submenu de operaciones
.equ OP_IDENTITY,     '1'   // identidad de A
.equ OP_TRANSPOSE,    '2'   // transpuesta de A
.equ OP_ADD,          '3'   // A + B
.equ OP_SUB,          '4'   // A - B
.equ OP_MUL,          '5'   // A * B (producto matricial)
.equ OP_GAUSS,        '6'   // eliminacion gaussiana de A
.equ OP_GAUSS_JORDAN, '7'   // Gauss-Jordan de A
.equ OP_INVERSE,      '8'   // inversa de A
.equ OP_DIV,          '9'   // division A / B = A * B^(-1)
.equ OP_DET,          'a'   // determinante de A
.equ OP_BACK,         '0'   // volver al menu principal