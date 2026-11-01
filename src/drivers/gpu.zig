const std = @import("std");
const console = @import("../console.zig");
const virtio = @import("virtio.zig");
const graphics = @import("../graphics/framebuffer.zig");
const Framebuffer = graphics.Framebuffer;
const Colour = graphics.Colour;

const MMIO_BASE: usize = 0x10002000;
const DEVICE_ID: usize = 16;
const RESOURCE_ID: u32 = 1;

const gpu = virtio.VirtioMmio.init(MMIO_BASE);
var queue_control_commands: *virtio.VirtIoQueue = undefined;
var queue_mouse: *virtio.VirtIoQueue = undefined;

var framebuffer: Framebuffer = undefined;

const CommandType = enum(u32) {
    get_display_info = 0x0100,
    resource_create_2d = 0x0101,
    set_scanout = 0x0103,
    resource_flush = 0x104,
    transfer_to_host_2d = 0x0105,
    resource_attach_backing = 0x0106,
};

const ResourceFormat = enum(u32) {
    b8g8r8a8 = 1,
};

const ResponseType = enum(u32) {
    ok_nodata = 0x1100,
    ok_display_info = 0x1101,
    _,
};

const GpuControlHeader = extern struct {
    type: u32,
    flags: u32,
    fence_id: u64,
    ctx_id: u32,
    ring_idx: u8,
    padding: [3]u8,

    fn init(command_type: CommandType) GpuControlHeader {
        var header = std.mem.zeroes(GpuControlHeader);
        header.type = @backingInt(command_type);
        return header;
    }

    fn init_zeroes() GpuControlHeader {
        return std.mem.zeroes(GpuControlHeader);
    }
};

comptime {
    if (@sizeOf(GpuControlHeader) != 24)
        @compileError("GPU Command must be of size 24 bytes");
}

const ResourceCreate2D = extern struct {
    header: GpuControlHeader,
    resource_id: u32,
    format: u32,
    width: u32,
    height: u32,

    fn init(resource_id: u32, format: ResourceFormat, width: u32, height: u32) ResourceCreate2D {
        var request = std.mem.zeroes(ResourceCreate2D);
        request.header = GpuControlHeader.init(.resource_create_2d);
        request.resource_id = resource_id;
        request.format = @backingInt(format);
        request.width = width;
        request.height = height;
        return request;
    }
};

comptime {
    if (@sizeOf(ResourceCreate2D) != 40)
        @compileError("Resource Create 2D must be of size 40 bytes");
}

const ResourceAttachBacking = extern struct {
    header: GpuControlHeader,
    resource_id: u32,
    nr_entries: u32,
    addr: u64,
    length: u32,
    padding: u32,

    fn init(resource_id: u32, data: []u8) ResourceAttachBacking {
        var request = std.mem.zeroes(ResourceAttachBacking);
        request.header = GpuControlHeader.init(.resource_attach_backing);
        request.resource_id = resource_id;
        request.nr_entries = 1;
        request.addr = @intFromPtr(data.ptr);
        request.length = @intCast(data.len);
        return request;
    }
};

comptime {
    if (@sizeOf(ResourceAttachBacking) != 48)
        @compileError("Resource Attach Backing must be of size 48 bytes");
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

    fn init() DisplayInfoResponse {
        return std.mem.zeroes(DisplayInfoResponse);
    }
};

const SetScanout = extern struct {
    header: GpuControlHeader,
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    scanout_id: u32,
    resource_id: u32,

    fn init(width: u32, height: u32, scanout_id: u32, source_id: u32) SetScanout {
        var command = std.mem.zeroes(SetScanout);
        command.header = GpuControlHeader.init(.set_scanout);
        command.width = width;
        command.height = height;
        command.scanout_id = scanout_id;
        command.resource_id = source_id;
        return command;
    }
};

comptime {
    if (@sizeOf(SetScanout) != 48)
        @compileError("Set Scanout must be of size 48 bytes");
}

const TransferToHost2D = extern struct {
    header: GpuControlHeader,
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    offset: u64,
    resource_id: u32,
    padding: u32,

    fn init(x: u32, y: u32, width: u32, height: u32, resource_id: u32) TransferToHost2D {
        var command = std.mem.zeroes(TransferToHost2D);
        command.header = GpuControlHeader.init(.transfer_to_host_2d);
        command.x = x;
        command.y = y;
        command.width = width;
        command.height = height;
        command.resource_id = resource_id;
        return command;
    }
};

