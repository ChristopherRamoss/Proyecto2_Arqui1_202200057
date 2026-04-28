// =============================================================================
// src/io/io.s  —  Entrada / Salida via syscalls Linux AArch64
//
// Sin libc: solo read(63), write(64), no printf/scanf.
//
// CONVENCION DE REGISTROS (AAPCS64):
//   x0-x7   : argumentos y valores de retorno  (caller-saved)
//   x8      : numero de syscall
//   x9-x15  : temporales                        (caller-saved)
//   x19-x28 : preservados entre llamadas        (callee-saved)
//   x29     : frame pointer   x30 : link register
//   sp      : siempre alineado a 16 bytes antes de BL
// =============================================================================

.include "include/defines.inc"

.global io_print_str
.global io_print_nl
.global io_print_char
.global io_print_int
.global io_read_int
.global io_print_matrix

// ─── buffers en BSS ────────────────────────────────────────────────────────
.section .bss
io_itoa_buf:    .skip 32        // conversion entero -> texto
io_read_buf:    .skip 64        // lectura desde stdin

// ─── codigo ────────────────────────────────────────────────────────────────
.section .text

// ============================================================
// io_print_str  —  escribe len bytes a stdout
// IN:  x0 = puntero  x1 = longitud
// ============================================================
io_print_str:
    stp  x29, x30, [sp, #-16]!
    mov  x29, sp
    mov  x2, x1          // len
    mov  x1, x0          // buf
    mov  x0, #FD_STDOUT
    mov  x8, #SYS_WRITE
    svc  #0
    ldp  x29, x30, [sp], #16
    ret

// ============================================================
// io_print_nl  —  imprime '\n'
// ============================================================
io_print_nl:
    stp  x29, x30, [sp, #-16]!
    mov  x29, sp
    adr  x1, .Lnl
    mov  x2, #1
    mov  x0, #FD_STDOUT
    mov  x8, #SYS_WRITE
    svc  #0
    ldp  x29, x30, [sp], #16
    ret
.Lnl: .byte '\n'

// ============================================================
// io_print_char  —  imprime un solo caracter
// IN:  x0 = caracter (byte bajo)
// ============================================================
io_print_char:
    stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    strb w0, [sp, #16]          // guardar byte en area de la pila
    add  x1, sp, #16
    mov  x2, #1
    mov  x0, #FD_STDOUT
    mov  x8, #SYS_WRITE
    svc  #0
    ldp  x29, x30, [sp], #32
    ret

// ============================================================
// io_print_int  —  imprime la PARTE ENTERA de un valor Q32.32
// IN:  x0 = valor en Q32.32
//
// ALGORITMO:
//   1. Extraer parte entera: x = x0 >> 32  (ASR preserva signo)
//   2. Si negativo: imprimir '-', negar
//   3. Dividir por 10 repetidamente, guardar digitos en buffer
//   4. Imprimir digitos en orden correcto
//
// REGISTROS CALLEE-SAVED usados: x19 x20 x21 x22
// ============================================================
io_print_int:
    stp  x29, x30, [sp, #-48]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]

    // ── extraer parte entera ──
    asr  x19, x0, #Q32_SHIFT       // x19 = entero con signo

    // ── caso cero ──
    cbnz x19, 1f
    mov  x0, #'0'
    bl   io_print_char
    b    9f

1:  // ── preparar buffer (llenamos de atras hacia adelante) ──
    adr  x20, io_itoa_buf
    add  x20, x20, #31             // x20 = ultimo byte del buffer
    strb wzr, [x20]                // terminador (no necesario, pero prolijo)
    sub  x20, x20, #1              // x20 = posicion actual

    // ── guardar signo, trabajar con valor absoluto ──
    mov  x21, #0                   // x21 = 0 → positivo
    tbnz x19, #63, 2f              // bit 63 set → negativo
    b    3f
2:  neg  x19, x19                  // abs
    mov  x21, #1                   // negativo

3:  // ── convertir digitos ──
    mov  x22, #10
.Ldigit:
    udiv  x0,  x19, x22            // cociente
    msub  x19, x0,  x22, x19      // residuo = x19 - cociente*10
    add   x19, x19, #'0'           // ASCII
    strb  w19, [x20]               // guardar digito
    sub   x20, x20, #1
    mov   x19, x0                  // siguiente numero
    cbnz  x19, .Ldigit

    // ── imprimir signo si negativo ──
    cbz  x21, 4f
    mov  x0, #'-'
    bl   io_print_char

4:  // ── imprimir digitos ──
    add  x0, x20, #1               // primer digito
    adr  x1, io_itoa_buf
    add  x1, x1, #31               // ultimo+1
    sub  x1, x1, x0                // longitud
    bl   io_print_str

9:  ldp  x21, x22, [sp, #32]
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #48
    ret

// ============================================================
// io_read_int  —  lee un entero desde stdin
// OUT: x0 = valor en Q32.32
//      x1 = ERR_OK (0) o ERR_INVALID (-1)
//
// ALGORITMO:
//   1. syscall read → bytes en io_read_buf
//   2. saltar espacios
//   3. detectar signo opcional
//   4. acumular digitos:  n = n*10 + (c-'0')
//   5. aplicar signo y desplazar a Q32.32
//
// REGISTROS CALLEE-SAVED: x19 x20 x21 x22 x23 x24
// ============================================================
io_read_int:
    stp  x29, x30, [sp, #-64]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    stp  x23, x24, [sp, #48]

    // ── leer bytes de stdin ──
    adr  x19, io_read_buf
    mov  x0,  #FD_STDIN
    mov  x1,  x19
    mov  x2,  #63               // dejar 1 byte libre para terminador
    mov  x8,  #SYS_READ
    svc  #0
    // x0 = bytes leidos (< 0 si error)
    cmp  x0,  #1
    blt  .Lri_err               // nada leido
    mov  x20, x0                // x20 = bytes leidos
    strb wzr, [x19, x20]       // poner '\0' al final

    // ── saltar espacios ──
    mov  x21, #0                // x21 = indice
.Lri_skip:
    cmp  x21, x20
    bge  .Lri_err
    ldrb w22, [x19, x21]
    cmp  w22, #' ';  beq  .Lri_adv_skip
    cmp  w22, #'\t'; beq  .Lri_adv_skip
    b    .Lri_sign
.Lri_adv_skip:
    add  x21, x21, #1
    b    .Lri_skip

    // ── detectar signo ──
.Lri_sign:
    mov  x23, #1                // x23 = signo (+1)
    ldrb w22, [x19, x21]
    cmp  w22, #'-'
    bne  .Lri_plus
    mov  x23, #-1
    add  x21, x21, #1
    b    .Lri_digits
.Lri_plus:
    cmp  w22, #'+'
    bne  .Lri_digits
    add  x21, x21, #1

    // ── acumular digitos ──
.Lri_digits:
    mov  x24, #0                // x24 = valor acumulado
.Lri_loop:
    cmp  x21, x20
    bge  .Lri_done
    ldrb w22, [x19, x21]
    cmp  w22, #'\n'; beq .Lri_done
    cmp  w22, #'\r'; beq .Lri_done
    sub  w22, w22, #'0'
    cmp  w22, #0;   blt .Lri_done
    cmp  w22, #9;   bgt .Lri_done
    mov  x0, #10
    mul  x24, x24, x0
    add  x24, x24, x22
    add  x21, x21, #1
    b    .Lri_loop

.Lri_done:
    // ── aplicar signo y convertir a Q32.32 ──
    mul  x24, x24, x23
    lsl  x0,  x24, #Q32_SHIFT  // x0 = valor Q32.32
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
// io_print_matrix  —  imprime una matriz completa
// IN:  x0 = puntero al descriptor
//
// Formato:
//   [ v00  v01  v02 ]
//   [ v10  v11  v12 ]
//
// Acceso A[i][j]:
//   offset = (i * COLS + j) * 8
//   dir    = DATA + offset
//
// REGISTROS CALLEE-SAVED: x19-x27
// ============================================================
io_print_matrix:
    stp  x29, x30, [sp, #-80]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    stp  x23, x24, [sp, #48]
    stp  x25, x26, [sp, #64]

    mov  x19, x0                // x19 = descriptor

    // ── verificar que tiene datos ──
    ldr  x20, [x19, #DESC_STATUS]
    cmp  x20, #STATUS_USED
    bne  .Lpm_empty

    // ── cargar dimensiones y puntero a datos ──
    ldr  x20, [x19, #DESC_ROWS]    // x20 = filas
    ldr  x21, [x19, #DESC_COLS]    // x21 = columnas
    ldr  x22, [x19, #DESC_DATA]    // x22 = datos

    mov  x23, #0                   // x23 = i

.Lpm_row:
    cmp  x23, x20
    bge  .Lpm_done

    // "[ "
    adr  x0, .Lbopen;  mov x1, #2;  bl io_print_str

    mov  x24, #0                   // x24 = j

.Lpm_col:
    cmp  x24, x21
    bge  .Lpm_endrow

    // offset = (i*COLS + j) * 8
    mul  x25, x23, x21
    add  x25, x25, x24
    lsl  x25, x25, #3
    ldr  x0,  [x22, x25]          // A[i][j] en Q32.32
    bl   io_print_int

    // separador (excepto ultimo)
    add  x26, x24, #1
    cmp  x26, x21
    bge  .Lpm_nosep
    adr  x0, .Lsep;  mov x1, #2;  bl io_print_str
.Lpm_nosep:
    add  x24, x24, #1
    b    .Lpm_col

.Lpm_endrow:
    // " ]\n"
    adr  x0, .Lbclose;  mov x1, #2;  bl io_print_str
    bl   io_print_nl
    add  x23, x23, #1
    b    .Lpm_row

.Lpm_empty:
    adr  x0, .Lempty;  mov x1, #11;  bl io_print_str
    bl   io_print_nl

.Lpm_done:
    ldp  x25, x26, [sp, #64]
    ldp  x23, x24, [sp, #48]
    ldp  x21, x22, [sp, #32]
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #80
    ret

// datos locales (en .text esta bien para literales de solo lectura)
.Lbopen:  .ascii "[ "
.Lbclose: .ascii " ]"
.Lsep:    .ascii "  "
.Lempty:  .ascii "(sin datos)"

// Al final de src/io/io.s
.global io_print_uint
io_print_uint:
    // Antes de llamar a io_print_int, el número debe estar en formato Q32.32
    // porque tu io_print_int hace un shift a la derecha (asr x19, x0, #32)
    lsl x0, x0, #32 
    b io_print_int