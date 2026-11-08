const std = @import("std");
const Target = @import("std").Target;
const Feature = @import("std").Target.Cpu.Feature;

pub fn build(b: *std.Build) void {
    const kernel = buildKernel(b);

    const run_step = b.step("run", "Run in QEMU");
    const run_qemu = b.addSystemCommand(&(.{
        "qemu-system-riscv32",
        "-machine",
        "virt",
        "-bios",
        "default",
        //"-nographic",
        "-serial",
        "mon:stdio",
        "--no-reboot",
        "-drive",
        "id=drive0,file=lorem.txt,format=raw,if=none",
        "-device",
        "virtio-blk-device,drive=drive0,bus=virtio-mmio-bus.0",
        "-device",
        "virtio-gpu-device,bus=virtio-mmio-bus.1,xres=640,yres=480",
        "-device",
        "virtio-keyboard-device,bus=virtio-mmio-bus.2",
        // "-display",
        // "sdl,gl=on",
        "-s",
        //"-S",
    }));
    run_qemu.addArg("-kernel");
    run_qemu.addFileArg(kernel.getEmittedBin());
    run_step.dependOn(&run_qemu.step);

    const clean_step = b.step("clean", "Clean");
    const clean_cmd = b.addSystemCommand(&(.{
        "rm",
        "-rf",
        "zig-out",
    }));
    clean_step.dependOn(&clean_cmd.step);
}

fn buildKernel(b: *std.Build) *std.Build.Step.Compile {
    const features = Target.riscv.Feature;
    var disabled_features = Feature.Set.empty;
    var enabled_features = Feature.Set.empty;

    disabled_features.addFeature(@backingInt(features.a));
    disabled_features.addFeature(@backingInt(features.c));
    disabled_features.addFeature(@backingInt(features.d));
    disabled_features.addFeature(@backingInt(features.e));
    disabled_features.addFeature(@backingInt(features.f));
    enabled_features.addFeature(@backingInt(features.m));

    const target = b.resolveTargetQuery(.{
        .cpu_arch = .riscv32,
        .os_tag = .freestanding,
        .abi = .none,
        .cpu_model = std.Target.Query.CpuModel{ .explicit = &std.Target.riscv.cpu.generic_rv32 },
        .cpu_features_add = enabled_features,
        .cpu_features_sub = disabled_features,
    });

    const kernel = b.addExecutable(.{
        .name = "kernel",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/kernel.zig"),
            .target = target,
            .optimize = .small,
            .strip = false,
            .unwind_tables = .none,
        }),
    });
    kernel.setLinkerScript(b.path("linker/kernel.ld"));
    kernel.entry = .{ .symbol_name = "boot" };

    const copy_kernel_object = b.addInstallBinFile(kernel.getEmittedBin(), "kernel.elf");
    b.default_step.dependOn(&copy_kernel_object.step);

    const shell = b.addExecutable(.{
        .name = "shell",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/user/shell.zig"),
            .target = target,
            .optimize = .small,
            .strip = false,
            .unwind_tables = .none,
        }),
    });
    shell.setLinkerScript(b.path("linker/user.ld"));
    shell.entry = .{ .symbol_name = "start" };

    const syscall_module = b.createModule(.{
        .root_source_file = b.path("src/abi/syscall.zig"),
        .target = target,
        .optimize = .small,
    });

    shell.root_module.addImport("syscall", syscall_module);
    kernel.root_module.addImport("syscall", syscall_module);

    const install_shell = b.addInstallBinFile(
        shell.getEmittedBin(),
        "shell.elf",
    );
    b.default_step.dependOn(&install_shell.step);

    const shell_bin = b.addSystemCommand(&.{
        "llvm-objcopy",
        "--set-section-flags",
        ".bss=alloc,contents",
        "-O",
        "binary",
    });
    shell_bin.addFileArg(shell.getEmittedBin());
    const shell_bin_output = shell_bin.addOutputFileArg("shell.bin");

    const install_shell_bin = b.addInstallBinFile(
        shell_bin_output,
        "shell.bin",
    );
    b.default_step.dependOn(&install_shell_bin.step);

    kernel.root_module.addAnonymousImport("shell_image", .{
        .root_source_file = shell_bin_output,
    });

    return kernel;
}
