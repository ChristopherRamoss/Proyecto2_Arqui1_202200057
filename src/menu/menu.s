// src/menu/menu.s  — Menu interactivo principal y submenu de operaciones
//
// FLUJO GENERAL:
//   _start -> matrix_init -> menu_main -> exit
//
// RESPONSABILIDAD:
//   - Interactuamos con el por la terminal
//   - Llamar a funciones de matrices y gauss
//
// COMO USO LOS REGISTROS:
//   - x0–x7  : argumentos / retorno (caller-saved)
//   - x9–x15 : temporales (caller-saved)
//   - x19–x28: callee-saved (DEBEN preservarse)

.include "include/defines.inc"

.global menu_main
.global menu_ops

.extern mat_A
.extern mat_B
.extern mat_R
.extern io_print_str
.extern io_print_nl
.extern io_print_matrix
.extern matrix_load
.extern matrix_free_all
.extern matrix_copy_desc
.extern matrix_validate
.extern arith_identity
.extern arith_transpose
.extern arith_add
.extern arith_sub
.extern arith_mul
.extern gauss_eliminate
.extern gauss_jordan
.extern gauss_inverse
.extern gauss_determinant
.extern gauss_div

// ----------- Cadenas del menu en .data -----------
.section .data

.Stit:  .ascii "\n======================================\n"
        .ascii "   Proyecto2 202200057\n"
        .ascii "   -----ARQUI1--------\n"
        .ascii "======================================\n"
.Stit_l = . - .Stit

.Smenu: .ascii "\n--- MENU PRINCIPAL ---\n"
        .ascii "  1. Cargar Matriz A\n"
        .ascii "  2. Cargar Matriz B\n"
        .ascii "  3. Mostrar A, B y R\n"
        .ascii "  4. Operaciones\n"
        .ascii "  5. Mover R -> A\n"
        .ascii "  6. Mover R -> B\n"
        .ascii "  7. Liberar memoria\n"
        .ascii "  8. Salir\n"
        .ascii "Opcion: "
.Smenu_l = . - .Smenu

.Sops:  .ascii "\n--- OPERACIONES ---\n"
        .ascii "  1. Identidad de A\n"
        .ascii "  2. Transpuesta de A\n"
        .ascii "  3. A + B\n"
        .ascii "  4. A - B\n"
        .ascii "  5. A * B  (producto matricial)\n"
        .ascii "  6. Gauss  (triangular superior de A)\n"
        .ascii "  7. Gauss-Jordan  (forma reducida de A)\n"
        .ascii "  8. Inversa de A\n"
        .ascii "  9. Determinante de A\n"
        .ascii "  a. Division  A / B  (= A * inv(B))\n"
        .ascii "  0. Volver\n"
        .ascii "Opcion: "
.Sops_l = . - .Sops

.SmA:   .ascii "\n--- Matriz A ---\n"; .SmA_l = . - .SmA
.SmB:   .ascii "\n--- Matriz B ---\n"; .SmB_l = . - .SmB
.SmR:   .ascii "\n--- Resultado R ---\n"; .SmR_l = . - .SmR
.SldA:  .ascii "\n[Cargando Matriz A]\n"; .SldA_l = . - .SldA
.SldB:  .ascii "\n[Cargando Matriz B]\n"; .SldB_l = . - .SldB
.SnA:   .ascii "A"; .SnA_l = . - .SnA
.SnB:   .ascii "B"; .SnB_l = . - .SnB
.Sbye:  .ascii "\nHasta luego.\n\n"; .Sbye_l = . - .Sbye
.Sinv:  .ascii "[!] Opcion invalida.\n"; .Sinv_l = . - .Sinv
.Serr:  .ascii "[ERROR] Operacion fallida. Verifique matrices.\n"; .Serr_l = . - .Serr
.Sres:  .ascii "\n[Resultado en R]\n"; .Sres_l = . - .Sres
.SmRA:  .ascii "[OK] R copiado a A.\n"; .SmRA_l = . - .SmRA
.SmRB:  .ascii "[OK] R copiado a B.\n"; .SmRB_l = . - .SmRB
.Sfree: .ascii "[OK] Memoria liberada.\n"; .Sfree_l = . - .Sfree
.SerRE: .ascii "[ERROR] R vacio. Haga una operacion primero.\n"; .SerRE_l = . - .SerRE

// ----------- Buffer de lectura en .bss -----------
.section .bss
.mrbuf: .skip 8

// ----------- Codigo en .text -----------
.section .text

