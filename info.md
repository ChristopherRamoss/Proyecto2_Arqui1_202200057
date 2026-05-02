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


COMPILAR POR GDB-
make gdb
agregar brakePoints
- Panel izquierdo RUN AND DEBUG