// =============================================================================
// src/io/io.s  —  Entrada / Salida via syscalls Linux AArch64
// Sin libc: solo read(63), write(64).
// =============================================================================

.include "include/defines.inc"

.global io_print_str
.global io_print_nl
.global io_print_char
.global io_print_int
.global io_read_int
.global io_print_matrix

// ─── buffers en .bss ──────────────────────────────────────────────────────
.section .bss
    .align 3
io_itoa_buf:  .skip 32
io_read_buf:  .skip 64

// ─── cadenas de solo lectura en .data ─────────────────────────────────────
.section .data
    .align 3
.Lbopen_d:   .ascii "[ "
.Lbclose_d:  .ascii " ]"
.Lsep_d:     .ascii "  "
.Lempty_d:   .ascii "(sin datos)"
.Lnewline_d: .byte '\n'

// ─── codigo ───────────────────────────────────────────────────────────────
.section .text

// ============================================================
// io_print_str — escribe x1 bytes desde x0 a stdout
// IN:  x0 = puntero   x1 = longitud
// Usa solo caller-saved: x0-x2, x8
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
// io_print_nl — imprime '\n'
// ============================================================
io_print_nl:
    stp  x29, x30, [sp, #-16]!
    mov  x29, sp
    adr  x1, .Lnewline_d
    mov  x2, #1
    mov  x0, #FD_STDOUT
    mov  x8, #SYS_WRITE
    svc  #0
    ldp  x29, x30, [sp], #16
    ret

// ============================================================
// io_print_char — imprime 1 byte desde x0
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
// io_print_int — imprime parte entera de un valor Q32.32
// IN:  x0 = valor Q32.32
//
// ALGORITMO:
//   1. asr x0, #32  -> extraer parte entera con signo
//   2. caso cero: imprimir '0' directo
//   3. negativo: guardar flag, negar valor
//   4. bucle: extraer digitos de atras hacia adelante en buffer
//   5. imprimir signo + digitos
//
// FIX DEL BUG ORIGINAL:
//   El buffer se llena de ATRAS hacia ADELANTE.
//   Al terminar, x20 apunta UNA POSICION ANTES del primer digito.
//   Por tanto: inicio = x20+1,  fin = inicio + n_digitos
//   La longitud se calcula ANTES de mover x20, contando cuantos
//   digitos insertamos, NO por diferencia de punteros al final.
//
// CALLEE-SAVED usados: x19 x20 x21 x22
// ============================================================
io_print_int:
    stp  x29, x30, [sp, #-48]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]

    // ── extraer parte entera ──
    asr  x19, x0, #Q32_SHIFT       // x19 = entero con signo

    // ── caso especial: cero ──
    cbnz x19, .Lpi_nonzero
    mov  x0, #'0'
    bl   io_print_char
    b    .Lpi_done

.Lpi_nonzero:
    // ── detectar signo y trabajar con abs ──
    mov  x21, #0                   // x21 = flag negativo (0=pos, 1=neg)
    tbnz x19, #63, .Lpi_neg
    b    .Lpi_convert
.Lpi_neg:
    neg  x19, x19
    mov  x21, #1

.Lpi_convert:
    // ── llenar buffer de atras hacia adelante ──
    // x20 = puntero que empieza al FINAL del buffer y retrocede
    adr  x20, io_itoa_buf
    add  x20, x20, #31             // x20 apunta al ultimo byte (indice 31)
    mov  x22, #0                   // x22 = contador de digitos insertados

    mov  x0, #10                   // divisor

.Lpi_loop:
    // extraer digito: residuo = x19 % 10
    udiv  x1,  x19, x0             // x1  = cociente
    msub  x19, x1,  x0,  x19      // x19 = x19 - x1*10  (residuo 0-9)
    add   x19, x19, #'0'           // convertir a ASCII
    strb  w19, [x20]               // guardar en buffer
    sub   x20, x20, #1             // retroceder puntero
    add   x22, x22, #1             // contar digito
    mov   x19, x1                  // cociente pasa a ser el nuevo numero
    cbnz  x19, .Lpi_loop           // seguir si quedan digitos

    // ── imprimir signo negativo si aplica ──
    cbz  x21, .Lpi_print
    mov  x0, #'-'
    bl   io_print_char

.Lpi_print:
    // x20 apunta UNA POSICION ANTES del primer digito
    // entonces: inicio = x20 + 1,  longitud = x22 (contador)
    add  x0, x20, #1               // x0 = puntero al primer digito
    mov  x1, x22                   // x1 = cantidad de digitos (LONGITUD CORRECTA)
    bl   io_print_str

.Lpi_done:
    ldp  x21, x22, [sp, #32]
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #48
    ret

// ============================================================
// io_read_int — lee un entero desde stdin
// OUT: x0 = valor Q32.32
//      x1 = ERR_OK(0) o ERR_INVALID(-1)
//
// CALLEE-SAVED: x19 x20 x21 x22 x23 x24
// ============================================================
io_read_int:
    stp  x29, x30, [sp, #-64]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    stp  x23, x24, [sp, #48]

    // ── leer de stdin al buffer ──
    adr  x19, io_read_buf
    mov  x0,  #FD_STDIN
    mov  x1,  x19
    mov  x2,  #63
    mov  x8,  #SYS_READ
    svc  #0
    cmp  x0, #1
    blt  .Lri_err
    mov  x20, x0                   // bytes leidos
    strb wzr, [x19, x20]           // terminador nulo

    // ── saltar espacios ──
    mov  x21, #0                   // indice actual
.Lri_skip:
    cmp  x21, x20;  bge .Lri_err
    ldrb w22, [x19, x21]
    cmp  w22, #' ';  beq .Lri_skip_adv
    cmp  w22, #'\t'; beq .Lri_skip_adv
    b    .Lri_sign
.Lri_skip_adv:
    add  x21, x21, #1;  b .Lri_skip

    // ── detectar signo ──
.Lri_sign:
    mov  x23, #1                   // signo = +1
    ldrb w22, [x19, x21]
    cmp  w22, #'-';  bne .Lri_chk_plus
    mov  x23, #-1
    add  x21, x21, #1
    b    .Lri_digits
.Lri_chk_plus:
    cmp  w22, #'+';  bne .Lri_digits
    add  x21, x21, #1

    // ── acumular digitos ──
.Lri_digits:
    mov  x24, #0
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
    mul  x24, x24, x23             // aplicar signo
    lsl  x0,  x24, #Q32_SHIFT     // convertir a Q32.32
    mov  x1,  #ERR_OK
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
// io_print_matrix — imprime descriptor completo con formato
// IN:  x0 = puntero al descriptor
//
// FIX: las cadenas "[ ", " ]", "  " ahora estan en .data
//      con longitudes calculadas correctamente (2 bytes cada una).
//      io_print_int ya esta corregido, asi que los valores salen bien.
//
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

    // verificar STATUS == USED
    ldr  x20, [x19, #DESC_STATUS]
    cmp  x20, #STATUS_USED
    bne  .Lpm_empty

    ldr  x20, [x19, #DESC_ROWS]    // filas
    ldr  x21, [x19, #DESC_COLS]    // columnas
    ldr  x22, [x19, #DESC_DATA]    // datos

    mov  x23, #0                   // i = 0
.Lpm_row:
    cmp  x23, x20;  bge .Lpm_done

    // imprimir "[ "
    adr  x0, .Lbopen_d
    mov  x1, #2
    bl   io_print_str

    mov  x24, #0                   // j = 0
.Lpm_col:
    cmp  x24, x21;  bge .Lpm_end_row

    // calcular offset = (i*COLS + j) * 8
    mul  x25, x23, x21
    add  x25, x25, x24
    lsl  x25, x25, #3
    ldr  x0, [x22, x25]            // A[i][j] en Q32.32
    bl   io_print_int               // imprime parte entera

    // separador "  " (solo si NO es el ultimo elemento de la fila)
    add  x26, x24, #1
    cmp  x26, x21
    bge  .Lpm_no_sep
    adr  x0, .Lsep_d
    mov  x1, #2
    bl   io_print_str
.Lpm_no_sep:
    add  x24, x24, #1
    b    .Lpm_col

.Lpm_end_row:
    // imprimir " ]" y newline
    adr  x0, .Lbclose_d
    mov  x1, #2
    bl   io_print_str
    bl   io_print_nl
    add  x23, x23, #1
    b    .Lpm_row

.Lpm_empty:
    adr  x0, .Lempty_d
    mov  x1, #11
    bl   io_print_str
    bl   io_print_nl

.Lpm_done:
    ldp  x25, x26, [sp, #64]
    ldp  x23, x24, [sp, #48]
    ldp  x21, x22, [sp, #32]
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #80
    ret