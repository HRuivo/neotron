gdb-multiarch zig-out/bin/kernel.elf

x/64bx (unsigned char *)&__bss

x/64bx (char *)(unsigned long)&__bss

p/x (unsigned long)&__bss_end - (unsigned long)&__bss

x/Nbx (unsigned char *)&__bss, replacing N with the size in bytes.
