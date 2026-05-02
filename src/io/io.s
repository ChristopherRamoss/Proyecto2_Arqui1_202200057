// =============================================================================
// src/io/io.s
// Entrada / Salida via syscalls Linux AArch64. Sin libc.
//
// REGLA CRITICA ARM64 ESTATICO:
//   Simbolos en .bss y .data pueden estar a mas de 1MB del .text.
//   ADR solo alcanza +-1MB. Para CUALQUIER simbolo fuera de .text usar:
//     adrp xN, simbolo
//     add  xN, xN, :lo12:simbolo
//
// FUNCIONES EXPORTADAS:
//   io_print_str    escribe buffer a stdout
//   io_print_nl     imprime '\n'
//   io_print_char   imprime un caracter
//   io_print_int    imprime valor Q32.32 (entero + decimales si aplica)
//   io_read_int     lee entero de stdin, devuelve Q32.32
//   io_print_matrix imprime una matriz completa con formato [ v v ]
// =============================================================================

.include "include/defines.inc"

.global io_print_str
.global io_print_nl
.global io_print_char
.global io_print_int
.global io_read_int
.global io_print_matrix

// ─── .bss: buffers ────────────────────────────────────────────────────────
.section .bss
    .align 3
io_itoa_buf:  .skip 32
io_read_buf:  .skip 64

// ─── .data: cadenas de solo lectura ───────────────────────────────────────
.section .data
    .align 3
Dbopen:   .ascii "[ "
Dbclose:  .ascii " ]"
Dsep:     .ascii "  "
Dempty:   .ascii "(sin datos)"
Dnewline: .byte '\n'
Ddot:     .byte '.'

// ─── .text: codigo ────────────────────────────────────────────────────────
.section .text

