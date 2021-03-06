/* Copyright (C) 2014 Stony Brook University
   This file is part of Graphene Library OS.

   Graphene Library OS is free software: you can redistribute it and/or
   modify it under the terms of the GNU Lesser General Public License
   as published by the Free Software Foundation, either version 3 of the
   License, or (at your option) any later version.

   Graphene Library OS is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
   GNU Lesser General Public License for more details.

   You should have received a copy of the GNU Lesser General Public License
   along with this program.  If not, see <http://www.gnu.org/licenses/>.  */

/*
 * syscallas.S
 *
 * This file contains the entry point of system call table in library OS.
 */

#include <shim_defs.h>
#include <shim_tls.h>
#include <shim_unistd_defs.h>

#include "asm-offsets.h"

        .global syscalldb
        .type syscalldb, @function
        .extern shim_table, debug_unsupp
        .global syscall_wrapper
        .type syscall_wrapper, @function
        .global syscall_wrapper_after_syscalldb
        .type syscall_wrapper_after_syscalldb, @function

        .global __syscallas_signal_allowed_0_begin
        .global __syscallas_signal_allowed_0_end
        .global __syscallas_signal_allowed_1_begin
        .global __syscallas_signal_allowed_1_end
        .global __syscallas_signal_allowed_2_begin
        .global __syscallas_signal_allowed_2_end
        .global __syscallas_signal_allowed_3_begin
        .global __syscallas_signal_allowed_3_end
        .type __syscallas_signal_allowed_0_begin, @object
        .type __syscallas_signal_allowed_0_end, @object
        .type __syscallas_signal_allowed_1_begin, @object
        .type __syscallas_signal_allowed_1_end, @object
        .type __syscallas_signal_allowed_2_begin, @object
        .type __syscallas_signal_allowed_2_end, @object
        .type __syscallas_signal_allowed_3_begin, @object
        .type __syscallas_signal_allowed_3_end, @object

#ifdef SHIM_TCB_USE_GS
# define TCB_SEGMENT_REG	%gs
#else
# define TCB_SEGMENT_REG	%fs
#endif

.macro CLEAR_SAVED_AREA_IN_SHIM_TLS
        movq $0, TCB_SEGMENT_REG:(SHIM_TCB_OFFSET + TCB_REGS)
.endm

.macro CHECK_SIGNAL_PENDING_BIT
        lock btrq $SHIM_FLAG_SIGPENDING, TCB_SEGMENT_REG:(SHIM_TCB_OFFSET + TCB_FLAGS)
.endm

syscalldb:
        .cfi_startproc

__syscallas_signal_allowed_0_begin:
        # Create shim_regs struct on the stack.
        pushfq

        # Under GDB, single-stepping sets Trap Flag (TP) of EFLAGS,
        # thus TP=1 is stored on pushfq above. Upon consequent popfq,
        # TP is 1, resulting in spurious trap. Reset TP here.
        andq $~0x100, (%rsp)

        cld
        pushq %rbp
        pushq %rbx
        pushq %rdi
        pushq %rsi
        pushq %rdx
        pushq %rcx
        pushq %r8
        pushq %r9
        pushq %r10
        pushq %r11
        pushq %r12
        pushq %r13
        pushq %r14
        pushq %r15
        leaq SHIM_REGS_SIZE - SHIM_REGS_R15(%rsp), %rbx
        pushq %rbx
        pushq %rax
        # shim_regs struct ends here.

        movq %rsp, %rbp
        .cfi_def_cfa_offset SHIM_REGS_SIZE
        .cfi_offset %rbp, -3 * 8    # saved_rbp is at CFA-24 (saved_rflags + saved_rbp)
        .cfi_def_cfa_register %rbp  # %rbp

        cmp $LIBOS_SYSCALL_BOUND, %rax
        jae isundef

        movq shim_table@GOTPCREL(%rip), %rbx
        movq (%rbx,%rax,8), %rbx
        cmp $0, %rbx
        je isundef