// ----------------------------------------------------------------
// leer_opcion
// Lee hasta 4 bytes desde stdin (teclado) y devuelve el primer char.
//
// ENTRADA:
//   - ninguna
//
// SALIDA:
//   x0 = caracter ASCII leido
//
// REGISTROS USADOS:
//   x0 = fd / retorno
//   x1 = buffer
//   x2 = tamaño
//   x8 = syscall
//
// NOTA:
//   Solo usa caller-saved → NO necesita guardar/restaurar stack
leer_opcion:
    adr  x1, .mrbuf        // x1 = direccion donde guardamos info antes de saber que hacer con ella
    mov  x2, #4            // x2 = maximo de bytes a leer
    mov  x0, #FD_STDIN     // x0 = 0 entrada desde el teclado
    mov  x8, #SYS_READ     // syscall read 
    svc  #0                // read(0, la entrada del teclado, 4)
    adr  x1, .mrbuf        // recargar direccion (por seguridad)
    ldrb w0, [x1]          // w0 = buffer[0] (primer caracter)
    ret                    // retorno con opcion en x0

// ----------------------------------------------------------------
// ops_show_result
// ENTRADA: x0 = codigo de retorno de la ultima operacion
// Muestra mat_R si ERR_OK, o mensaje de error en caso contrario.

