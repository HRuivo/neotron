const std = @import("std");

pub const QUEUE_SIZE: usize = 16;
pub const PAGE_SIZE: usize = 4096;

pub const Register = struct {
    pub const magic: usize = 0x00;
    pub const version: usize = 0x04;
    pub const device_id: usize = 0x08;
    pub const page_size = 0x28;
    pub const queue_sel = 0x30;
    pub const queue_num_max = 0x34;
    pub const queue_num = 0x38;
    pub const queue_align = 0x3c;
    pub const queue_pfn = 0x40;
    pub const queue_ready = 0x44;
    pub const queue_notify = 0x50;
    pub const device_status = 0x70;
    pub const device_config = 0x100;
};

pub const Status = struct {
    pub const ack: usize = 1;
    pub const driver: usize = 2;
    pub const driver_ok: usize = 4;
};

pub const VirtQueueDesc = extern struct {
    addr: u64,
    len: u32,
    flags: u16,
    next: u16,
};

comptime {
    if (@sizeOf(VirtQueueDesc) != 16)
        @compileError("description must occupy 16 bytes");
}

pub const VirtQueueAvail = extern struct {
    flags: u16,
    index: u16,
    ring: [QUEUE_SIZE]u16,
};

pub const VirtQueueUsedElem = extern struct {
    id: u32,
    len: u32,
};

pub const VirtQueueUsed = extern struct {
    flags: u16,
    index: u16,
    ring: [QUEUE_SIZE]VirtQueueUsedElem,
};

pub const VirtIoQueue = extern struct {
    descs: [QUEUE_SIZE]VirtQueueDesc,
    avail: VirtQueueAvail,
    used: VirtQueueUsed align(PAGE_SIZE),
    queue_index: usize,
    used_index: *volatile u16,
    last_used_index: u16,
};

comptime {
    if (@offsetOf(VirtIoQueue, "used") != PAGE_SIZE)
        @compileError("used ring must begin at offset 4096");
    if (@alignOf(VirtIoQueue) < PAGE_SIZE)
        @compileError("VirtIO queue must be page aligned");
    if (@offsetOf(VirtIoQueue, "used") != PAGE_SIZE)
        @compileError("used ring must begin at offset PAGE_SIZE");
}

pub const DescriptorFlags = struct {
    pub const next: u16 = 1;
    pub const write: u16 = 2;
};

pub const VirtioMmio = struct {
    pub const VIRTIO_MAGIC: usize = 0x74726976;

    base: usize,

    pub fn init(mmio_base: usize) VirtioMmio {
        return .{
            .base = mmio_base,
        };
    }

    pub fn readRegister(self: VirtioMmio, offset: usize) u32 {
        const register: *volatile u32 = @ptrFromInt(self.base + offset);
        return register.*;
    }

    pub fn readRegister64(self: VirtioMmio, offset: usize) u64 {
        const low = self.readRegister(offset);
        const high = self.readRegister(offset + 4);
        return (@as(u64, high) << 32) | @as(u64, low);
    }

    pub fn writeRegister(self: VirtioMmio, offset: usize, value: u32) void {
        const register: *volatile u32 = @ptrFromInt(self.base + offset);
        register.* = value;
    }

    pub fn setRegisterBits(self: VirtioMmio, offset: usize, bits: u32) void {
        self.writeRegister(offset, self.readRegister(offset) | bits);
    }
};

pub fn initQueue(
    allocator: std.mem.Allocator,
    transport: VirtioMmio,
    index: u32,
) *VirtIoQueue {
    const queue = allocator.create(VirtIoQueue) catch @panic("out of memory for VirtIO queue");
    @memset(std.mem.asBytes(queue), 0);

    queue.queue_index = index;
    queue.used_index = &queue.used.index;

    transport.writeRegister(Register.queue_sel, index);
    const max_size = transport.readRegister(Register.queue_num_max);
    if (max_size < QUEUE_SIZE) {
        @panic("VirtIO queue is too small or unavailable");
    }
    transport.writeRegister(Register.queue_num, QUEUE_SIZE);
    transport.writeRegister(Register.queue_align, PAGE_SIZE);
    transport.writeRegister(Register.queue_pfn, @intFromPtr(queue) / PAGE_SIZE);

    return queue;
}

pub fn kickQueue(
    transport: VirtioMmio,
    queue: *VirtIoQueue,
    head: u16,
) void {
    queue.avail.ring[queue.avail.index % QUEUE_SIZE] = head;
    queue.avail.index +%= 1;

    asm volatile ("fence iorw, iorw" ::: .{ .memory = true });

    transport.writeRegister(Register.queue_notify, queue.queue_index);
    queue.last_used_index +%= 1;
}

pub fn isBusy(queue: *VirtIoQueue) bool {
    return queue.last_used_index != queue.used_index.*;
}