__syscallas_signal_allowed_0_end:

        ## struct shim_regs
        ##   %orig_rax
        ##   %rsp
        ##   %r15
        ##   %r14
        ##   %r13
        ##   %r12
        ##   %r11
        ##   %r10
        ##   %r9
        ##   %r8
        ##   %rcx
        ##   %rdx
        ##   %rsi
        ##   %rdi
        ##   %rbx
        ##   %rbp: previous %rbp <= %rbp: current %rbp
        ##   %rflags
        ## %rip: saved RIP
        ## previous stack frame
        movq %rbp, TCB_SEGMENT_REG:(SHIM_TCB_OFFSET + TCB_REGS)

        /* Translating x86_64 kernel calling convention to user-space
         * calling convention */
        movq %r10, %rcx
        andq $~0xF, %rsp  # Required by System V AMD64 ABI.
        call *%rbx

.Lret_nosignal:
        CHECK_SIGNAL_PENDING_BIT
__syscallas_signal_allowed_1_begin:
        jc .Lsignal_pending

.Lret_signal:
        CLEAR_SAVED_AREA_IN_SHIM_TLS

ret:
        movq %rbp, %rsp
        addq $2 * 8, %rsp   # skip orig_rax and rsp
        popq %r15
        popq %r14
        popq %r13
        popq %r12
        popq %r11
        popq %r10
        popq %r9
        popq %r8
        popq %rcx
        popq %rdx
        popq %rsi
        popq %rdi
        popq %rbx
        popq %rbp
        .cfi_def_cfa %rsp, 2 * 8  # +8 for ret_addr, +8 for saved_rflags
        popfq
        .cfi_def_cfa_offset 8     # +8 for ret_addr
        retq

isundef:
#ifdef DEBUG
        mov %rax, %rdi
        andq $~0xF, %rsp  # Required by System V AMD64 ABI.
        call *debug_unsupp@GOTPCREL(%rip)
#endif
        movq $-38, %rax  # ENOSYS
        jmp ret
__syscallas_signal_allowed_1_end:

.Lsignal_pending:
        /*
         * allocate signal stack frame
         *
         * struct shim_regs: 16B align + 8
         *                   sizeof(struct shim_regs) = 0x90
         * struct sigframe
         *   restorer: 8 bytes
         *   ucontext_t: 16 bytes align
         *   siginfo_t
         * [ optionally padding to align fpstate ]
         * struct _libc_fpstate: 64 bytes align: fpu_xstate_size
         * extended area
         * FP_XSTATE_MAGIC2
         */
#define SIGFRAME_SIZE_SUB       (SIGFRAME_SIZE + FP_XSTATE_MAGIC2_SIZE + 64)
        movq %rsp, %rdi
        subq $SIGFRAME_SIZE_SUB, %rdi
        movq fpu_xstate_size@GOTPCREL(%rip), %rbx
        subq (%rbx), %rdi
        andq $(~15), %rdi
        subq $8, %rdi

        movq %rdi, %rsp
        movq %rax, %rsi
        pushq %rsi # save %rax in case that signal is not delivered
        pushq %rbp
        movq %rsp, %rbp
        andq $~15, %rsp
        call *deliver_signal_on_sysret@GOTPCREL(%rip)
        movq %rbp, %rsp
        popq %rbp
        popq %rsi
        cmp $0, %rax
        movq %rsi, %rax # %rsi conatins returning %rax saved above
        je .Lret_nosignal
        ## deliver_signal_on_sysret changes shim_tcb->context->regs
        ## to allocate signal frame. adjust it.
        ## .Lret_signal expects %rbp has struct shim_regs.
        ## mov from %rsp is faster than from memory.
        ## %rsp == TCB_SEGMENT_REG:(SHIM_TCB_OFFSET + TCB_REGS)
        ## movq TCB_SEGMENT_REG:(SHIM_TCB_OFFSET + TCB_REGS), %rbp
        movq %rsp, %rbp
        jmp .Lret_signal

        .cfi_endproc
        .size syscalldb, .-syscalldb

        // void __sigreturn(mcontext_t * uc_mcontext)
        .global __sigreturn
        .type __sigreturn, @function
