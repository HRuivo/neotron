const std = @import("std");

const free_ram = @extern([*]u8, .{ .name = "__free_ram" });
const free_ram_end = @extern([*]u8, .{ .name = "__free_ram_end" });

pub const PAGE_SIZE: usize = 4096;
const MMIO_DEVICE_BASE_ADDR: usize = 0x1000_0000;
const MMIO_DEVICE_DISK: usize = 0x1000;
const MMIO_DEVICE_GPU: usize = 0x2000;
const MMIO_DEVICE_KEYBOARD: usize = 0x3000;

pub const PageTable = [1024]u32;

var heap: std.heap.FixedBufferAllocator = undefined;

pub const PageFlags = struct {
    pub const valid: u32 = 1 << 0;
    pub const read: u32 = 1 << 1;
    pub const write: u32 = 1 << 2;
    pub const execute: u32 = 1 << 3;
    pub const user: u32 = 1 << 4;

    pub const rw: u32 = read | write;
    pub const rx: u32 = read | execute;
    pub const rwx: u32 = read | write | execute;
};

pub fn init() void {
    const heap_memory = free_ram[0 .. free_ram_end - free_ram];
    heap = std.heap.FixedBufferAllocator.init(heap_memory);
}

pub fn allocator() std.mem.Allocator {
    return heap.allocator();
}

pub fn mapPage(
    alloc: std.mem.Allocator,
    root: *PageTable,
    vaddr: usize,
    paddr: usize,
    flags: u32,
) void {
    if (!std.mem.isAligned(vaddr, PAGE_SIZE) or !std.mem.isAligned(paddr, PAGE_SIZE)) {
        std.debug.panic("could not create a page table for an unaligned address: v{x} p{x}\n", .{ vaddr, paddr });
    }

    const vpn1 = (vaddr >> 22) & 0x3ff;
    if ((root[vpn1] & PageFlags.valid) == 0) {
        const new_table = createPageTable(alloc);
        const table_paddr = @intFromPtr(new_table);

        const table_ppn = table_paddr >> 12;
        root[vpn1] = (table_ppn << 10) | PageFlags.valid;
    }

    const table_paddr = (root[vpn1] >> 10) << 12;
    const table: *PageTable = @ptrFromInt(table_paddr);
    const vpn0 = (vaddr >> 12) & 0x3ff;
    const ppn = paddr >> 12;
    table[vpn0] = (ppn << 10) | flags | PageFlags.valid;
}

pub fn mapKernel(
    alloc: std.mem.Allocator,
    root: *PageTable,
) void {
    var addr: usize = 0x8020_0000;
    while (addr < @intFromPtr(free_ram_end)) : (addr += PAGE_SIZE) {
        mapPage(alloc, root, addr, addr, PageFlags.rwx);
    }

    // VirtIO block device registers
    mapPage(
        alloc,
        root,
        MMIO_DEVICE_BASE_ADDR + MMIO_DEVICE_DISK,
        MMIO_DEVICE_BASE_ADDR + MMIO_DEVICE_DISK,
        PageFlags.rw,
    );

    // VirtIO GPU registers
    mapPage(
        alloc,
        root,
        MMIO_DEVICE_BASE_ADDR + MMIO_DEVICE_GPU,
        MMIO_DEVICE_BASE_ADDR + MMIO_DEVICE_GPU,
        PageFlags.rw,
    );

    // VirtIO keyboard registers: supervisor access only
    mapPage(
        alloc,
        root,
        MMIO_DEVICE_BASE_ADDR + MMIO_DEVICE_KEYBOARD,
        MMIO_DEVICE_BASE_ADDR + MMIO_DEVICE_KEYBOARD,
        PageFlags.rw,
    );
}

pub fn createPageTable(alloc: std.mem.Allocator) *PageTable {
    const entries = alloc.alignedAlloc(
        u32,
        .fromByteUnits(PAGE_SIZE),
        1024,
    ) catch @panic("out of memory for page table");

    @memset(entries, 0);
    return entries[0..1024];
}
