const std = @import("std");
const console = @import("console.zig");

const SECTOR_SIZE: usize = 512;
const QUEUE_SIZE: usize = 16;
const MMIO_BASE: usize = 0x10001000;
const DEVICE_BLK: usize = 2;
const PAGE_SIZE: usize = 4096;

var request_queue: *VirtIoQueue = undefined;
var blk_capacity: u64 = 0;
var blk_req: *VirtIoBlkReq = undefined;

comptime {
    if (@sizeOf(VirtQueueDesc) != 16)
        @compileError("description must occupy 16 bytes");
    if (@offsetOf(VirtIoQueue, "used") != PAGE_SIZE)
        @compileError("used ring must begin at offset 4096");
}

const Register = struct {
    const magic: usize = 0x00;
    const version: usize = 0x04;
    const device_id: usize = 0x08;
    const page_size = 0x28;
    const queue_sel = 0x30;
    const queue_num_max = 0x34;
    const queue_num = 0x38;
    const queue_pfn = 0x40;
    const queue_ready = 0x44;
    const queue_notify = 0x50;
    const device_status = 0x70;
    const device_config = 0x100;
};

const Status = struct {
    const ack: usize = 1;
    const driver: usize = 2;
    const driver_ok: usize = 4;
};

const DescriptorFlags = struct {
    const next: u16 = 1;
    const write: u16 = 2;
};

const RequestType = enum(u32) {
    read = 0, // BLK_T_IN: disk → RAM
    write = 1, // BLK_T_OUT: RAM → disk
};

pub const VirtQueueDesc = extern struct {
    addr: u64,
    len: u32,
    flags: u16,
    next: u16,
};

const VirtQueueAvail = extern struct {
    flags: u16,
    index: u16,
    ring: [QUEUE_SIZE]u16,
};

const VirtQueueUsedElem = extern struct {
    id: u32,
    len: u32,
};

const VirtQueueUsed = extern struct {
    flags: u16,
    index: u16,
    ring: [QUEUE_SIZE]VirtQueueUsedElem,
};

const VirtIoQueue = extern struct {
    descs: [QUEUE_SIZE]VirtQueueDesc,
    avail: VirtQueueAvail,
    used: VirtQueueUsed align(PAGE_SIZE),
    queue_index: usize,
    used_index: *volatile u16,
    last_used_index: u16,
};

const VirtIoBlkReq = extern struct {
    type: u32,
    reserved: u32,
    sector: u64,
    data: [SECTOR_SIZE]u8,
    status: u8,
};

fn readRegister(offset: usize) u32 {
    const register: *volatile u32 = @ptrFromInt(MMIO_BASE + offset);
    return register.*;
}

fn readRegister64(offset: usize) u64 {
    const low = readRegister(offset);
    const high = readRegister(offset + 4);
    return (@as(u64, high) << 32) | @as(u64, low);
}

fn writeRegister(offset: usize, value: u32) void {
    const register: *volatile u32 = @ptrFromInt(MMIO_BASE + offset);
    register.* = value;
}

fn setRegisterBits(offset: usize, bits: u32) void {
    writeRegister(offset, readRegister(offset) | bits);
}

pub fn init(allocator: std.mem.Allocator) void {
    if (readRegister(Register.magic) != 0x74726976) {
        @panic("virtio: invalid magic value");
    }
    if (readRegister(Register.version) != 1) {
        @panic("virtio: invalid version");
    }
    if (readRegister(Register.device_id) != DEVICE_BLK) {
        @panic("virtio: invalid devide id");
    }

    // 1. Reset the device
    writeRegister(Register.device_status, 0);
    // 2. Set the ACKNOWLEDGE status bit: We found the device.
    setRegisterBits(Register.device_status, Status.ack);
    // 3. Set the DRIVER status bit: We know how to use the device.
    setRegisterBits(Register.device_status, Status.driver);
    // Set out page sizE: We use 4KB pages. This defines PFN (page frame number)
    writeRegister(Register.page_size, PAGE_SIZE);

    request_queue = initQueue(allocator, 0);

    setRegisterBits(Register.device_status, Status.driver_ok);

    // Get the disk capacity
    blk_capacity = readRegister64(Register.device_config + 0) * SECTOR_SIZE;
    console.print("virtio-blk: capacity is {d} bytes\n", .{blk_capacity}) catch {};

    blk_req = allocator.create(VirtIoBlkReq) catch @panic("failed to allocate disk request");
    @memset(std.mem.asBytes(blk_req), 0);
}

fn initQueue(allocator: std.mem.Allocator, index: u32) *VirtIoQueue {
    const queue = allocator.create(VirtIoQueue) catch @panic("out of memory for VirtIO queue");
    @memset(std.mem.asBytes(queue), 0);

    queue.queue_index = index;
    queue.used_index = &queue.used.index;

    writeRegister(Register.queue_sel, index);
    const max_size = readRegister(Register.queue_num_max);
    if (max_size < QUEUE_SIZE) {
        @panic("VirtIO queue is too small or unavailable");
    }
    writeRegister(Register.queue_num, QUEUE_SIZE);
    writeRegister(Register.queue_pfn, @intFromPtr(queue) / PAGE_SIZE);

    return queue;
}

fn kickQueue(queue: *VirtIoQueue, head: u16) void {
    queue.avail.ring[queue.avail.index % QUEUE_SIZE] = head;
    queue.avail.index +%= 1;

    asm volatile ("fence iorw, iorw" ::: .{ .memory = true });

    writeRegister(Register.queue_notify, queue.queue_index);
    queue.last_used_index +%= 1;
}

fn isBusy(queue: *VirtIoQueue) bool {
    return queue.last_used_index != queue.used_index.*;
}

pub fn readWriteDisk(
    buffer: *[SECTOR_SIZE]u8,
    sector: u64,
    is_write: bool,
) void {
    if (sector >= blk_capacity / SECTOR_SIZE) {
        @panic("disk sector out of range");
    }

    blk_req.sector = sector;
    const operation: RequestType = if (is_write) .write else .read;
    blk_req.type = @backingInt(operation);
    if (is_write) {
        @memcpy(blk_req.data[0..], buffer[0..]);
    }

    request_queue.descs[0] = .{
        .addr = @intFromPtr(blk_req),
        .len = 16,
        .flags = DescriptorFlags.next,
        .next = 1,
    };

    request_queue.descs[1] = .{
        .addr = @intFromPtr(&blk_req.data),
        .len = SECTOR_SIZE,
        .flags = DescriptorFlags.next | (if (is_write) 0 else DescriptorFlags.write),
        .next = 2,
    };

    request_queue.descs[2] = .{
        .addr = @intFromPtr(&blk_req.status),
        .len = @sizeOf(u8),
        .flags = DescriptorFlags.write,
        .next = 0,
    };

    blk_req.status = 0xff;

    kickQueue(request_queue, 0);

    while (isBusy(request_queue)) {}

    asm volatile ("fence iorw, iorw" ::: .{ .memory = true });

    if (blk_req.status != 0) {
        console.print("virtio: warn: failed to read/write sector={d} status={d}\n", .{ sector, blk_req.status }) catch {};
        return;
    }

    if (!is_write) {
        @memcpy(buffer[0..], blk_req.data[0..]);
    }
}
