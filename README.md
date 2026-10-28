# neotron

A small experimental RISC-V kernel written in Zig. It runs on QEMU's 32-bit `virt` machine with OpenSBI and currently demonstrates console output, a custom panic handler, and page-aligned allocation from a linker-defined RAM region.

Largely based on the OS in 1000 Lines tutorial.

## Build and run

Requires Zig 0.17.0 and `qemu-system-riscv32`.

```sh
zig build
zig build run
```

The build produces `zig-out/bin/kernel.elf`. The kernel currently prints an allocation test and a boot message, then deliberately panics.

The linker layout is in `linker/kernel.ld`; source files are in `src/`. Notes on QEMU and debugging are in `docs/`.