__sigreturn:
        CHECK_SIGNAL_PENDING_BIT
        jnc .Lno_more_signal
        retq

__syscallas_signal_allowed_2_begin:
.Lno_more_signal:
        CLEAR_SAVED_AREA_IN_SHIM_TLS

        movq %rdi, %rsp

        // pop up gregs_t
        popq %r8
        popq %r9
        popq %r10
        popq %r11
        popq %r12
        popq %r13
        popq %r14
        popq %r15
        popq %rdi
        popq %rsi
        popq %rbp
        popq %rbx
        popq %rdx

        movq PAL_CONTEXT_RSP - PAL_CONTEXT_RAX(%rsp), %rcx  // saved %rsp
        movq PAL_CONTEXT_RIP - PAL_CONTEXT_RAX(%rsp), %rax  // saved %rip
        movq %rax, -RED_ZONE_SIZE-8(%rcx) // 8 bytes below redzone

        popq %rax
        popq %rcx
        // skip rsp, rip
        addq $(2 * 8), %rsp

        /* avoid to clobber red zone */
        subq $(RED_ZONE_SIZE + 8), PAL_CONTEXT_RSP - PAL_CONTEXT_EFL(%rsp)
        popfq
        movq PAL_CONTEXT_RSP - PAL_CONTEXT_CSGSFS(%rsp), %rsp
        retq $RED_ZONE_SIZE
__syscallas_signal_allowed_2_end:

        /*
         * syscall_wrapper: emulate syscall instruction
         *   prohibited in e.g. Linux-SGX PAL which raises a SIGILL exception
         * See illegal_upcall() @ shim_signal.c and
         *     fixup_child_context() @ shim_clone.c
         *
         * input:
         * %rcx: Instruction address to continue app execution after trapped
         *       syscall instruction
         * %r11: rflags on entering syscall
         */
__syscallas_signal_allowed_3_begin:
syscall_wrapper:
        .cfi_startproc
        .cfi_def_cfa %rsp, 0
        # %rcx is used as input for returning %rip
        .cfi_register %rip, %rcx
#ifdef SHIM_SYSCALL_STACK
        ## %rcx, %r11 are preserved by syscalldb
        movq %rsp, %r11
        .cfi_def_cfa_register %r11
        .cfi_register %rsp, %r11
        movq TCB_SEGMENT_REG:(SHIM_TCB_OFFSET + TCB_SYSCALL_STACK), %rsp
#else
        # %r11 is used as input to keep %rflags
        .cfi_register %rflags, %r11
        subq $RED_ZONE_SIZE, %rsp
        .cfi_adjust_cfa_offset RED_ZONE_SIZE
#endif
        callq *syscalldb@GOTPCREL(%rip)
syscall_wrapper_after_syscalldb:
#ifdef SHIM_SYSCALL_STACK
        movq %r11, %rsp
#else
        addq $RED_ZONE_SIZE, %rsp
        .cfi_adjust_cfa_offset -RED_ZONE_SIZE
        # restore %rflags for syscall abi compatibility.
        # This must be done after "addq $RED_ZONE_SIZE, %rsp" above
        # which destroys %rflags
        xchg %r11, (%rsp)
        .cfi_offset %rflags, 0
        popfq
        .cfi_adjust_cfa_offset -8
        .cfi_same_value %rflags
        pushq %r11
        .cfi_adjust_cfa_offset 8
#endif
        jmp *%rcx       /* syscalldb preserves %rcx */

        .cfi_endproc
        .size syscall_wrapper, .-syscall_wrapper
__syscallas_signal_allowed_3_end:
