const std = @import("std");
const console = @import("../console/console.zig");
const virtio = @import("virtio.zig");

const MMIO_BASE: usize = 0x10001000;
const DEVICE_ID: usize = 2;

const SECTOR_SIZE: usize = 512;

const transport = virtio.VirtioMmio.init(MMIO_BASE);

var queue: *virtio.VirtIoQueue = undefined;
var blk_capacity: u64 = 0;
var blk_req: *VirtIoBlkReq = undefined;

const BlockRequestHeader = extern struct {
    type: u32,
    reserved: u32,
    sector: u64,
};

const VirtIoBlkReq = extern struct {
    header: BlockRequestHeader,
    data: [SECTOR_SIZE]u8,
    status: u8,
};

const RequestType = enum(u32) {
    read = 0, // BLK_T_IN: disk → RAM
    write = 1, // BLK_T_OUT: RAM → disk
};

pub fn init(allocator: std.mem.Allocator) void {
    // device check
    if (transport.readRegister(virtio.Register.magic) != virtio.VirtioMmio.VIRTIO_MAGIC) {
        @panic("[virtio][DISK]: invalid magic value");
    }
    if (transport.readRegister(virtio.Register.version) != 1) {
        @panic("[virtio][DISK]: invalid version");
    }
    if (transport.readRegister(virtio.Register.device_id) != DEVICE_ID) {
        @panic("[virtio][DISK]: invalid device id");
    }

    // 1. Reset the device
    transport.writeRegister(virtio.Register.device_status, 0);
    // 2. Set the ACKNOWLEDGE status bit: We found the device.
    transport.setRegisterBits(virtio.Register.device_status, virtio.Status.ack);
    // 3. Set the DRIVER status bit: We know how to use the device.
    transport.setRegisterBits(virtio.Register.device_status, virtio.Status.driver);

    // Set the page size used to calculate the queue's page frame number.
    transport.writeRegister(virtio.Register.page_size, virtio.PAGE_SIZE);

    queue = virtio.VirtIoQueue.init(allocator, transport, 0);

    transport.setRegisterBits(virtio.Register.device_status, virtio.Status.driver_ok);

    // Get the disk capacity
    blk_capacity = transport.readRegister64(virtio.Register.device_config + 0) * SECTOR_SIZE;
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

    const operation: RequestType = if (is_write) .write else .read;
    if (is_write) {
        @memcpy(blk_req.data[0..], buffer[0..]);
    }

    const written = submitRequest(sector, operation);

    // A read writes the sector data followed by the status byte.
    // A write only writes the status byte.
    const expected_written: usize =
        if (is_write) 1 else SECTOR_SIZE + 1;

    if (written < expected_written) {
        console.print(
            "virtio: short response for sector={d}\n",
            .{sector},
        ) catch {};
        return;
    }

    if (blk_req.status != 0) {
        console.print(
            "virtio: failed to read/write sector={d} status={d}\n",
            .{ sector, blk_req.status },
        ) catch {};
        return;
    }

    if (!is_write) {
        @memcpy(buffer[0..], blk_req.data[0..]);
    }
}

// The shared request and descriptors support one operation at a time.
fn submitRequest(sector: u64, operation: RequestType) usize {
    blk_req.header = .{
        .type = @backingInt(operation),
        .reserved = 0,
        .sector = sector,
    };
    blk_req.status = 0xff;

    queue.descs[0] = .{
        .addr = @intFromPtr(&blk_req.header),
        .len = @sizeOf(BlockRequestHeader),
        .flags = virtio.DescriptorFlags.next,
        .next = 1,
    };

    queue.descs[1] = .{
        .addr = @intFromPtr(&blk_req.data),
        .len = SECTOR_SIZE,
        .flags = virtio.DescriptorFlags.next | (if (operation == .read) virtio.DescriptorFlags.write else 0),
        .next = 2,
    };

    queue.descs[2] = .{
        .addr = @intFromPtr(&blk_req.status),
        .len = @sizeOf(u8),
        .flags = virtio.DescriptorFlags.write,
        .next = 0,
    };

    return transport.submitAndWait(queue, 0);
}
