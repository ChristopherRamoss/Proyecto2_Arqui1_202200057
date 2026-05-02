# =============================================================================
# Makefile — Motor de Algebra Lineal ARM64
# Universidad San Carlos de Guatemala — ARQUI1
#
# USO:
#   make          -> compila todo y genera el binario
#   make run      -> compila y ejecuta con QEMU
#   make clean    -> borra archivos generados
#   make debug    -> compila con simbolos de debug para GDB
#   make gdb      -> inicia QEMU con GDB server en puerto 1234
#
# HERRAMIENTAS REQUERIDAS (instalar en Linux Mint):
#   sudo apt install gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu
#   sudo apt install qemu-user qemu-user-static
#   sudo apt install gdb-multiarch
#
# COMO FUNCIONA LA COMPILACION CRUZADA:
#   1. aarch64-linux-gnu-as  -> ensambla .s en archivos objeto .o (codigo ARM64)
#   2. aarch64-linux-gnu-ld  -> enlaza los .o en un ejecutable ELF ARM64
#   3. qemu-aarch64          -> emula un CPU ARM64 para ejecutar el binario
#
# NOTA SOBRE EL LINKER:waw
#   No usamos libc (-lc) porque el proyecto implementa todo via syscalls.
#   El punto de entrada es _start (no main).
#   Usamos -static para que el binario no dependa de librerias dinamicas ARM64.
# =============================================================================

# ---------------------------------------------------------------------------
# Variables de configuracion
# ---------------------------------------------------------------------------

# Nombre del ejecutable final
TARGET = algebra_lineal

# Ensamblador y linker para ARM64
AS  = aarch64-linux-gnu-as
LD  = aarch64-linux-gnu-ld

# Emulador QEMU para ARM64
QEMU = qemu-aarch64

# Debugger multiarchitecture
GDB = gdb-multiarch

# Flags del ensamblador:
#   -g           -> incluir informacion de debug (numeros de linea, simbolos)
#   -march=armv8-a -> arquitectura ARMv8-A (AArch64)
ASFLAGS = -g -march=armv8-a

# Flags del linker:
#   -static     -> enlace estatico (no busca .so de ARM64 en el host)
#   -e _start   -> punto de entrada es el simbolo _start
#   --no-dynamic-linker -> sin interprete dinamico
LDFLAGS = -static -e _start --no-dynamic-linker

# Flags de QEMU:
#   -L /usr/aarch64-linux-gnu -> directorio de librerias ARM64 (para libc si la usaramos)
QEMUFLAGS =

# Puerto para GDB server
GDB_PORT = 1234

# ---------------------------------------------------------------------------
# Lista de archivos fuente (.s) y sus objetos (.o) correspondientes
# ---------------------------------------------------------------------------
#
# ORDEN DE LOS OBJETOS EN EL LINKER:
#   El linker resuelve simbolos en orden. main.o debe ir PRIMERO porque
#   define _start. Los demas pueden ir en cualquier orden.
#
SRCS = main.s \
       src/io/io.s \
       src/core/matrix.s \
       src/arith/arith.s \
       src/gauss/gauss.s \
       src/menu/menu.s

# Generar lista de .o reemplazando .s -> .o
# Ej: main.s -> build/main.o, src/io/io.s -> build/src/io/io.o
OBJS = $(patsubst %.s, build/%.o, $(SRCS))

# ---------------------------------------------------------------------------
# Regla principal: compilar el ejecutable
# ---------------------------------------------------------------------------
.PHONY: all run clean debug gdb help

all: $(TARGET)
	@echo ""
	@echo "=== Compilacion exitosa ==="
	@echo "Ejecutable: $(TARGET)"
	@echo "Para correr: make run"
	@echo "Para debuggear: make gdb (en otra terminal)"
	@echo ""

# Enlazar todos los .o en el ejecutable final
$(TARGET): $(OBJS)
	@echo "[LD]  Enlazando -> $@"
	$(LD) $(LDFLAGS) -o $@ $^
	@echo "[OK]  $@ generado"

# ---------------------------------------------------------------------------
# Regla generica: ensamblar cualquier .s -> build/ruta/archivo.o
#
# $< = archivo fuente (.s)
# $@ = archivo objeto destino (.o)
# @mkdir -p $(@D) -> crear el directorio de destino si no existe
# ---------------------------------------------------------------------------
build/%.o: %.s
	@mkdir -p $(@D)
	@echo "[AS]  $< -> $@"
	$(AS) $(ASFLAGS) -I . -o $@ $<

# ---------------------------------------------------------------------------
# Ejecutar con QEMU
# ---------------------------------------------------------------------------
run: all
	@echo "=== Ejecutando con QEMU ==="
	$(QEMU) $(QEMUFLAGS) ./$(TARGET)

# ---------------------------------------------------------------------------
# Compilar con debug extra (para usar con gdb-multiarch + QEMU gdbserver)
#
# Para depurar:
#   Terminal 1: make gdb
#   Terminal 2: Presiona F5 en VS Code (o ejecuta: gdb-multiarch ./algebra_lineal)
#               (gdb) target remote localhost:1234
#               (gdb) break _start
#               (gdb) continue
# ---------------------------------------------------------------------------
debug: ASFLAGS += -gdwarf-4
debug: all
	@echo ""
	@echo "=== Compilacion con DEBUG exitosa ==="
	@echo "Ahora ejecuta en otra terminal: make gdb"
	@echo "Luego presiona F5 en VS Code para debuggear"
	@echo ""

# ---------------------------------------------------------------------------
# Lanzar QEMU con GDB server
# ---------------------------------------------------------------------------
gdb: debug
	@echo ""
	@echo "=== Iniciando QEMU con GDB server ==="
	@echo "Puerto GDB: $(GDB_PORT)"
	@echo ""
	@echo "En VS Code presiona F5 para conectar el debugger"
	@echo "O en otra terminal ejecuta:"
	@echo "  $(GDB) ./$(TARGET)"
	@echo "  (gdb) target remote localhost:$(GDB_PORT)"
	@echo ""
	$(QEMU) -g $(GDB_PORT) ./$(TARGET)

# ---------------------------------------------------------------------------
# Limpiar archivos generados
# ---------------------------------------------------------------------------
clean:
	@echo "[CLEAN] Borrando build/ y $(TARGET)"
	rm -rf build/ $(TARGET)

# ---------------------------------------------------------------------------
# Ayuda
# ---------------------------------------------------------------------------
help:
	@echo "Comandos disponibles:"
	@echo "  make        -> compilar todo"
	@echo "  make run    -> compilar y ejecutar con QEMU"
	@echo "  make debug  -> compilar con info de debug"
	@echo "  make gdb    -> compilar y lanzar QEMU con GDB server"
	@echo "  make clean  -> borrar archivos generados"
	@echo "  make help   -> mostrar esta ayuda"
	@echo ""
	@echo "Herramientas necesarias:"
	@echo "  sudo apt install gcc-aarch64-linux-gnu"
	@echo "  sudo apt install binutils-aarch64-linux-gnu"
	@echo "  sudo apt install qemu-user"
	@echo "  sudo apt install gdb-multiarch"
