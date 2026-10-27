Register	ABI Name (alias)	Description

pc	        pc	                Program counter (where the next instruction is)

x0	        zero	            Hardwired zero (always reads as zero)

x1	        ra	                Return address

x2	        sp	                Stack pointer

x5 - x7 	t0 - t2	            Temporary registers

x8	        fp	                Stack frame pointer

x10 - x11	a0 - a1	            Function arguments/return values
x12 - x17	a2 - a7	            Function arguments

x18 - x27	s0 - s11	        Temporary registers saved across calls
x28 - x31	t3 - t6	            Temporary registers