comptime {
    if (@sizeOf(TransferToHost2D) != 56)
        @compileError("Transfer To Host 2D must be of size 56 bytes");
}

fn transferToHost2D() void {
    var request = TransferToHost2D.init(0, 0, framebuffer.width, framebuffer.height, RESOURCE_ID);
    var response = GpuControlHeader.init_zeroes();

    sendControl(&request, &response);

    const result: ResponseType = @fromBackingInt(@intCast(response.type));
    if (result == .ok_nodata) {
        console.print("[GPU] Transfer To Host 2D:           [OK]\n", .{}) catch {};
    } else {
        console.print("[GPU] Transfer To Host 2D:           [ERR] 0x{x}\n", .{response.type}) catch {};
    }
}

const ResourceFlush = extern struct {
    header: GpuControlHeader,
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    resource_id: u32,
    padding: u32,

    fn init(x: u32, y: u32, width: u32, height: u32, resource_id: u32) ResourceFlush {
        var command = std.mem.zeroes(ResourceFlush);
        command.header = GpuControlHeader.init(.resource_flush);
        command.x = x;
        command.y = y;
        command.width = width;
        command.height = height;
        command.resource_id = resource_id;
        return command;
    }
};

fn resourceFlush() void {
    var request = ResourceFlush.init(0, 0, 1280, 800, RESOURCE_ID);
    var response = GpuControlHeader.init_zeroes();

    sendControl(&request, &response);

    const result: ResponseType = @fromBackingInt(@intCast(response.type));
    if (result == .ok_nodata) {
        console.print("[GPU] Resource Flush:                [OK]\n", .{}) catch {};
    } else {
        console.print("[GPU] Resource Flush:                [ERR] 0x{x}\n", .{response.type}) catch {};
    }
}

pub fn init(allocator: std.mem.Allocator) void {
    const magic = gpu.readRegister(virtio.Register.magic);
    if (magic != virtio.VirtioMmio.VIRTIO_MAGIC) {
        @panic("[virtio][GPU]: invalid magic value");
    }
    const version = gpu.readRegister(virtio.Register.version);
    if (version != 1) {
        @panic("[virtio][GPU]: invalid version");
    }
    const device_id = gpu.readRegister(virtio.Register.device_id);
    if (device_id != DEVICE_ID) {
        std.debug.panic("[virtio][GPU]: invalid devide id={x}", .{device_id});
    }

    console.print(
        "[virtio][GPU]: magic=0x{x}, version={d}, device_id={d}\n",
        .{ magic, version, device_id },
    ) catch {};

    gpu.writeRegister(virtio.Register.device_status, 0);
    gpu.setRegisterBits(virtio.Register.device_status, virtio.Status.ack);
    gpu.setRegisterBits(virtio.Register.device_status, virtio.Status.driver);

    gpu.writeRegister(0x14, 0);
    const feature_word: u32 = gpu.readRegister(0x10);
    console.print("[GPU] Feature word: 0x{x}\n", .{feature_word}) catch {};

    // select driver-feature page 0.
    gpu.writeRegister(0x24, 0);
    // accept no optinal features on that page.
    gpu.writeRegister(0x20, 0);

    gpu.writeRegister(virtio.Register.queue_sel, 0);
    const queue_num_max = gpu.readRegister(virtio.Register.queue_num_max);
    console.print("[GPU] Queue Num Max: {d}\n", .{queue_num_max}) catch {};

    gpu.writeRegister(virtio.Register.page_size, virtio.PAGE_SIZE);

    queue_control_commands = virtio.initQueue(allocator, gpu, 0);
    queue_mouse = virtio.initQueue(allocator, gpu, 1);

    gpu.setRegisterBits(virtio.Register.device_status, virtio.Status.driver_ok);
    const status = gpu.readRegister(virtio.Register.device_status);
    console.print("[GPU] Device status: 0b{b}\n", .{status}) catch {};

    getDisplayInfo();

    framebuffer = Framebuffer.init(allocator, 1280, 800) catch @panic("failed to allocate framebuffer");

    for (0..framebuffer.height) |y| {
        for (0..framebuffer.width) |x| {
            framebuffer.putPixel(.{ .x = x, .y = y }, .{ .r = 19, .g = 128, .b = 134 });
        }
    }

    createResource2D(.b8g8r8a8, framebuffer.width, framebuffer.height);
    attachBackingResource();
    transferToHost2D();
    setScanout(framebuffer.width, framebuffer.height, 0, 1);
    resourceFlush();

    framebuffer.drawRect(.{ .x = 1000, .y = 500 }, .{ .x = 350, .y = 120 }, Colour.white());
    transferToHost2D();
    framebuffer.drawRect(.{ .x = 100, .y = 100 }, .{ .x = 350, .y = 120 }, Colour.red());
    transferToHost2D();

    resourceFlush();
}

