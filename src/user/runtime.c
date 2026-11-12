#include "runtime.h"

extern char __stack_top[];

__attribute__((section(".text.start")))
__attribute__((naked))
void start(void) {
    __asm__ __volatile__(
        "la sp, __stack_top\n"
        "call main\n"
        "call exit\n"
    );
}

void put_char(unsigned char ch) {
    register long num __asm__("a3") = 1;
    register long a0 __asm__("a0") = ch;

    __asm__ __volatile__("ecall"
        : "+r"(a0)
        : "r"(num)
        : "memory"
    );
}

_Noreturn void exit(void) {
    register long num __asm__("a3") = 3;

    __asm__ __volatile__("ecall"
        :
        : "r"(num)
        : "memory"
    );

    __builtin_unreachable();
}
