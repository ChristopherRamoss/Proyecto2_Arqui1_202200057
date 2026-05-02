// =============================================================================
// main.s
// Punto de entrada del programa. Linux llama a _start para iniciar 
//
// ESTRUCTURA DE UN PROGRAMA SIN LIBC:
//   El linker busca el simbolo "_start" como punto de entrada.
//   Desde ahi configuramos el entorno y llamamos a nuestras funciones.
//   Al terminar, hacemos syscall exit directamente (no hay return de main).
//
// FLUJO PRINCIPAL:
//   _start
//     -> matrix_init     (inicializar descriptores A, B, R a STATUS_FREE)
//     -> menu_main       (bucle del menu hasta que el usuario elija salir)
//     -> _exit           (syscall exit con codigo 0)
//
// NOTA SOBRE EL STACK POINTER AL INICIO:
//   Cuando el kernel ejecuta _start, el stack ya esta configurado.
//   En la cima del stack esta argc, luego los punteros de argv, luego env.
//   No necesitamos leerlos, pero el SP ya apunta ahi.
//   La primera instruccion DEBE alinear SP a 16 bytes si vamos a hacer
//   llamadas (bl). En la practica, el kernel ya lo alinea, pero lo hacemos
//   explicitamente por seguridad.
// =============================================================================

.include "include/defines.inc"

// Declarar _start como simbolo global visible para el linker
.global _start

// Importar funciones que usaremos desde otros modulos
.extern matrix_init
.extern menu_main

.section .text

// =============================================================================
// _start
// Punto de entrada. Aqui comienza la ejecucion del programa.
// =============================================================================
_start:
    // -------------------------------------------------------------------------
    // PASO 1: Asegurar que el stack pointer esta alineado a 16 bytes.
    // La instruccion BL (Branch with Link) requiere que SP % 16 == 0
    // antes de cualquier llamada. Lo forzamos con AND.
    // -------------------------------------------------------------------------
    // Alinear SP a 16 bytes de forma segura
    mov x9, sp          // Copiar el valor actual de SP a x9
    and x9, x9, #~15    // Aplicar la máscara en x9 (limpia los últimos 4 bits)
    mov sp, x9          // Regresar el valor alineado a SP

    // -------------------------------------------------------------------------
    // PASO 2: Configurar el frame pointer para debugging.
    // x29 (FP) apunta al frame actual. Al inicio ponemos 0 para indicar
    // que no hay frame previo (fin de la cadena de frames).
    // -------------------------------------------------------------------------
    mov x29, #0                    // FP = 0 (no hay frame anterior)
    mov x30, #0                    // LR = 0 (no hay quien nos llamo)

    // -------------------------------------------------------------------------
    // PASO 3: Inicializar los descriptores de matrices A, B y R.
    // Esto pone STATUS_FREE en los tres descriptores.
    // Aunque .bss ya viene en cero, llamar matrix_init es una buena practica
    // porque hace el codigo mas legible y explicito.
    // -------------------------------------------------------------------------
    bl matrix_init                 // inicializar A, B, R -> STATUS_FREE

    // -------------------------------------------------------------------------
    // PASO 4: Entrar al bucle principal del menu.
    // menu_main no retorna hasta que el usuario elige "Salir" (opcion 8).
    // Antes de retornar, menu_main llama matrix_free_all para liberar memoria.
    // -------------------------------------------------------------------------
    bl menu_main                   // bucle del menu (no retorna hasta salir)

    // -------------------------------------------------------------------------
    // PASO 5: Salir del proceso con codigo de salida 0 (exito).
    // Llamamos a la syscall exit directamente.
    //   x0 = codigo de salida (0 = exito)
    //   x8 = numero de syscall (SYS_EXIT = 93 en ARM64 Linux)
    //   svc #0 = llamada al kernel
    // NOTA: Esta instruccion nunca retorna. El kernel termina el proceso.
    // -------------------------------------------------------------------------
_exit:
    mov x0, #0                     // x0 = 0 (codigo de salida: exito)
    mov x8, #SYS_EXIT              // x8 = 93 (syscall exit)
    svc #0                         // llamar al kernel -> proceso termina aqui

    // Esta linea nunca se ejecuta, pero la incluimos para claridad:
    // Si por algun motivo el kernel no termina el proceso, entrariamos
    // en un bucle infinito de salidas.
.loop_forever:
    b .loop_forever