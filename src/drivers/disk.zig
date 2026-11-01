const std = @import("std");
const console = @import("../console.zig");
const virtio = @import("virtio.zig");

const MMIO_BASE: usize = 0x10001000;
const DEVICE_ID: usize = 2;

const SECTOR_SIZE: usize = 512;

var request_queue: *virtio.VirtIoQueue = undefined;
var blk_capacity: u64 = 0;
var blk_req: *VirtIoBlkReq = undefined;

const disk = virtio.VirtioMmio.init(MMIO_BASE);

const VirtIoBlkReq = extern struct {
    type: u32,
    reserved: u32,
    sector: u64,
    data: [SECTOR_SIZE]u8,
    status: u8,
};

const RequestType = enum(u32) {
    read = 0, // BLK_T_IN: disk → RAM
    write = 1, // BLK_T_OUT: RAM → disk
};

pub fn init(allocator: std.mem.Allocator) void {
    // device check
    if (disk.readRegister(virtio.Register.magic) != virtio.VirtioMmio.VIRTIO_MAGIC) {
        @panic("[virtio][DISK]: invalid magic value");
    }
    if (disk.readRegister(virtio.Register.version) != 1) {
        @panic("[virtio][DISK]: invalid version");
    }
    if (disk.readRegister(virtio.Register.device_id) != DEVICE_ID) {
        @panic("[virtio][DISK]: invalid devide id");
    }

    // 1. Reset the device
    disk.writeRegister(virtio.Register.device_status, 0);
    // 2. Set the ACKNOWLEDGE status bit: We found the device.
    disk.setRegisterBits(virtio.Register.device_status, virtio.Status.ack);
    // 3. Set the DRIVER status bit: We know how to use the device.
    disk.setRegisterBits(virtio.Register.device_status, virtio.Status.driver);

    // Set out page sizE: We use 4KB pages. This defines PFN (page frame number)
    disk.writeRegister(virtio.Register.page_size, virtio.PAGE_SIZE);

    request_queue = virtio.initQueue(allocator, disk, 0);

    disk.setRegisterBits(virtio.Register.device_status, virtio.Status.driver_ok);

    // Get the disk capacity
    blk_capacity = disk.readRegister64(virtio.Register.device_config + 0) * SECTOR_SIZE;
    console.print("virtio-blk: capacity is {d} bytes\n", .{blk_capacity}) catch {};

    blk_req = allocator.create(VirtIoBlkReq) catch @panic("failed to allocate disk request");
    @memset(std.mem.asBytes(blk_req), 0);
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
        .flags = virtio.DescriptorFlags.next,
        .next = 1,
    };

    request_queue.descs[1] = .{
        .addr = @intFromPtr(&blk_req.data),
        .len = SECTOR_SIZE,
        .flags = virtio.DescriptorFlags.next | (if (is_write) 0 else virtio.DescriptorFlags.write),
        .next = 2,
    };

    request_queue.descs[2] = .{
        .addr = @intFromPtr(&blk_req.status),
        .len = @sizeOf(u8),
        .flags = virtio.DescriptorFlags.write,
        .next = 0,
    };

    blk_req.status = 0xff;

    virtio.kickQueue(disk, request_queue, 0);

    while (virtio.isBusy(request_queue)) {}

    asm volatile ("fence iorw, iorw" ::: .{ .memory = true });

    if (blk_req.status != 0) {
        console.print("virtio: warn: failed to read/write sector={d} status={d}\n", .{ sector, blk_req.status }) catch {};
        return;
    }

    if (!is_write) {
        @memcpy(buffer[0..], blk_req.data[0..]);
    }
}
