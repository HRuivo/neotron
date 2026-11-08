const std = @import("std");
const virtio = @import("virtio.zig");
const sbi_console = @import("../console/sbi_console.zig");

const Register = virtio.Register;

const MMIO_BASE: usize = 0x1000_3000;
const DEVICE_ID: usize = 18;

const transport = virtio.VirtioMmio.init(MMIO_BASE);
const input_device_id = 18;

const InputEvent = extern struct {
    type: u16,
    code: u16,
    value: u32,
};

comptime {
    if (@sizeOf(InputEvent) != 8)
        @compileError("VirtIO input events must be 8 bytes");
}

var events: [virtio.QUEUE_SIZE]InputEvent = undefined;
var event_queue: *virtio.VirtIoQueue = undefined;
var input_sink: ?*const fn (u8) bool = null;

pub fn init(alloc: std.mem.Allocator) void {
    // device check
    if (transport.readRegister(Register.magic) != virtio.VirtioMmio.VIRTIO_MAGIC) {
        @panic("[KEYBOARD]: invalid magic value");
    }
    if (transport.readRegister(Register.version) != 1) {
        @panic("[KEYBOARD]: invalid version");
    }
    if (transport.readRegister(Register.device_id) != DEVICE_ID) {
        @panic("[KEYBOARD]: invalid device id");
    }

    transport.writeRegister(Register.device_status, 0);
    transport.setRegisterBits(Register.device_status, virtio.Status.ack);
    transport.setRegisterBits(Register.device_status, virtio.Status.driver);

    transport.writeRegister(0x24, 0);
    transport.writeRegister(0x20, 0);

    sbi_console.print("[KEYBOARD] Status: 0b{b}\n", .{transport.readRegister(Register.device_status)}) catch {};
    sbi_console.print("[KEYBOARD] events size: {d}\n", .{@sizeOf(@TypeOf(events))}) catch {};

    transport.writeRegister(Register.queue_sel, 0);
    const desc_max = transport.readRegister(Register.queue_num_max);
    sbi_console.print("[KEYBOARD] max: {d}\n", .{desc_max}) catch {};

    transport.writeRegister(Register.page_size, virtio.PAGE_SIZE);
    event_queue = virtio.VirtIoQueue.init(alloc, transport, 0);

    const queue_pfn = transport.readRegister(Register.queue_pfn);
    sbi_console.print("[KEYBOARD] queue pfn: 0x{x} == 0x{x}?\n", .{ queue_pfn, @intFromPtr(event_queue) / virtio.PAGE_SIZE }) catch {};

    for (0..virtio.QUEUE_SIZE) |i| {
        event_queue.descs[i] = .{
            .addr = @intFromPtr(&events[i]),
            .len = @sizeOf(InputEvent),
            .flags = virtio.DescriptorFlags.write,
            .next = 0,
        };

        const slot = event_queue.avail.index % virtio.QUEUE_SIZE;
        event_queue.avail.ring[slot] = @intCast(i);

        asm volatile ("fence iorw, iorw" ::: .{ .memory = true });
        event_queue.avail.index +%= 1;
    }

    asm volatile ("fence iorw, iorw" ::: .{ .memory = true });

    transport.setRegisterBits(Register.device_status, virtio.Status.driver_ok);

    transport.writeRegister(Register.queue_notify, 0);

    sbi_console.print("[KEYBOARD] device status: 0b{b}\n", .{transport.readRegister(Register.device_status)}) catch {};
    sbi_console.print("[KEYBOARD] event_queue.avail.index: {d}\n", .{event_queue.avail.index}) catch {};
}

var next_used: u16 = 0;
pub fn poll() void {
    const current = event_queue.used_index.*;
    asm volatile ("fence iorw, iorw" ::: .{ .memory = true });
    while (next_used != current) {
        const slot = next_used % virtio.QUEUE_SIZE;
        const entry: *volatile virtio.VirtQueueUsedElem = &event_queue.used.ring[slot];

        //sbi_console.print("[KEYBOARD] entry: {d}, len: {d}\n", .{ entry.id, entry.len }) catch {};

        const completed = entry.*;

        if (completed.id >= virtio.QUEUE_SIZE or completed.len != @sizeOf(InputEvent))
            @panic("Keyboard entry id or length is not valid.");

        const event_ptr: *volatile InputEvent = &events[completed.id];
        const event = event_ptr.*;
        handleEvent(event);

        const avail_slot = event_queue.avail.index % virtio.QUEUE_SIZE;
        event_queue.avail.ring[avail_slot] = @intCast(completed.id);
        asm volatile ("fence iorw, iorw" ::: .{ .memory = true });
        event_queue.avail.index +%= 1;

        next_used +%= 1;
    }

    asm volatile ("fence iorw, iorw" ::: .{ .memory = true });
    transport.writeRegister(Register.queue_notify, 0);
}

pub fn setInputSink(sink: *const fn (u8) bool) void {
    input_sink = sink;
}

fn handleEvent(event: InputEvent) void {
    if (event.type != 1 or event.value != 1) return;

    if (translateKey(event.code)) |ch| {
        if (input_sink) |sink| {
            _ = sink(ch);
        }
    }
}

fn translateKey(code: u16) ?u8 {
    return switch (code) {
        2...13 => "1234567890-="[code - 2],
        16...25 => "qwertyuiop"[code - 16],
        30...38 => "asdfghjkl"[code - 30],
        44...50 => "zxcvbnm"[code - 44],
        14 => '\x08',
        28 => '\n',
        57 => ' ',
        else => {
            sbi_console.print("keycode: {d}\n", .{code}) catch {};
            return null;
        },
    };
}
