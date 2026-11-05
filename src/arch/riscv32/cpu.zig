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

pub fn readTime() u64 {
    while (true) {
        const high_before = readCsr("timeh");
        const low = readCsr("time");
        const high_after = readCsr("timeh");
        if (high_before == high_after) {
            return (@as(u64, high_before) << 32) | @as(u64, low);
        }
    }
}

pub fn waitTicks(ticks: u64) void {
    const start = readTime();
    while ((readTime() - start) < ticks) {}
}

pub fn sleepMs(milliseconds: u64) void {
    waitTicks(milliseconds * 10_000);
}
