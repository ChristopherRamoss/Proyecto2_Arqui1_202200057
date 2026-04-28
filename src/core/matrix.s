// =============================================================================
// src/core/matrix.s  —  Gestion de descriptores A, B y R
//
// Modelo de memoria:
//   Descriptores (64 bytes c/u) en .bss  (memoria estatica)
//   Datos de la matriz via mmap          (memoria dinamica)
//
// Funciones exportadas:
//   matrix_init      inicializar A, B, R a STATUS_FREE
//   matrix_load      pedir dimensiones+valores al usuario, reservar con mmap
//   matrix_resize    liberar datos anteriores y reservar nuevo bloque mmap
//   matrix_free      munmap + limpiar un descriptor
//   matrix_free_all  liberar A, B y R
//   matrix_copy_desc copiar descriptor (transfiere propiedad del bloque)
//   matrix_validate  verificar que el descriptor tiene datos
// =============================================================================

.include "include/defines.inc"

.global matrix_init
.global matrix_load
.global matrix_resize
.global matrix_free
.global matrix_free_all
.global matrix_copy_desc
.global matrix_validate
.global mat_A
.global mat_B
.global mat_R

.extern io_print_str
.extern io_print_nl
.extern io_print_int
.extern io_read_int

// ─── descriptores estaticos ────────────────────────────────────────────────
.section .bss
mat_A:  .skip DESC_SIZE        // 64 bytes, descriptor de la matriz A
mat_B:  .skip DESC_SIZE        // 64 bytes, descriptor de la matriz B
mat_R:  .skip DESC_SIZE        // 64 bytes, descriptor del resultado R

// ─── cadenas de texto (en .data, NO en .text) ──────────────────────────────
.section .data

Srows:  .ascii "Ingrese filas: "
Srows_l = . - Srows

Scols:  .ascii "Ingrese columnas: "
Scols_l = . - Scols

// Prompt "a[i][j] = "
// Imprimiremos sus partes por separado: "a[" + i + "][" + j + "] = "
Sai:    .ascii "a["
Sai_l   = . - Sai

Sbr:    .ascii "]["
Sbr_l   = . - Sbr

Seq:    .ascii "] = "
Seq_l   = . - Seq

Sloading: .ascii "Ingrese los valores:\n"
Sloading_l = . - Sloading

Serr_dim:   .ascii "Error: dimensiones invalidas (1-32)\n"
Serr_dim_l  = . - Serr_dim

Serr_mem:   .ascii "Error: fallo al reservar memoria\n"
Serr_mem_l  = . - Serr_mem

// ─── codigo ────────────────────────────────────────────────────────────────
.section .text