// FP =29 y LR =30 se preservan porque esta funcion se llama desde menu_ops, que es un submenu.
// ----------------------------------------------------------------
ops_show_result:
    stp  x29, x30, [sp, #-16]!   // guardar FP y LR
    mov  x29, sp
    cmp  x0, #ERR_OK            // se pregunta si la operacion fue exitosa (ERR_OK = 0)
    bne  .osr_err
    adr  x0, .Sres;  mov x1, #.Sres_l;  bl io_print_str // EXITO mensaje "[Resultado en R]"
    adr  x0, mat_R;  bl io_print_matrix                 // imprimir matriz resultado
    b    .osr_done
.osr_err:
    adr  x0, .Serr;  mov x1, #.Serr_l;  bl io_print_str // ERROR mensaje "[ERROR] Operacion fallida. Verifique matrices."
.osr_done:                                              // Restaurar FP y LR antes de retornar
    ldp  x29, x30, [sp], #16
    ret

// menu_main — Bucle principal
//   x19 = opcion seleccionada (callee-saved)
menu_main:
    stp  x29, x30, [sp, #-32]!   // stack frame 
    mov  x29, sp
    stp  x19, x20, [sp, #16]    // Guardar PAR x19-x20 en 16 bytes (callee-saved)
    adr  x0, .Stit;  mov x1, #.Stit_l;  bl io_print_str // imprimir titulo del proyecto

.mm_loop:
    adr  x0, .Smenu; mov x1, #.Smenu_l; bl io_print_str // imprimir menu
    bl   leer_opcion
    mov  x19, x0                    // x19 = opcion (callee-saved)

// comparamos el valor de x19 con cada opcion del menu, y saltamos a la etiqueta correspondiente :)
    cmp x19, #MENU_LOAD_A;    beq .mm_load_A
    cmp x19, #MENU_LOAD_B;    beq .mm_load_B
    cmp x19, #MENU_SHOW;      beq .mm_show
    cmp x19, #MENU_OPERATE;   beq .mm_ops
    cmp x19, #MENU_MOVE_R_A;  beq .mm_move_RA
    cmp x19, #MENU_MOVE_R_B;  beq .mm_move_RB
    cmp x19, #MENU_FREE;      beq .mm_free
    cmp x19, #MENU_EXIT;      beq .mm_exit
    adr x0, .Sinv; mov x1, #.Sinv_l; bl io_print_str // por si no es ninguna
    b .mm_loop                                      // volver a mostrar el menu



// x0 = descriptor matriz   x1 = nombre     x2 = longitud
.mm_load_A:
    adr x0, .SldA; mov x1, #.SldA_l; bl io_print_str    // mensaje
    adr x0, mat_A                                       // destino
    adr x1, .SnA; mov x2, #.SnA_l                       // nombre "A"
    bl matrix_load                                      // cargar datos
    b .mm_loop                                          //Nos devolvemos al menu de antes

.mm_load_B:
    adr x0, .SldB; mov x1, #.SldB_l; bl io_print_str    // lo mismo que A xd
    adr x0, mat_B
    adr x1, .SnB; mov x2, #.SnB_l
    bl matrix_load
    b .mm_loop

.mm_show:                                           // Mostrar A, B, R con sus respectivos mensajes
    adr x0, .SmA; mov x1, #.SmA_l; bl io_print_str  // Aca va A
    adr x0, mat_A; bl io_print_matrix
    adr x0, .SmB; mov x1, #.SmB_l; bl io_print_str  // Aca va B
    adr x0, mat_B; bl io_print_matrix
    adr x0, .SmR; mov x1, #.SmR_l; bl io_print_str  // Aca va R
    adr x0, mat_R; bl io_print_matrix
    b .mm_loop

.mm_ops:
    bl menu_ops
    b .mm_loop

.mm_move_RA:
    adr x0, mat_R; bl matrix_validate                   // validar R
    cmp x0, #ERR_OK; bne .mm_R_empty
    adr x0, mat_A; adr x1, mat_R; bl matrix_copy_desc   // destino de A hacia R
    adr x0, .SmRA; mov x1, #.SmRA_l; bl io_print_str
    b .mm_loop

.mm_move_RB:
    adr x0, mat_R; bl matrix_validate               // Lo mismo que moveRA peroa b
    cmp x0, #ERR_OK; bne .mm_R_empty
    adr x0, mat_B; adr x1, mat_R; bl matrix_copy_desc
    adr x0, .SmRB; mov x1, #.SmRB_l; bl io_print_str
    b .mm_loop

.mm_R_empty:
    adr x0, .SerRE; mov x1, #.SerRE_l; bl io_print_str
    b .mm_loop

.mm_free:
    bl matrix_free_all                                  // liberar memoria de A, B, R
    adr x0, .Sfree; mov x1, #.Sfree_l; bl io_print_str  
    b .mm_loop                                      

.mm_exit:                                               // Nos despedimos y nos vamos
    adr x0, .Sbye; mov x1, #.Sbye_l; bl io_print_str
    bl matrix_free_all
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

// ================================================================
// menu_ops — Submenu de operaciones matematicas completo
// Incluye: identidad, transpuesta, suma, resta, multiplicacion,
//          Gauss, Gauss-Jordan, inversa, determinante, division.
// ================================================================
menu_ops:
    stp  x29, x30, [sp, #-32]!      // stack frame para submenu (guardamos FP y LR)
    mov  x29, sp                    
    stp  x19, x20, [sp, #16]        // Guardar PAR x19-x20 en 16 bytes (callee-saved)

.ops_loop:
    adr  x0, .Sops;  mov x1, #.Sops_l;  bl io_print_str
    bl   leer_opcion
    mov  x19, x0                    // x19 = opcion (callee-saved, sobrevive los BL)

    // ---- Aritmetica basica ----
    cmp x19, #OP_IDENTITY;     beq .op_ident
    cmp x19, #OP_TRANSPOSE;    beq .op_trans
    cmp x19, #OP_ADD;          beq .op_add
    cmp x19, #OP_SUB;          beq .op_sub
    cmp x19, #OP_MUL;          beq .op_mul
    // ---- Gauss ----
    cmp x19, #OP_GAUSS;        beq .op_gauss
    cmp x19, #OP_GAUSS_JORDAN; beq .op_gj
    cmp x19, #OP_INVERSE;      beq .op_inv
    cmp x19, #OP_DET;          beq .op_det
    cmp x19, #OP_DIV;          beq .op_div
    // ---- Volver ----
    cmp x19, #OP_BACK;         beq .op_back
    // Invalida
    adr x0, .Sinv; mov x1, #.Sinv_l; bl io_print_str
    b .ops_loop

.op_ident:
    bl arith_identity              // A -> identidad en R
    bl ops_show_result
    b .ops_loop

.op_trans:
    bl arith_transpose             // A^T -> R
    bl ops_show_result
    b .ops_loop

.op_add:
    bl arith_add                   // A + B -> R
    bl ops_show_result
    b .ops_loop

.op_sub:
    bl arith_sub                   // A - B -> R
    bl ops_show_result
    b .ops_loop

.op_mul:
    bl arith_mul                   // A * B -> R (producto matricial)
    bl ops_show_result
    b .ops_loop

.op_gauss:
    // gauss_eliminate: x0=ERR_OK, x1=signo_det
    bl gauss_eliminate             // triangular superior de A -> R
    // ops_show_result necesita ERR_OK en x0, que ya esta ahi
    bl ops_show_result
    b .ops_loop

.op_gj:
    bl gauss_jordan                // forma reducida de A -> R
    bl ops_show_result
    b .ops_loop

.op_inv:
    bl gauss_inverse               // inv(A) -> R
    bl ops_show_result
    b .ops_loop

.op_det:
    bl gauss_determinant
    bl ops_show_result
    b .ops_loop
    // CAMBIOS
    // CAMBIOS

.op_div:
    bl gauss_div                   // A / B = A * inv(B) -> R
    bl ops_show_result
    b .ops_loop

.op_back:                           // Restaurar estado de menu_main antes de retornar
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret