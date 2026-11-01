pub inline fn readCsr(comptime reg: []const u8) usize {
    return asm volatile ("csrr %[result], " ++ reg
        : [result] "=r" (-> usize),
    );
}

pub inline fn writeCsr(comptime reg: []const u8, value: usize) void {
    asm volatile ("csrw " ++ reg ++ ", %[value]"
        :
        : [value] "r" (value),
    );
}

pub fn activatePageTable(root_address: usize) void {
    const ppn = root_address >> 12;
    const sv32 = @as(usize, 1) << 31;
    const satp_value = sv32 | ppn;

    asm volatile (
        \\sfence.vma
        \\csrw satp, %[value]
        \\sfence.vma
        :
        : [value] "r" (satp_value),
        : .{ .memory = true });
}