fn sendControl(request: anytype, response: anytype) void {
    const request_bytes = std.mem.asBytes(request);
    const response_bytes = std.mem.asBytes(response);

    queue_control_commands.descs[0] = .{
        .addr = @intFromPtr(request_bytes),
        .len = @intCast(request_bytes.len),
        .flags = virtio.DescriptorFlags.next,
        .next = 1,
    };
    queue_control_commands.descs[1] = .{
        .addr = @intFromPtr(response_bytes),
        .len = @intCast(response_bytes.len),
        .flags = virtio.DescriptorFlags.write,
        .next = 0,
    };

    virtio.kickQueue(gpu, queue_control_commands, 0);

    while (virtio.isBusy(queue_control_commands)) {
        asm volatile ("nop");
    }
    asm volatile ("fence iorw, iorw" ::: .{ .memory = true });
}

fn setScanout(width: u32, height: u32, scanout_id: u32, source_id: u32) void {
    var request = SetScanout.init(width, height, scanout_id, source_id);
    var response: GpuControlHeader = GpuControlHeader.init_zeroes();

    sendControl(&request, &response);

    const result: ResponseType = @fromBackingInt(@intCast(response.type));
    if (result == .ok_nodata) {
        console.print("[GPU] Set Scanout:                   [OK]\n", .{}) catch {};
    } else {
        console.print("[GPU] Set Scanout:                   [ERR] 0x{x}\n", .{response.type}) catch {};
    }
}

pub fn attachBackingResource() void {
    var request = ResourceAttachBacking.init(RESOURCE_ID, framebuffer.pixels);
    var response: GpuControlHeader = GpuControlHeader.init_zeroes();

    sendControl(&request, &response);

    const result: ResponseType = @fromBackingInt(@intCast(response.type));
    if (result == .ok_nodata) {
        console.print("[GPU] Attach Backing Resource:       [OK]\n", .{}) catch {};
    } else {
        console.print("[GPU] Attach Backing Resource:       [ERR] 0x{x}\n", .{response.type}) catch {};
    }
}

pub fn createResource2D(format: ResourceFormat, width: u32, height: u32) void {
    var request = ResourceCreate2D.init(RESOURCE_ID, format, width, height);
    var response: GpuControlHeader = GpuControlHeader.init_zeroes();

    sendControl(&request, &response);

    const result: ResponseType = @fromBackingInt(@intCast(response.type));
    if (result == .ok_nodata) {
        console.print("[GPU] Create Resource 2D:            [OK]\n", .{}) catch {};
    } else {
        console.print("[GPU] Create Resource 2D:            [ERR] 0x{x}\n", .{response.type}) catch {};
    }
}

pub fn getDisplayInfo() void {
    var request = GpuControlHeader.init(.get_display_info);
    var response = DisplayInfoResponse.init();

    sendControl(&request, &response);

    const result: ResponseType = @fromBackingInt(@intCast(response.header.type));

    if (result == .ok_display_info) {
        console.print("[GPU] Get Display Info:              [OK]\n", .{}) catch {};
        for (response.displays) |display_info| {
            if (display_info.enabled != 0) {
                console.print("      X:{d}, Y:{d}\n", .{ display_info.x, display_info.y }) catch {};
                console.print("      W:{d}, H:{d}\n", .{ display_info.width, display_info.height }) catch {};
            }
        }
    } else {
        console.print("[GPU] Get Display Info:              [ERR] 0x{x}\n", .{response.header.type}) catch {};
    }
}
