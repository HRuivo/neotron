# neotron

A small experimental RISC-V kernel written in Zig. It runs on QEMU's 32-bit `virt` machine with OpenSBI and currently demonstrates console output, a custom panic handler, and page-aligned allocation from a linker-defined RAM region.

Largely based on the OS in 1000 Lines tutorial.

- Supervisor-mode kernel running through OpenSBI.
- Sv32 page tables and cooperative process scheduling.
- User-mode shell with console and exit syscalls.
- VirtIO block and GPU drivers.
- Framebuffer drawing with a temporary kernel graphics demo.
- Build dependencies: Zig, qemu-system-riscv32, and llvm-objcopy.

## Build and run

Requires Zig 0.17.0 and `qemu-system-riscv32`.

```sh
zig build
zig build run
```

For a demo screenshot, wait for the initialization summary and shell prompt
in the QEMU display. Click the display, type `hello`, and press Enter to show
`Hello world from shell!` beneath the boot messages.