// ============================================================
// io_print_str
// IN: x0 = puntero al buffer   x1 = longitud en bytes
// ============================================================
io_print_str:
    stp  x29, x30, [sp, #-16]!
    mov  x29, sp
    mov  x2, x1
    mov  x1, x0
    mov  x0, #FD_STDOUT
    mov  x8, #SYS_WRITE
    svc  #0
    ldp  x29, x30, [sp], #16
    ret

// ============================================================
// io_print_nl
// ============================================================
io_print_nl:
    stp  x29, x30, [sp, #-16]!
    mov  x29, sp
    adrp x1, Dnewline
    add  x1, x1, :lo12:Dnewline
    mov  x2, #1
    mov  x0, #FD_STDOUT
    mov  x8, #SYS_WRITE
    svc  #0
    ldp  x29, x30, [sp], #16
    ret

// ============================================================
// io_print_char
// IN: x0 = caracter (byte bajo)
// ============================================================
io_print_char:
    stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    strb w0, [sp, #16]
    add  x1, sp, #16
    mov  x2, #1
    mov  x0, #FD_STDOUT
    mov  x8, #SYS_WRITE
    svc  #0
    ldp  x29, x30, [sp], #32
    ret

// ============================================================
// INTERNO: .Lprintu  —  imprime entero SIN SIGNO desde x0
// Usa io_itoa_buf. Solo modifica x0-x5 (caller-saved).
// ============================================================
.Lprintu:
    stp  x29, x30, [sp, #-16]!
    mov  x29, sp

    cbnz x0, .Lpu_nz
    mov  x0, #'0'
    bl   io_print_char
    ldp  x29, x30, [sp], #16
    ret

.Lpu_nz:
    adrp x1, io_itoa_buf
    add  x1, x1, :lo12:io_itoa_buf
    add  x1, x1, #31          // x1 = ultimo byte del buffer
    mov  x2, #0               // x2 = contador de digitos
    mov  x3, #10              // divisor

.Lpu_loop:
    udiv x4, x0, x3           // x4 = cociente
    msub x0, x4, x3, x0      // x0 = residuo (digito)
    add  x0, x0, #'0'
    strb w0, [x1]
    sub  x1, x1, #1
    add  x2, x2, #1
    mov  x0, x4
    cbnz x0, .Lpu_loop

    add  x0, x1, #1           // x0 = puntero al primer digito
    mov  x1, x2               // x1 = longitud (numero de digitos)
    bl   io_print_str

    ldp  x29, x30, [sp], #16
    ret

// ============================================================
// io_print_int
// IN: x0 = valor en formato Q32.32
//
// Imprime la parte entera y, si hay fraccion, tambien los decimales.
// Formato: "2", "-3", "1.50", "-0.50", "0"
//
// Q32.32 significa: bits[63..32] = parte entera (con signo, complemento a 2)
//                   bits[31..0]  = fraccion (interpretada como positiva)
//
// Para valores negativos con fraccion (ej: -0.50):
//   El patron en bits es: 0xFFFFFFFF80000000
//   ASR>>32 = -1  (parte entera en complemento a 2)
//   bits bajos = 0x80000000
//   Valor real = -1 + 0x80000000/2^32 = -1 + 0.5 = -0.5
//   Para mostrar "-0.50":
//     entero visible  = parte_entera + 1 = 0
//     fraccion visible = 2^32 - bits_bajos = 0x80000000
//
// CALLEE-SAVED usados: x19 x20 x21 x22 x23
// ============================================================
io_print_int:
    stp  x29, x30, [sp, #-64]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    stp  x23, xzr, [sp, #48]

    // ── extraer parte entera (con signo) ──
    asr  x19, x0, #Q32_SHIFT    // x19 = parte entera signed

    // ── extraer bits fraccionarios (32 bits bajos sin signo) ──
    mov  x20, #0xFFFFFFFF
    and  x20, x0, x20           // x20 = fraccion bits (sin signo)

    // ── detectar signo del valor original ──
    mov  x21, #0                // x21 = 0 positivo, 1 negativo
    tbnz x0, #63, .Lpi_neg
    b    .Lpi_do_sign

.Lpi_neg:
    mov  x21, #1
    // ajuste para negativos con fraccion:
    cbz  x20, .Lpi_do_sign     // sin fraccion: no ajustar
    add  x19, x19, #1          // entero visible += 1  (ej: -1 -> 0)
    mov  x22, #1
    lsl  x22, x22, #32
    sub  x20, x22, x20         // fraccion visible = 2^32 - bits_bajos

.Lpi_do_sign:
    cbz  x21, .Lpi_int         // positivo: no imprimir '-'
    mov  x0, #'-'
    bl   io_print_char

.Lpi_int:
    // imprimir valor absoluto de la parte entera
    mov  x22, x19
    tbnz x22, #63, .Lpi_abs   // si negativo, negar
    b    .Lpi_print_int
.Lpi_abs:
    neg  x22, x22
.Lpi_print_int:
    mov  x0, x22
    bl   .Lprintu

    // ── si no hay fraccion, terminar ──
    cbz  x20, .Lpi_done

    // ── imprimir punto decimal ──
    adrp x0, Ddot
    add  x0, x0, :lo12:Ddot
    mov  x1, #1
    bl   io_print_str

    // ── calcular centesimas = (fraccion_bits * 100) >> 32 ──
    mov  x23, #100
    mul  x0, x20, x23
    lsr  x0, x0, #32           // x0 = 0..99

    // ── imprimir siempre 2 digitos ──
    cmp  x0, #10
    bge  .Lpi_2d
    // un solo digito: imprimir '0' adelante
    mov  x22, x0
    mov  x0, #'0'
    bl   io_print_char
    mov  x0, x22
    bl   .Lprintu
    b    .Lpi_done
.Lpi_2d:
    bl   .Lprintu

.Lpi_done:
    ldp  x23, xzr, [sp, #48]
    ldp  x21, x22, [sp, #32]
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #64
    ret

// ============================================================
// io_read_int
// Lee un entero con signo de stdin. Devuelve en formato Q32.32.
// OUT: x0 = valor Q32.32    x1 = ERR_OK(0) o ERR_INVALID(-1)
// CALLEE-SAVED: x19-x24
// ============================================================
io_read_int:
    stp  x29, x30, [sp, #-64]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    stp  x23, x24, [sp, #48]

    // leer bytes de stdin -> io_read_buf
    adrp x19, io_read_buf
    add  x19, x19, :lo12:io_read_buf
    mov  x0, #FD_STDIN
    mov  x1, x19
    mov  x2, #63
    mov  x8, #SYS_READ
    svc  #0
    cmp  x0, #1
    blt  .Lri_err
    mov  x20, x0               // x20 = bytes leidos
    strb wzr, [x19, x20]       // terminador nulo

    // saltar espacios
    mov  x21, #0               // x21 = indice
.Lri_sp:
    cmp  x21, x20;  bge .Lri_err
    ldrb w22, [x19, x21]
    cmp  w22, #' ';  beq .Lri_sp_adv
    cmp  w22, #'\t'; beq .Lri_sp_adv
    b    .Lri_sign
.Lri_sp_adv:
    add  x21, x21, #1;  b .Lri_sp

    // detectar signo
.Lri_sign:
    mov  x23, #1               // x23 = signo (+1 o -1)
    ldrb w22, [x19, x21]
    cmp  w22, #'-';  bne .Lri_plus
    mov  x23, #-1
    add  x21, x21, #1
    b    .Lri_dig
.Lri_plus:
    cmp  w22, #'+';  bne .Lri_dig
    add  x21, x21, #1

    // acumular digitos
.Lri_dig:
    mov  x24, #0               // x24 = valor acumulado
.Lri_loop:
    cmp  x21, x20;  bge .Lri_done
    ldrb w22, [x19, x21]
    cmp  w22, #'\n'; beq .Lri_done
    cmp  w22, #'\r'; beq .Lri_done
    sub  w22, w22, #'0'
    cmp  w22, #0;    blt .Lri_done
    cmp  w22, #9;    bgt .Lri_done
    mov  x0, #10
    mul  x24, x24, x0
    add  x24, x24, x22
    add  x21, x21, #1
    b    .Lri_loop

.Lri_done:
    mul  x24, x24, x23         // aplicar signo
    lsl  x0, x24, #Q32_SHIFT  // convertir a Q32.32
    mov  x1, #ERR_OK
    b    .Lri_ret
.Lri_err:
    mov  x0, #0
    mov  x1, #ERR_INVALID
.Lri_ret:
    ldp  x23, x24, [sp, #48]
    ldp  x21, x22, [sp, #32]
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #64
    ret

// ============================================================
// io_print_matrix
// IN: x0 = puntero al descriptor de la matriz
//
// Formato de salida (ejemplo 2x3):
//   [ 1  2  3 ]
//   [ 4  5  6 ]
//
// Acceso A[i][j]:   offset = (i * COLS + j) * 8
// CALLEE-SAVED: x19-x26
// ============================================================
io_print_matrix:
    stp  x29, x30, [sp, #-80]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    stp  x23, x24, [sp, #48]
    stp  x25, x26, [sp, #64]

    mov  x19, x0

    // verificar que el descriptor tiene datos
    ldr  x20, [x19, #DESC_STATUS]
    cmp  x20, #STATUS_USED
    bne  .Lpm_empty

    ldr  x20, [x19, #DESC_ROWS]   // x20 = filas
    ldr  x21, [x19, #DESC_COLS]   // x21 = columnas
    ldr  x22, [x19, #DESC_DATA]   // x22 = puntero a datos

    mov  x23, #0                   // i = 0
.Lpm_row:
    cmp  x23, x20;  bge .Lpm_done

    adrp x0, Dbopen;  add x0, x0, :lo12:Dbopen
    mov  x1, #2;  bl io_print_str

    mov  x24, #0                   // j = 0
.Lpm_col:
    cmp  x24, x21;  bge .Lpm_erow

    // offset = (i*COLS + j)*8
    mul  x25, x23, x21
    add  x25, x25, x24
    lsl  x25, x25, #3
    ldr  x0, [x22, x25]           // A[i][j] en Q32.32
    bl   io_print_int

    // separador "  " si no es el ultimo de la fila
    add  x26, x24, #1
    cmp  x26, x21;  bge .Lpm_nosep
    adrp x0, Dsep;  add x0, x0, :lo12:Dsep
    mov  x1, #2;  bl io_print_str
.Lpm_nosep:
    add  x24, x24, #1;  b .Lpm_col

.Lpm_erow:
    adrp x0, Dbclose;  add x0, x0, :lo12:Dbclose
    mov  x1, #2;  bl io_print_str
    bl   io_print_nl
    add  x23, x23, #1;  b .Lpm_row

.Lpm_empty:
    adrp x0, Dempty;  add x0, x0, :lo12:Dempty
    mov  x1, #11;  bl io_print_str
    bl   io_print_nl

.Lpm_done:
    ldp  x25, x26, [sp, #64]
    ldp  x23, x24, [sp, #48]
    ldp  x21, x22, [sp, #32]
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #80
    ret