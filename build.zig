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
        "-nographic",
        "-serial",
        "mon:stdio",
        "--no-reboot",
        // "-s",
        // "-S",
        "-kernel",
        b.pathJoin(&.{ "zig-out/bin", kernel }),
    }));
    run_qemu.step.dependOn(b.default_step);
    run_step.dependOn(&run_qemu.step);

    const clean_step = b.step("clean", "Clean");
    const clean_cmd = b.addSystemCommand(&(.{
        "rm",
        "-rf",
        "zig-out",
    }));
    clean_cmd.step.dependOn(b.default_step);
    clean_step.dependOn(&clean_cmd.step);
}

fn buildKernel(b: *std.Build) []const u8 {
    const features = Target.riscv.Feature;
    var disabled_features = Feature.Set.empty;
    var enabled_features = Feature.Set.empty;

    disabled_features.addFeature(@intFromEnum(features.a));
    disabled_features.addFeature(@intFromEnum(features.c));
    disabled_features.addFeature(@intFromEnum(features.d));
    disabled_features.addFeature(@intFromEnum(features.e));
    disabled_features.addFeature(@intFromEnum(features.f));
    enabled_features.addFeature(@intFromEnum(features.m));

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
            .optimize = .ReleaseSmall,
            .strip = false,
        }),
    });
    kernel.setLinkerScript(b.path("linker/kernel.ld"));
    kernel.entry = .{ .symbol_name = "boot" };

    const copy_kernel_object = b.addInstallBinFile(kernel.getEmittedBin(), "kernel.elf");

    b.default_step.dependOn(&copy_kernel_object.step);
    copy_kernel_object.step.dependOn(&kernel.step);

    return copy_kernel_object.dest_rel_path;
}