// ============================================================
// matrix_init  —  pone STATUS_FREE en A, B y R
// (.bss ya viene en cero, pero lo hacemos explicitamente)
// ============================================================
matrix_init:
    adr  x0, mat_A;  str xzr, [x0, #DESC_STATUS]
    adr  x0, mat_B;  str xzr, [x0, #DESC_STATUS]
    adr  x0, mat_R;  str xzr, [x0, #DESC_STATUS]
    ret

// ============================================================
// matrix_load
// Pide filas, columnas y valores al usuario.
// Llama matrix_resize para reservar memoria.
//
// IN:  x0 = puntero al descriptor (mat_A o mat_B)
//      x1, x2 ignorados (no se usa el nombre de la matriz aqui)
// OUT: x0 = ERR_OK o codigo de error
//
// CALLEE-SAVED: x19 (descriptor) x20 (filas) x21 (cols)
//               x22 (puntero datos) x23 (i) x24 (j)
// ============================================================
matrix_load:
    stp  x29, x30, [sp, #-64]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    stp  x23, x24, [sp, #48]

    mov  x19, x0               // x19 = descriptor

    // ── pedir filas ──
    adr  x0, Srows;  mov x1, #Srows_l;  bl io_print_str
    bl   io_read_int
    cmp  x1, #ERR_OK;  bne .ml_err_inv
    asr  x20, x0, #Q32_SHIFT  // x20 = filas (entero)
    cmp  x20, #1;  blt .ml_err_dim
    cmp  x20, #MAX_ROWS; bgt .ml_err_dim

    // ── pedir columnas ──
    adr  x0, Scols;  mov x1, #Scols_l;  bl io_print_str
    bl   io_read_int
    cmp  x1, #ERR_OK;  bne .ml_err_inv
    asr  x21, x0, #Q32_SHIFT  // x21 = columnas (entero)
    cmp  x21, #1;  blt .ml_err_dim
    cmp  x21, #MAX_COLS; bgt .ml_err_dim

    // ── reservar memoria ──
    mov  x0, x19
    mov  x1, x20
    mov  x2, x21
    bl   matrix_resize
    cmp  x0, #ERR_OK;  bne .ml_err_mem

    // ── obtener puntero a datos ──
    ldr  x22, [x19, #DESC_DATA]

    // ── informar al usuario ──
    adr  x0, Sloading;  mov x1, #Sloading_l;  bl io_print_str

    // ── leer cada elemento a[i][j] ──
    mov  x23, #0               // i = 0

.ml_row:
    cmp  x23, x20;  bge .ml_done
    mov  x24, #0               // j = 0

.ml_col:
    cmp  x24, x21;  bge .ml_nextrow

    // --- REEMPLAZO SIMPLIFICADO ---
    // En lugar de imprimir a[i][j], imprimimos algo que no use io_print_int
    adr  x0, Seq       // Usamos el "] = " que ya tienes definido o "-> "
    mov  x1, #Seq_l
    bl   io_print_str

    // leer valor (Esto es lo que importa)
    bl   io_read_int
    cmp  x1, #ERR_OK;  bne .ml_err_inv
    // ------------------------------

    // guardar en A[i][j]:  offset = (i*COLS + j) * 8
    mul  x1, x23, x21         // i * COLS
    add  x1, x1,  x24         // + j
    lsl  x1, x1,  #3          // * 8
    str  x0, [x22, x1]        // datos[offset] = valor Q32.32

    add  x24, x24, #1
    b    .ml_col

.ml_nextrow:
    add  x23, x23, #1
    b    .ml_row

.ml_done:
    mov  x0, #ERR_OK;  b .ml_ret

.ml_err_inv:
    mov  x0, #ERR_INVALID;  b .ml_ret

.ml_err_dim:
    adr  x0, Serr_dim;  mov x1, #Serr_dim_l;  bl io_print_str
    mov  x0, #ERR_RANGE;  b .ml_ret

.ml_err_mem:
    adr  x0, Serr_mem;  mov x1, #Serr_mem_l;  bl io_print_str
    mov  x0, #ERR_ALLOC

.ml_ret:
    ldp  x23, x24, [sp, #48]
    ldp  x21, x22, [sp, #32]
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #64
    ret

// ============================================================
// matrix_resize
// Si el descriptor tenia datos, los libera con munmap.
// Luego reserva un nuevo bloque con mmap y actualiza el descriptor.
//
// IN:  x0 = descriptor   x1 = filas   x2 = columnas
// OUT: x0 = ERR_OK o ERR_ALLOC
//
// NOTAS SOBRE MMAP:
//   mmap(addr=0, size, PROT_RW, MAP_PRIVATE|MAP_ANON, fd=-1, off=0)
//   El bloque nuevo viene en cero (MAP_ANONYMOUS garantiza esto).
//   Si falla, el retorno en x0 tiene el bit 63 en 1 (valor negativo).
//
// CALLEE-SAVED: x19 (desc) x20 (filas) x21 (cols) x22 (elems) x23 (bytes)
// ============================================================
matrix_resize:
    stp  x29, x30, [sp, #-64]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    stp  x23, xzr, [sp, #48]

    mov  x19, x0
    mov  x20, x1
    mov  x21, x2

    // ── liberar datos anteriores si existen ──
    ldr  x22, [x19, #DESC_STATUS]
    cmp  x22, #STATUS_USED
    bne  .mr_alloc

    ldr  x0,  [x19, #DESC_DATA]
    ldr  x1,  [x19, #DESC_BYTES]
    mov  x8,  #SYS_MUNMAP
    svc  #0

.mr_alloc:
    // ── calcular tamano del nuevo bloque ──
    //   ELEMS = filas * cols
    //   BYTES = ELEMS * 8  (cada Q32.32 ocupa 8 bytes)
    mul  x22, x20, x21            // ELEMS
    lsl  x23, x22, #3             // BYTES = ELEMS * 8

    // ── llamar mmap ──
    //   mmap(0, BYTES, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0)
    mov  x0, #0
    mov  x1, x23                  // size = BYTES
    mov  x2, #MMAP_PROT_RW        // prot
    mov  x3, #MMAP_FLAGS          // flags
    mov  x4, #-1                  // fd = -1
    mov  x5, #0                   // offset = 0
    mov  x8, #SYS_MMAP
    svc  #0
    // x0 = nueva direccion

    // ── verificar fallo de mmap (bit 63 = 1 → error) ──
    tbnz x0, #63, .mr_fail

    // ── actualizar descriptor ──
    mov  x1, #STATUS_USED
    str  x1,  [x19, #DESC_STATUS]
    str  x20, [x19, #DESC_ROWS]
    str  x21, [x19, #DESC_COLS]
    str  x22, [x19, #DESC_ELEMS]
    str  x23, [x19, #DESC_BYTES]
    str  x0,  [x19, #DESC_DATA]   // guardar puntero al bloque
    str  xzr, [x19, #DESC_RSVD1]
    str  xzr, [x19, #DESC_RSVD2]

    mov  x0, #ERR_OK;  b .mr_ret

.mr_fail:
    // mmap fallo: limpiar descriptor
    str  xzr, [x19, #DESC_STATUS]
    str  xzr, [x19, #DESC_DATA]
    mov  x0, #ERR_ALLOC

.mr_ret:
    ldp  x23, xzr, [sp, #48]
    ldp  x21, x22, [sp, #32]
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #64
    ret

// ============================================================
// matrix_free  —  munmap + limpiar descriptor
// IN: x0 = descriptor
// ============================================================
matrix_free:
    stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    stp  x19, xzr, [sp, #16]

    mov  x19, x0
    ldr  x1,  [x19, #DESC_STATUS]
    cmp  x1,  #STATUS_USED
    bne  .mf_done

    ldr  x0, [x19, #DESC_DATA]
    ldr  x1, [x19, #DESC_BYTES]
    mov  x8, #SYS_MUNMAP
    svc  #0

    // limpiar descriptor completo
    str  xzr, [x19, #DESC_STATUS]
    str  xzr, [x19, #DESC_ROWS]
    str  xzr, [x19, #DESC_COLS]
    str  xzr, [x19, #DESC_ELEMS]
    str  xzr, [x19, #DESC_BYTES]
    str  xzr, [x19, #DESC_DATA]
    str  xzr, [x19, #DESC_RSVD1]
    str  xzr, [x19, #DESC_RSVD2]

.mf_done:
    ldp  x19, xzr, [sp, #16]
    ldp  x29, x30, [sp], #32
    ret

// ============================================================
// matrix_free_all  —  libera A, B y R
// ============================================================
matrix_free_all:
    stp  x29, x30, [sp, #-16]!
    mov  x29, sp
    adr  x0, mat_A;  bl matrix_free
    adr  x0, mat_B;  bl matrix_free
    adr  x0, mat_R;  bl matrix_free
    ldp  x29, x30, [sp], #16
    ret

// ============================================================
// matrix_copy_desc
// Copia el descriptor de SRC a DST y transfiere la propiedad
// del bloque de datos (SRC queda como FREE).
//
// Si DST ya tenia datos, los libera primero con munmap.
//
// IN:  x0 = DST   x1 = SRC
// ============================================================
matrix_copy_desc:
    stp  x29, x30, [sp, #-48]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, xzr, [sp, #32]

    mov  x19, x0               // DST
    mov  x20, x1               // SRC

    // ── si DST tiene datos, liberarlos ──
    ldr  x21, [x19, #DESC_STATUS]
    cmp  x21, #STATUS_USED
    bne  .mcd_copy
    ldr  x0, [x19, #DESC_DATA]
    ldr  x1, [x19, #DESC_BYTES]
    mov  x8, #SYS_MUNMAP;  svc #0

.mcd_copy:
    // ── copiar los 8 campos del descriptor (8 bytes c/u = 64 bytes total) ──
    ldr  x21, [x20, #DESC_STATUS];  str x21, [x19, #DESC_STATUS]
    ldr  x21, [x20, #DESC_ROWS];    str x21, [x19, #DESC_ROWS]
    ldr  x21, [x20, #DESC_COLS];    str x21, [x19, #DESC_COLS]
    ldr  x21, [x20, #DESC_ELEMS];   str x21, [x19, #DESC_ELEMS]
    ldr  x21, [x20, #DESC_BYTES];   str x21, [x19, #DESC_BYTES]
    ldr  x21, [x20, #DESC_DATA];    str x21, [x19, #DESC_DATA]
    ldr  x21, [x20, #DESC_RSVD1];   str x21, [x19, #DESC_RSVD1]
    ldr  x21, [x20, #DESC_RSVD2];   str x21, [x19, #DESC_RSVD2]

    // ── marcar SRC como FREE (transfiere propiedad) ──
    str  xzr, [x20, #DESC_STATUS]
    str  xzr, [x20, #DESC_ROWS]
    str  xzr, [x20, #DESC_COLS]
    str  xzr, [x20, #DESC_ELEMS]
    str  xzr, [x20, #DESC_BYTES]
    str  xzr, [x20, #DESC_DATA]

    ldp  x21, xzr, [sp, #32]
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #48
    ret

// ============================================================
// matrix_validate
// IN:  x0 = descriptor
// OUT: x0 = ERR_OK si valido y activo
//          ERR_INVALID si puntero nulo
//          ERR_EMPTY si STATUS != USED
// ============================================================
matrix_validate:
    cbz  x0, .mv_null
    ldr  x1, [x0, #DESC_STATUS]
    cmp  x1, #STATUS_USED
    bne  .mv_empty
    mov  x0, #ERR_OK;  ret
.mv_null:
    mov  x0, #ERR_INVALID;  ret
.mv_empty:
    mov  x0, #ERR_EMPTY;  ret