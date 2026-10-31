const std = @import("std");
const console = @import("console.zig");
const hw = @import("hw.zig");

comptime {
    if (@alignOf(hw.VirtIoQueue) < hw.PAGE_SIZE)
        @compileError("VirtIO queue must be page aligned");

    if (@offsetOf(hw.VirtIoQueue, "used") != hw.PAGE_SIZE)
        @compileError("used ring must begin at offset PAGE_SIZE");

    if (@sizeOf(GpuControlHeader) != 24)
        @compileError("GPU Command must be of size 24 bytes");
}

const MMIO_BASE: usize = 0x10002000;
const DEVICE_ID: usize = 16;

const gpu = hw.VirtioMmio.init(MMIO_BASE);
var queue_control_commands: *hw.VirtIoQueue = undefined;
var queue_mouse: *hw.VirtIoQueue = undefined;

const Register = struct {
    const magic: usize = 0x00;
    const version: usize = 0x04;
    const device_id: usize = 0x08;
};

const GpuControlHeader = extern struct {
    type: u32,
    flags: u32,
    fence_id: u64,
    ctx_id: u32,
    ring_idx: u8,
    padding: [3]u8,
};

pub fn init(allocator: std.mem.Allocator) void {
    const magic = gpu.readRegister(hw.Register.magic);
    if (magic != hw.VirtioMmio.VIRTIO_MAGIC) {
        @panic("[virtio][GPU]: invalid magic value");
    }
    const version = gpu.readRegister(hw.Register.version);
    if (version != 1) {
        @panic("[virtio][GPU]: invalid version");
    }
    const device_id = gpu.readRegister(hw.Register.device_id);
    if (device_id != DEVICE_ID) {
        std.debug.panic("[virtio][GPU]: invalid devide id={x}", .{device_id});
    }

    console.print(
        "[virtio][GPU]: magic=0x{x}, version={d}, device_id={d}\n",
        .{ magic, version, device_id },
    ) catch {};

    gpu.writeRegister(hw.Register.device_status, 0);
    gpu.setRegisterBits(hw.Register.device_status, hw.Status.ack);
    gpu.setRegisterBits(hw.Register.device_status, hw.Status.driver);

    gpu.writeRegister(0x14, 0);
    const feature_word: u32 = gpu.readRegister(0x10);
    console.print("[GPU] Feature word: 0x{x}\n", .{feature_word}) catch {};

    // select driver-feature page 0.
    gpu.writeRegister(0x24, 0);
    // accept no optinal features on that page.
    gpu.writeRegister(0x20, 0);

    gpu.writeRegister(hw.Register.queue_sel, 0);
    const queue_num_max = gpu.readRegister(hw.Register.queue_num_max);
    console.print("[GPU] Queue Num Max: {d}\n", .{queue_num_max}) catch {};

    gpu.writeRegister(hw.Register.page_size, hw.PAGE_SIZE);

    queue_control_commands = initQueue(allocator, gpu, 0);
    queue_mouse = initQueue(allocator, gpu, 1);

    gpu.setRegisterBits(hw.Register.device_status, hw.Status.driver_ok);
    const status = gpu.readRegister(hw.Register.device_status);
    console.print("[GPU] Device status: 0b{b}\n", .{status}) catch {};

    getDisplayInfo();
}

fn initQueue(
    allocator: std.mem.Allocator,
    transport: hw.VirtioMmio,
    index: u32,
) *hw.VirtIoQueue {
    const queue = allocator.create(hw.VirtIoQueue) catch @panic("out of memory for VirtIO queue");
    @memset(std.mem.asBytes(queue), 0);

    queue.queue_index = index;
    queue.used_index = &queue.used.index;

    transport.writeRegister(hw.Register.queue_sel, index);
    const max_size = transport.readRegister(hw.Register.queue_num_max);
    if (max_size < hw.QUEUE_SIZE) {
        @panic("VirtIO queue is too small or unavailable");
    }
    transport.writeRegister(hw.Register.queue_num, hw.QUEUE_SIZE);
    transport.writeRegister(hw.Register.queue_align, hw.PAGE_SIZE);
    transport.writeRegister(hw.Register.queue_pfn, @intFromPtr(queue) / hw.PAGE_SIZE);

    return queue;
}

const DisplayInfoEntry = extern struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    enabled: u32,
    flags: u32,
};

const DisplayInfoResponse = extern struct {
    header: GpuControlHeader,
    displays: [16]DisplayInfoEntry,
};

pub fn getDisplayInfo() void {
    var request = std.mem.zeroes(GpuControlHeader);
    request.type = 0x0100;

    var response_buff = std.mem.zeroes(DisplayInfoResponse);

    queue_control_commands.descs[0] = .{
        .addr = @intFromPtr(&request),
        .len = @sizeOf(GpuControlHeader),
        .flags = hw.DescriptorFlags.next,
        .next = 1,
    };
    queue_control_commands.descs[1] = .{
        .addr = @intFromPtr(&response_buff),
        .len = @sizeOf(DisplayInfoResponse),
        .flags = hw.DescriptorFlags.write,
        .next = 0,
    };

    kickQueue(gpu, queue_control_commands, 0);

    while (isBusy(queue_control_commands)) {
        asm volatile ("nop");
    }
    asm volatile ("fence iorw, iorw" ::: .{ .memory = true });

    console.print("[GPU] Display Info Header Type: 0x{x}\n", .{response_buff.header.type}) catch {};
    for (response_buff.displays) |display_info| {
        if (display_info.enabled != 0) {
            console.print("[CPU] Display X:{d}, Y:{d}\n", .{ display_info.x, display_info.y }) catch {};
            console.print("[CPU] Display W:{d}, H:{d}\n", .{ display_info.width, display_info.height }) catch {};
        }
    }
}

fn kickQueue(transport: hw.VirtioMmio, queue: *hw.VirtIoQueue, head: u16) void {
    queue.avail.ring[queue.avail.index % hw.QUEUE_SIZE] = head;
    queue.avail.index +%= 1;

    asm volatile ("fence iorw, iorw" ::: .{ .memory = true });

    transport.writeRegister(hw.Register.queue_notify, queue.queue_index);
    queue.last_used_index +%= 1;
}

fn isBusy(queue: *hw.VirtIoQueue) bool {
    return queue.last_used_index != queue.used_index.*;
}
