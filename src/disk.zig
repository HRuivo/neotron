const std = @import("std");
const console = @import("console.zig");
const hw = @import("hw.zig");

const MMIO_BASE: usize = 0x10001000;
const DEVICE_ID: usize = 2;

const SECTOR_SIZE: usize = 512;

var request_queue: *hw.VirtIoQueue = undefined;
var blk_capacity: u64 = 0;
var blk_req: *VirtIoBlkReq = undefined;

const disk = hw.VirtioMmio.init(MMIO_BASE);

comptime {
    if (@sizeOf(hw.VirtQueueDesc) != 16)
        @compileError("description must occupy 16 bytes");
    if (@offsetOf(hw.VirtIoQueue, "used") != hw.PAGE_SIZE)
        @compileError("used ring must begin at offset 4096");
}

const VirtIoBlkReq = extern struct {
    type: u32,
    reserved: u32,
    sector: u64,
    data: [SECTOR_SIZE]u8,
    status: u8,
};

pub fn init(allocator: std.mem.Allocator) void {
    // device check
    if (disk.readRegister(hw.Register.magic) != hw.VirtioMmio.VIRTIO_MAGIC) {
        @panic("[virtio][DISK]: invalid magic value");
    }
    if (disk.readRegister(hw.Register.version) != 1) {
        @panic("[virtio][DISK]: invalid version");
    }
    if (disk.readRegister(hw.Register.device_id) != DEVICE_ID) {
        @panic("[virtio][DISK]: invalid devide id");
    }

    // 1. Reset the device
    disk.writeRegister(hw.Register.device_status, 0);
    // 2. Set the ACKNOWLEDGE status bit: We found the device.
    disk.setRegisterBits(hw.Register.device_status, hw.Status.ack);
    // 3. Set the DRIVER status bit: We know how to use the device.
    disk.setRegisterBits(hw.Register.device_status, hw.Status.driver);

    // Set out page sizE: We use 4KB pages. This defines PFN (page frame number)
    disk.writeRegister(hw.Register.page_size, hw.PAGE_SIZE);

    request_queue = initQueue(allocator, 0);

    disk.setRegisterBits(hw.Register.device_status, hw.Status.driver_ok);

    // Get the disk capacity
    blk_capacity = disk.readRegister64(hw.Register.device_config + 0) * SECTOR_SIZE;
    console.print("virtio-blk: capacity is {d} bytes\n", .{blk_capacity}) catch {};

    blk_req = allocator.create(VirtIoBlkReq) catch @panic("failed to allocate disk request");
    @memset(std.mem.asBytes(blk_req), 0);
}

fn initQueue(allocator: std.mem.Allocator, index: u32) *hw.VirtIoQueue {
    const queue = allocator.create(hw.VirtIoQueue) catch @panic("out of memory for VirtIO queue");
    @memset(std.mem.asBytes(queue), 0);

    queue.queue_index = index;
    queue.used_index = &queue.used.index;

    disk.writeRegister(hw.Register.queue_sel, index);
    const max_size = disk.readRegister(hw.Register.queue_num_max);
    if (max_size < hw.QUEUE_SIZE) {
        @panic("VirtIO queue is too small or unavailable");
    }
    disk.writeRegister(hw.Register.queue_num, hw.QUEUE_SIZE);
    disk.writeRegister(hw.Register.queue_pfn, @intFromPtr(queue) / hw.PAGE_SIZE);

    return queue;
}

fn kickQueue(queue: *hw.VirtIoQueue, head: u16) void {
    queue.avail.ring[queue.avail.index % hw.QUEUE_SIZE] = head;
    queue.avail.index +%= 1;

    asm volatile ("fence iorw, iorw" ::: .{ .memory = true });

    disk.writeRegister(hw.Register.queue_notify, queue.queue_index);
    queue.last_used_index +%= 1;
}

fn isBusy(queue: *hw.VirtIoQueue) bool {
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
    const operation: hw.RequestType = if (is_write) .write else .read;
    blk_req.type = @backingInt(operation);
    if (is_write) {
        @memcpy(blk_req.data[0..], buffer[0..]);
    }

    request_queue.descs[0] = .{
        .addr = @intFromPtr(blk_req),
        .len = 16,
        .flags = hw.DescriptorFlags.next,
        .next = 1,
    };

    request_queue.descs[1] = .{
        .addr = @intFromPtr(&blk_req.data),
        .len = SECTOR_SIZE,
        .flags = hw.DescriptorFlags.next | (if (is_write) 0 else hw.DescriptorFlags.write),
        .next = 2,
    };

    request_queue.descs[2] = .{
        .addr = @intFromPtr(&blk_req.status),
        .len = @sizeOf(u8),
        .flags = hw.DescriptorFlags.write,
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
