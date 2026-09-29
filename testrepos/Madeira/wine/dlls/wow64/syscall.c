/*
 * WoW64 syscall wrapping
 *
 * Copyright 2021 Alexandre Julliard
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301, USA
 */

#include <stdarg.h>
#include <setjmp.h>

#include "ntstatus.h"
#include "windef.h"
#include "winbase.h"
#include "winnt.h"
#include "winternl.h"
#include "rtlsupportapi.h"
#include "wine/unixlib.h"
#include "wine/asm.h"
#include "wow64_private.h"
#include "wine/debug.h"

WINE_DEFAULT_DEBUG_CHANNEL(wow);

USHORT native_machine = 0;
USHORT current_machine = 0;
ULONG_PTR args_alignment = 0;
ULONG_PTR highest_user_address = 0x7ffeffff;
ULONG_PTR default_zero_bits = 0x7fffffff;

typedef NTSTATUS (WINAPI *syscall_thunk)( UINT *args );

static const syscall_thunk syscall_thunks[] =
{
#define SYSCALL_ENTRY(id,name,args) wow64_ ## name,
    ALL_SYSCALLS32
#undef SYSCALL_ENTRY
};

static BYTE syscall_args[ARRAY_SIZE(syscall_thunks)] =
{
#define SYSCALL_ENTRY(id,name,args) args,
    ALL_SYSCALLS32
#undef SYSCALL_ENTRY
};

static SYSTEM_SERVICE_TABLE syscall_tables[4] =
{
    { (ULONG_PTR *)syscall_thunks, NULL, ARRAY_SIZE(syscall_thunks), syscall_args }
};

/* header for Wow64AllocTemp blocks; probably not the right layout */
struct mem_header
{
    struct mem_header *next;
    void              *__pad;
    BYTE               data[1];
};

/* stack frame for user callbacks */
struct user_callback_frame
{
    struct user_callback_frame *prev_frame;
    struct mem_header          *temp_list;
    void                      **ret_ptr;
    ULONG                      *ret_len;
    NTSTATUS                    status;
    jmp_buf                     jmpbuf;
};

/* stack frame for user APCs */
struct user_apc_frame
{
    struct user_apc_frame *prev_frame;
    CONTEXT               *context;
    void                  *wow_context;
};

SYSTEM_DLL_INIT_BLOCK *pLdrSystemDllInitBlock = NULL;

/* host address of guest 0 for THIS process.  0 means the
 * classic WoW64 identity (guest address == host address), which is what every
 * platform except the iOS port uses — with 0 the guest_ptr32/host_ptr32
 * helpers are exactly the ULongToPtr/PtrToUlong they replaced. */
ULONG_PTR wow_guest_base = 0;

/* Same, for another process.  Cross-process VM calls must use the TARGET's
 * window (target-window rule, wow64_private.h), never ours.  Cached per handle value because the
 * query is a syscall and these calls come in bursts; a handle is closed and
 * reused only after the process object is gone, and a pseudo-process's window
 * dies with it, so a stale entry can only appear after a handle is recycled —
 * revalidated by comparing the process's unique id below. */
ULONG_PTR wow_guest_base_for_process( HANDLE process )
{
    static struct { HANDLE volatile handle; ULONG_PTR pid; ULONG_PTR base; } cache[8];
    static LONG cache_pos;
    PROCESS_BASIC_INFORMATION pbi;
    ULONG_PTR base = 0, pid;
    unsigned int i;

    /* on a platform that keeps the classic WoW64 identity
     * there are no windows at all, so answer without any syscall — this runs
     * on every cross-process VM call. */
    if (!wow_guest_base) return 0;
    if (process == GetCurrentProcess() || !process) return wow_guest_base;

    /* Cache lookup FIRST: the ProcessBasicInformation query below is itself a
     * syscall, so doing it before the lookup made the cache pointless. */
    for (i = 0; i < ARRAY_SIZE(cache); i++)
    {
        HANDLE h = ReadPointerAcquire( &cache[i].handle );   /* pairs with the release below */

        if (h == process) return cache[i].base;
    }

    /* Not cached.  Resolve the unique id so a recycled handle value cannot
     * alias a dead process's entry, then query B. */
    if (NtQueryInformationProcess( process, ProcessBasicInformation, &pbi, sizeof(pbi), NULL ))
        return 0;
    pid = pbi.UniqueProcessId;
    for (i = 0; i < ARRAY_SIZE(cache); i++)
        if (cache[i].handle == process && cache[i].pid == pid) return cache[i].base;
    if (NtQueryInformationProcess( process, ProcessWineIosWowGuestBase, &base, sizeof(base), NULL ))
        base = 0;

    /* Ordered publish: base and pid are visible before the handle that makes
     * the entry findable, so a concurrent reader can never match a handle and
     * then read a half-written base. */
    i = (unsigned int)InterlockedIncrement( &cache_pos ) % ARRAY_SIZE(cache);
    WritePointerRelease( &cache[i].handle, NULL );   /* retire the old entry first */
    cache[i].base = base;
    cache[i].pid = pid;
    WritePointerRelease( &cache[i].handle, process );
    return base;
}

static WOW64INFO *wow64info;
static WORD ss32_sel;

/* cpu backend dll functions */
/* the function prototypes most likely differ from Windows */
static void *   (WINAPI *pBTCpuGetBopCode)(void);
static NTSTATUS (WINAPI *pBTCpuGetContext)(HANDLE,HANDLE,void *,void *);
static BOOLEAN  (WINAPI *pBTCpuIsProcessorFeaturePresent)(UINT);
static void     (WINAPI *pBTCpuProcessInit)(void);
static NTSTATUS (WINAPI *pBTCpuSetContext)(HANDLE,HANDLE,void *,void *);
static void     (WINAPI *pBTCpuThreadInit)(void);
static void     (WINAPI *pBTCpuSimulate)(void) __attribute__((used));
static void *   (WINAPI *p__wine_get_unix_opcode)(void);
static void *   (WINAPI *pKiRaiseUserExceptionDispatcher)(void);
void     (WINAPI *pBTCpuFlushInstructionCache2)( const void *, SIZE_T ) = NULL;
void     (WINAPI *pBTCpuFlushInstructionCacheHeavy)( const void *, SIZE_T ) = NULL;
NTSTATUS (WINAPI *pBTCpuNotifyMapViewOfSection)( void *, void *, void *, SIZE_T, ULONG, ULONG ) = NULL;
void     (WINAPI *pBTCpuNotifyMemoryAlloc)( void *, SIZE_T, ULONG, ULONG, BOOL, NTSTATUS ) = NULL;
void     (WINAPI *pBTCpuNotifyMemoryDirty)( void *, SIZE_T ) = NULL;
void     (WINAPI *pBTCpuNotifyMemoryFree)( void *, SIZE_T, ULONG, BOOL, NTSTATUS ) = NULL;
void     (WINAPI *pBTCpuNotifyMemoryProtect)( void *, SIZE_T, ULONG, BOOL, NTSTATUS ) = NULL;
void     (WINAPI *pBTCpuNotifyProcessExecuteFlagsChange)( ULONG ) = NULL;
void     (WINAPI *pBTCpuNotifyReadFile)( HANDLE, void *, SIZE_T, BOOL, NTSTATUS ) = NULL;
void     (WINAPI *pBTCpuNotifyUnmapViewOfSection)( void *, BOOL, NTSTATUS ) = NULL;
NTSTATUS (WINAPI *pBTCpuResetToConsistentState)( EXCEPTION_POINTERS * ) = NULL;
void     (WINAPI *pBTCpuUpdateProcessorInformation)( SYSTEM_CPU_INFORMATION * ) = NULL;
void     (WINAPI *pBTCpuProcessTerm)( HANDLE, BOOL, NTSTATUS ) = NULL;
void     (WINAPI *pBTCpuThreadTerm)( HANDLE, LONG ) = NULL;

BOOL WINAPI DllMain( HINSTANCE inst, DWORD reason, void *reserved )
{
    if (reason == DLL_PROCESS_ATTACH) LdrDisableThreadCalloutsForDll( inst );
    return TRUE;
}

void __cdecl DECLSPEC_NORETURN __wine_spec_unimplemented_stub( const char *module, const char *function )
{
    EXCEPTION_RECORD record;

    record.ExceptionCode    = EXCEPTION_WINE_STUB;
    record.ExceptionFlags   = EXCEPTION_NONCONTINUABLE;
    record.ExceptionRecord  = NULL;
    record.ExceptionAddress = __wine_spec_unimplemented_stub;
    record.NumberParameters = 2;
    record.ExceptionInformation[0] = (ULONG_PTR)module;
    record.ExceptionInformation[1] = (ULONG_PTR)function;
    for (;;) RtlRaiseException( &record );
}

static void DECLSPEC_NORETURN stub_syscall( const char *name )
{
    __wine_spec_unimplemented_stub( "ntdll", name );
}

#define SYSCALL_STUB(name) NTSTATUS WINAPI wow64_ ## name( UINT *args ) { stub_syscall( #name ); }
ALL_SYSCALL_STUBS

/* most ExceptionInformation[] entries are
 * scalars (access type, length, thread id, NTSTATUS, ordinal, __fastfail code)
 * and must NEVER be offset — but a handful are ADDRESSES by contract, and
 * those cross the window boundary like any other pointer.  Fill `is_ptr[]`
 * with the ones that do.
 *
 * `info` must be the entries in the namespace being converted FROM.  The one
 * value-dependent test (EXCEPTION_WINE_STUB's function-name-or-ordinal) is
 * stable in both namespaces: an ordinal is <= 0xffff on both sides, and any
 * real pointer is > 0xffff as a guest address and >= 4 GB as a host one, so
 * the record round-trips exactly.
 */
static void get_exception_info_ptrs( DWORD code, ULONG count, const ULONG_PTR *info,
                                     BOOL is_ptr[EXCEPTION_MAXIMUM_PARAMETERS] )
{
    unsigned int i;

    for (i = 0; i < EXCEPTION_MAXIMUM_PARAMETERS; i++) is_ptr[i] = FALSE;
    if (count > EXCEPTION_MAXIMUM_PARAMETERS) count = EXCEPTION_MAXIMUM_PARAMETERS;

    switch (code)
    {
    case EXCEPTION_ACCESS_VIOLATION:
    case EXCEPTION_IN_PAGE_ERROR:
        /* [0] access type, [1] FAULTING ADDRESS, [2] (in-page) NTSTATUS */
        if (count >= 2) is_ptr[1] = TRUE;
        break;

    case EXCEPTION_WINE_NAME_THREAD:
        /* [0] 0x1000 magic, [1] const char *name, [2] thread id.  Raised by
         * 32-bit code (RaiseException from a debugger-style SetThreadName) and
         * consumed by the 64-bit ntdll's dispatch_exception, which prints the
         * name and passes it to set_native_thread_name — one SEGV per raise
         * until the pointer converts. */
        if (count >= 2 && info[0] == 0x1000) is_ptr[1] = TRUE;
        break;

    case EXCEPTION_WINE_STUB:
        /* [0] const char *module, [1] const char *function OR an ordinal —
         * dispatch_exception discriminates with the same `>> 16` test. */
        if (count >= 1) is_ptr[0] = TRUE;
        if (count >= 2 && (info[1] >> 16)) is_ptr[1] = TRUE;
        break;

    case DBG_PRINTEXCEPTION_C:
    case DBG_PRINTEXCEPTION_WIDE_C:
        /* [0] length in characters, [1] the string (char * / WCHAR *) */
        if (count >= 2) is_ptr[1] = TRUE;
        break;
    }
}


static EXCEPTION_RECORD *exception_record_32to64( const EXCEPTION_RECORD32 *rec32 )
{
    BOOL is_ptr[EXCEPTION_MAXIMUM_PARAMETERS];
    EXCEPTION_RECORD *rec;
    unsigned int i;

    rec = Wow64AllocateTemp( sizeof(*rec) );
    rec->ExceptionCode = rec32->ExceptionCode;
    rec->ExceptionFlags = rec32->ExceptionFlags;
    rec->ExceptionRecord = rec32->ExceptionRecord ? exception_record_32to64( guest_ptr32(rec32->ExceptionRecord) ) : NULL;
    rec->ExceptionAddress = guest_ptr32( rec32->ExceptionAddress );
    rec->NumberParameters = rec32->NumberParameters;
    for (i = 0; i < EXCEPTION_MAXIMUM_PARAMETERS; i++)
        rec->ExceptionInformation[i] = rec32->ExceptionInformation[i];

    /* The record built here is the one NtRaiseException and the 64-bit ntdll's
     * dispatch_exception see, so its addresses must be HOST addresses.  The
     * caller keeps rec32 and hands THAT to the 32-bit KiUserExceptionDispatcher
     * (see raise_exception), so the guest's own filters still read guest
     * values — the two records are never the same storage. */
    get_exception_info_ptrs( rec->ExceptionCode, rec->NumberParameters,
                             rec->ExceptionInformation, is_ptr );
    for (i = 0; i < EXCEPTION_MAXIMUM_PARAMETERS; i++)
        if (is_ptr[i])
            rec->ExceptionInformation[i] = (ULONG_PTR)guest_ptr32( rec32->ExceptionInformation[i] );
    return rec;
}


static void exception_record_64to32( EXCEPTION_RECORD32 *rec32, const EXCEPTION_RECORD *rec )
{
    BOOL is_ptr[EXCEPTION_MAXIMUM_PARAMETERS];
    unsigned int i;

    rec32->ExceptionCode    = rec->ExceptionCode;
    rec32->ExceptionFlags   = rec->ExceptionFlags;
    rec32->ExceptionRecord  = host_ptr32( rec->ExceptionRecord );
    rec32->ExceptionAddress = host_ptr32( rec->ExceptionAddress );
    rec32->NumberParameters = rec->NumberParameters;
    for (i = 0; i < rec->NumberParameters && i < EXCEPTION_MAXIMUM_PARAMETERS; i++)
        rec32->ExceptionInformation[i] = rec->ExceptionInformation[i];

    /* Same catalogue the other way round — see exception_record_32to64. */
    get_exception_info_ptrs( rec->ExceptionCode, rec->NumberParameters,
                             rec->ExceptionInformation, is_ptr );
    for (i = 0; i < EXCEPTION_MAXIMUM_PARAMETERS; i++)
        if (is_ptr[i])
            rec32->ExceptionInformation[i] = host_ptr32( (void *)rec->ExceptionInformation[i] );
}


static NTSTATUS get_context_return_value( void *wow_context )
{
    switch (current_machine)
    {
    case IMAGE_FILE_MACHINE_I386:
        return ((I386_CONTEXT *)wow_context)->Eax;
    case IMAGE_FILE_MACHINE_ARMNT:
        return ((ARM_CONTEXT *)wow_context)->R0;
    }
    return 0;
}


/**********************************************************************
 *           call_user_exception_dispatcher
 */
static void __attribute__((used)) call_user_exception_dispatcher( EXCEPTION_RECORD32 *rec, void *ctx32_ptr,
                                                                  void *ctx64_ptr )
{
    switch (current_machine)
    {
    case IMAGE_FILE_MACHINE_I386:
        {
            /* stack layout when calling 32-bit KiUserExceptionDispatcher */
            struct exc_stack_layout32
            {
                ULONG              rec_ptr;       /* 000 */
                ULONG              context_ptr;   /* 004 */
                EXCEPTION_RECORD32 rec;           /* 008 */
                I386_CONTEXT       context;       /* 058 */
            } *stack;
            I386_CONTEXT ctx = { CONTEXT_I386_ALL };
            CONTEXT_EX *context_ex, *src_ex = NULL;
            ULONG esp, flags, context_length;

            C_ASSERT( offsetof(struct exc_stack_layout32, context) == 0x58 );

            pBTCpuGetContext( GetCurrentThread(), GetCurrentProcess(), NULL, &ctx );

            if (ctx32_ptr)
            {
                I386_CONTEXT *ctx32 = ctx32_ptr;

                if ((ctx32->ContextFlags & CONTEXT_I386_XSTATE) == CONTEXT_I386_XSTATE)
                    src_ex = (CONTEXT_EX *)(ctx32 + 1);
            }
            else if (native_machine == IMAGE_FILE_MACHINE_AMD64)
            {
                AMD64_CONTEXT *ctx64 = ctx64_ptr;

                if ((ctx64->ContextFlags & CONTEXT_AMD64_FLOATING_POINT) == CONTEXT_AMD64_FLOATING_POINT)
                    memcpy( ctx.ExtendedRegisters, &ctx64->FltSave, sizeof(ctx.ExtendedRegisters) );
                if ((ctx64->ContextFlags & CONTEXT_AMD64_XSTATE) == CONTEXT_AMD64_XSTATE)
                    src_ex = (CONTEXT_EX *)(ctx64 + 1);
            }

            flags = ctx.ContextFlags;
            if (src_ex) flags |= CONTEXT_I386_XSTATE;

            RtlGetExtendedContextLength( flags, &context_length );

            esp = LOWORD(ctx.SegSs) != ss32_sel ? NtCurrentTeb32()->SystemReserved1[0] : ctx.Esp;
            stack = (struct exc_stack_layout32 *)guest_ptr32( (esp - offsetof(struct exc_stack_layout32, context) - context_length) & ~3 );
            stack->rec_ptr     = host_ptr32( &stack->rec );
            stack->context_ptr = host_ptr32( &stack->context );
            stack->rec         = *rec;
            stack->context     = ctx;
            RtlInitializeExtendedContext( &stack->context, flags, &context_ex );
            if (src_ex) RtlCopyExtendedContext( context_ex, WOW64_CONTEXT_XSTATE, src_ex );

            /* adjust Eip for breakpoints in software emulation (hardware exceptions already adjust Rip) */
            if (rec->ExceptionCode == EXCEPTION_BREAKPOINT && (wow64info->CpuFlags & WOW64_CPUFLAGS_SOFTWARE))
                stack->context.Eip--;

            ctx.Esp = host_ptr32( stack );
            ctx.Eip = pLdrSystemDllInitBlock->pKiUserExceptionDispatcher;
            ctx.EFlags &= ~(0x100|0x400|0x40000);
            ctx.ContextFlags = CONTEXT_I386_CONTROL;
            pBTCpuSetContext( GetCurrentThread(), GetCurrentProcess(), NULL, &ctx );

            TRACE( "exception %08lx dispatcher %08lx stack %08lx eip %08lx\n",
                   rec->ExceptionCode, ctx.Eip, ctx.Esp, stack->context.Eip );
        }
        break;

    case IMAGE_FILE_MACHINE_ARMNT:
        {
            struct stack_layout
            {
                ARM_CONTEXT        context;
                EXCEPTION_RECORD32 rec;
            } *stack;
            ARM_CONTEXT ctx = { CONTEXT_ARM_ALL };

            pBTCpuGetContext( GetCurrentThread(), GetCurrentProcess(), NULL, &ctx );
            stack = (struct stack_layout *)guest_ptr32( ctx.Sp & ~3 ) - 1;
            stack->rec = *rec;
            stack->context = ctx;

            ctx.R0 = host_ptr32( &stack->rec );     /* first arg for KiUserExceptionDispatcher */
            ctx.R1 = host_ptr32( &stack->context ); /* second arg for KiUserExceptionDispatcher */
            ctx.Sp = host_ptr32( stack );
            ctx.Pc = pLdrSystemDllInitBlock->pKiUserExceptionDispatcher;
            if (ctx.Pc & 1) ctx.Cpsr |= 0x20;
            else ctx.Cpsr &= ~0x20;
            ctx.ContextFlags = CONTEXT_ARM_FULL;
            pBTCpuSetContext( GetCurrentThread(), GetCurrentProcess(), NULL, &ctx );

            TRACE( "exception %08lx dispatcher %08lx stack %08lx pc %08lx\n",
                   rec->ExceptionCode, ctx.Pc, ctx.Sp, stack->context.Sp );
        }
        break;
    }
}


/**********************************************************************
 *           call_raise_user_exception_dispatcher
 */
static void __attribute__((used)) call_raise_user_exception_dispatcher( ULONG code )
{
    NtCurrentTeb32()->ExceptionCode = code;

    switch (current_machine)
    {
    case IMAGE_FILE_MACHINE_I386:
        {
            I386_CONTEXT ctx;

            ctx.ContextFlags = CONTEXT_I386_CONTROL;
            pBTCpuGetContext( GetCurrentThread(), GetCurrentProcess(), NULL, &ctx );
            ctx.Esp -= sizeof(ULONG);
            *(ULONG *)guest_ptr32( ctx.Esp ) = ctx.Eip;
            ctx.Eip = host_ptr32( pKiRaiseUserExceptionDispatcher );
            pBTCpuSetContext( GetCurrentThread(), GetCurrentProcess(), NULL, &ctx );
        }
        break;

    case IMAGE_FILE_MACHINE_ARMNT:
        {
            ARM_CONTEXT ctx;

            ctx.ContextFlags = CONTEXT_ARM_CONTROL;
            pBTCpuGetContext( GetCurrentThread(), GetCurrentProcess(), NULL, &ctx );
            ctx.Pc = host_ptr32( pKiRaiseUserExceptionDispatcher );
            pBTCpuSetContext( GetCurrentThread(), GetCurrentProcess(), NULL, &ctx );
        }
        break;
    }
}


/* based on RtlRaiseException: call NtRaiseException with context setup to return to caller */
void WINAPI raise_exception( EXCEPTION_RECORD32 *rec32, void *ctx32,
                             BOOL first_chance, EXCEPTION_RECORD *rec );
#ifdef __aarch64__
__ASM_GLOBAL_FUNC( raise_exception,
                   "sub sp, sp, #0x390\n\t"    /* sizeof(context) */
                   ".seh_stackalloc 0x390\n\t"
                   "stp x29, x30, [sp, #-48]!\n\t"
                   ".seh_save_fplr_x 48\n\t"
                   ".seh_endprologue\n\t"
                   ".seh_handler raise_exception_handler, @except\n\t"
                   "stp x0, x1, [sp, #16]\n\t"
                   "stp x2, x3, [sp, #32]\n\t"
                   "add x0, sp, #48\n\t"
                   "bl RtlCaptureContext\n\t"
                   "add x1, sp, #48\n\t"       /* context */
                   "adr x2, 1f\n\t"            /* return address */
                   "str x2, [x1, #0x108]\n\t"  /* context->Pc */
                   "ldp x2, x0, [sp, #32]\n\t" /* first_chance, rec */
                   "bl NtRaiseException\n"
                   "raise_exception_ret:\n\t"
                   "ldp x0, x1, [sp, #16]\n\t" /* rec32, ctx32 */
                   "add x2, sp, #48\n\t"       /* context */
                   "bl call_user_exception_dispatcher\n"
                   "1:\tnop\n\t"
                   "ldp x29, x30, [sp], #48\n\t"
                   "add sp, sp, #0x390\n\t"
                   "ret" )
__ASM_GLOBAL_FUNC( raise_exception_handler,
                   "stp x29, x30, [sp, #-16]!\n\t"
                   ".seh_save_fplr_x 16\n\t"
                   ".seh_endprologue\n\t"
                   "ldr w4, [x0, #4]\n\t"      /* record->ExceptionFlags */
                   "tst w4, #6\n\t"            /* EXCEPTION_UNWINDING | EXCEPTION_EXIT_UNWIND */
                   "b.ne 1f\n\t"
                   "mov x2, x0\n\t"            /* rec */
                   "mov x0, x1\n\t"            /* frame */
                   "adr x1, raise_exception_ret\n\t"
                   "bl RtlUnwind\n"
                   "1:\tmov w0, #1\n\t"        /* ExceptionContinueSearch */
                   "ldp x29, x30, [sp], #16\n\t"
                   "ret" )
#else
__ASM_GLOBAL_FUNC( raise_exception,
                   "sub $0x4d8,%rsp\n\t"       /* sizeof(context) + alignment */
                   ".seh_stackalloc 0x4d8\n\t"
                   ".seh_endprologue\n\t"
                   ".seh_handler raise_exception_handler, @except\n\t"
                   "movq %rcx,0x4e0(%rsp)\n\t"
                   "movq %rdx,0x4e8(%rsp)\n\t"
                   "movq %r8,0x4f0(%rsp)\n\t"
                   "movq %r9,0x4f8(%rsp)\n\t"
                   "movq %rsp,%rcx\n\t"
                   "call RtlCaptureContext\n\t"
                   "movq %rsp,%rdx\n\t"        /* context */
                   "leaq 1f(%rip),%rax\n\t"    /* return address */
                   "movq %rax,0xf8(%rdx)\n\t"  /* context->Rip */
                   "movq 0x4f8(%rsp),%rcx\n\t" /* rec */
                   "movq 0x4f0(%rsp),%r8\n\t"  /* first_chance */
                   "call NtRaiseException\n"
                   "raise_exception_ret:\n\t"
                   "mov 0x4e0(%rsp),%rcx\n\t"  /* rec32 */
                   "mov 0x4e8(%rsp),%rdx\n\t"  /* ctx32 */
                   "movq %rsp,%r8\n\t"         /* context */
                   "call call_user_exception_dispatcher\n"
                   "1:\tnop\n\t"
                   "add $0x4d8,%rsp\n\t"
                   "ret" )
__ASM_GLOBAL_FUNC( raise_exception_handler,
                   "sub $0x28,%rsp\n\t"
                   ".seh_stackalloc 0x28\n\t"
                   ".seh_endprologue\n\t"
                   "movq %rcx,%r8\n\t"         /* rec */
                   "movq %rdx,%rcx\n\t"        /* frame */
                   "leaq raise_exception_ret(%rip),%rdx\n\t"
                   "call RtlUnwind\n\t"
                   "int3" )
#endif


/**********************************************************************
 *           wow64_NtAddAtom
 */
NTSTATUS WINAPI wow64_NtAddAtom( UINT *args )
{
    const WCHAR *name = get_ptr( &args );
    ULONG len = get_ulong( &args );
    RTL_ATOM *atom = get_ptr( &args );

    return NtAddAtom( name, len, atom );
}


/**********************************************************************
 *           wow64_NtAllocateLocallyUniqueId
 */
NTSTATUS WINAPI wow64_NtAllocateLocallyUniqueId( UINT *args )
{
    LUID *luid = get_ptr( &args );

    return NtAllocateLocallyUniqueId( luid );
}

/**********************************************************************
 *           wow64_NtAllocateReserveObject
 */
NTSTATUS WINAPI wow64_NtAllocateReserveObject( UINT *args )
{
    ULONG *handle_ptr = get_ptr( &args );
    OBJECT_ATTRIBUTES32 *attr32 = get_ptr( &args );
    MEMORY_RESERVE_OBJECT_TYPE type = get_ulong( &args );
    NTSTATUS status;

    struct object_attr64 attr;
    HANDLE handle = 0;

    status = NtAllocateReserveObject( &handle, objattr_32to64( &attr, attr32 ), type );
    put_handle( handle_ptr, handle );
    return status;
}

/**********************************************************************
 *           wow64_NtAllocateUuids
 */
NTSTATUS WINAPI wow64_NtAllocateUuids( UINT *args )
{
    ULARGE_INTEGER *time = get_ptr( &args );
    ULONG *delta = get_ptr( &args );
    ULONG *sequence = get_ptr( &args );
    UCHAR *seed = get_ptr( &args );

    return NtAllocateUuids( time, delta, sequence, seed );
}


/***********************************************************************
 *           wow64_NtCallbackReturn
 */
NTSTATUS WINAPI wow64_NtCallbackReturn( UINT *args )
{
    void *ret_ptr = get_ptr( &args );
    ULONG ret_len = get_ulong( &args );
    NTSTATUS status = get_ulong( &args );

    struct user_callback_frame *frame = NtCurrentTeb()->TlsSlots[WOW64_TLS_USERCALLBACKDATA];

    if (!frame) return STATUS_NO_CALLBACK_ACTIVE;

    *frame->ret_ptr = ret_ptr;
    *frame->ret_len = ret_len;
    frame->status = status;
    longjmp( frame->jmpbuf, 1 );
    return STATUS_SUCCESS;
}


/**********************************************************************
 *           wow64_NtClose
 */
NTSTATUS WINAPI wow64_NtClose( UINT *args )
{
    HANDLE handle = get_handle( &args );

    return NtClose( handle );
}


/**********************************************************************
 *           wow64_NtContinueEx
 */
NTSTATUS WINAPI wow64_NtContinueEx( UINT *args )
{
    void *context = get_ptr( &args );
    /* Not every value in a pointer slot is a pointer: this argument is NOT always a pointer.
     * NtContinue( context, alertable ) and NtContinueEx( context, cont_args )
     * share one entry here; the callee side (ntdll NtContinueEx) tells them
     * apart by value, "<= 0xff is the BOOLEAN alertable".  The discriminator
     * must therefore run on the RAW 32-bit value, BEFORE any window
     * conversion: with B != 0, get_ptr() turned NtContinue( ctx, TRUE ) into
     * B+1, which is > 0xff, so the pointer branch below dereferenced
     * (B+1)->ContinueFlags and faulted.  The i386 caller is ntdll's
     * signal_start_thread(), which ends LdrInitializeThunk with a literal
     * NtContinue( context, 1 ) (dlls/ntdll/signal_i386.c:528-530). */
    ULONG cont_args32 = get_ulong( &args );
    KCONTINUE_ARGUMENT *cont_args = (cont_args32 > 0xff) ? guest_ptr32( cont_args32 )
                                                         : ULongToPtr( cont_args32 );

    NTSTATUS status = get_context_return_value( context );
    struct user_apc_frame *frame = NtCurrentTeb()->TlsSlots[WOW64_TLS_APCLIST];
    BOOL alertable;

    pBTCpuSetContext( GetCurrentThread(), GetCurrentProcess(), NULL, context );

    while (frame && frame->wow_context != context) frame = frame->prev_frame;
    NtCurrentTeb()->TlsSlots[WOW64_TLS_APCLIST] = frame ? frame->prev_frame : NULL;
    if (frame) NtContinueEx( frame->context, cont_args );

    if (cont_args32 > 0xff)
        alertable = cont_args->ContinueFlags & KCONTINUE_FLAG_TEST_ALERT;
    else
        alertable = !!cont_args32;

    if (alertable) NtTestAlert();
    return status;
}


/**********************************************************************
 *           wow64_NtContinue
 */
NTSTATUS WINAPI wow64_NtContinue( UINT *args )
{
    return wow64_NtContinueEx( args );
}


/**********************************************************************
 *           wow64_NtDeleteAtom
 */
NTSTATUS WINAPI wow64_NtDeleteAtom( UINT *args )
{
    RTL_ATOM atom = get_ulong( &args );

    return NtDeleteAtom( atom );
}


/**********************************************************************
 *           wow64_NtFindAtom
 */
NTSTATUS WINAPI wow64_NtFindAtom( UINT *args )
{
    const WCHAR *name = get_ptr( &args );
    ULONG len = get_ulong( &args );
    RTL_ATOM *atom = get_ptr( &args );

    return NtFindAtom( name, len, atom );
}


/**********************************************************************
 *           wow64_NtGetContextThread
 */
NTSTATUS WINAPI wow64_NtGetContextThread( UINT *args )
{
    HANDLE handle = get_handle( &args );
    WOW64_CONTEXT *context = get_ptr( &args );

    return RtlWow64GetThreadContext( handle, context );
}


/**********************************************************************
 *           wow64_NtGetCurrentProcessorNumber
 */
NTSTATUS WINAPI wow64_NtGetCurrentProcessorNumber( UINT *args )
{
    return NtGetCurrentProcessorNumber();
}


/**********************************************************************
 *           wow64_NtQueryDefaultLocale
 */
NTSTATUS WINAPI wow64_NtQueryDefaultLocale( UINT *args )
{
    BOOLEAN user = get_ulong( &args );
    LCID *lcid = get_ptr( &args );

    return NtQueryDefaultLocale( user, lcid );
}


/**********************************************************************
 *           wow64_NtQueryDefaultUILanguage
 */
NTSTATUS WINAPI wow64_NtQueryDefaultUILanguage( UINT *args )
{
    LANGID *lang = get_ptr( &args );

    return NtQueryDefaultUILanguage( lang );
}


/**********************************************************************
 *           wow64_NtQueryInformationAtom
 */
NTSTATUS WINAPI wow64_NtQueryInformationAtom( UINT *args )
{
    RTL_ATOM atom = get_ulong( &args );
    ATOM_INFORMATION_CLASS class = get_ulong( &args );
    void *info = get_ptr( &args );
    ULONG len = get_ulong( &args );
    ULONG *retlen = get_ptr( &args );

    if (class != AtomBasicInformation) FIXME( "class %u not supported\n", class );
    return NtQueryInformationAtom( atom, class, info, len, retlen );
}


/**********************************************************************
 *           wow64_NtQueryInstallUILanguage
 */
NTSTATUS WINAPI wow64_NtQueryInstallUILanguage( UINT *args )
{
    LANGID *lang = get_ptr( &args );

    return NtQueryInstallUILanguage( lang );
}


/**********************************************************************
 *           wow64_NtRaiseException
 */
NTSTATUS WINAPI wow64_NtRaiseException( UINT *args )
{
    EXCEPTION_RECORD32 *rec32 = get_ptr( &args );
    void *context32 = get_ptr( &args );
    BOOL first_chance = get_ulong( &args );

    pBTCpuSetContext( GetCurrentThread(), GetCurrentProcess(), NULL, context32 );
    raise_exception( rec32, context32, first_chance, exception_record_32to64( rec32 ));
    return STATUS_SUCCESS;
}


/**********************************************************************
 *           wow64_NtSetContextThread
 */
NTSTATUS WINAPI wow64_NtSetContextThread( UINT *args )
{
    HANDLE handle = get_handle( &args );
    WOW64_CONTEXT *context = get_ptr( &args );

    return RtlWow64SetThreadContext( handle, context );
}


/**********************************************************************
 *           wow64_NtSetDebugFilterState
 */
NTSTATUS WINAPI wow64_NtSetDebugFilterState( UINT *args )
{
    ULONG component_id = get_ulong( &args );
    ULONG level = get_ulong( &args );
    BOOLEAN state = get_ulong( &args );

    return NtSetDebugFilterState( component_id, level, state );
}


/**********************************************************************
 *           wow64_NtSetDefaultLocale
 */
NTSTATUS WINAPI wow64_NtSetDefaultLocale( UINT *args )
{
    BOOLEAN user = get_ulong( &args );
    LCID lcid = get_ulong( &args );

    return NtSetDefaultLocale( user, lcid );
}


/**********************************************************************
 *           wow64_NtSetDefaultUILanguage
 */
NTSTATUS WINAPI wow64_NtSetDefaultUILanguage( UINT *args )
{
    LANGID lang = get_ulong( &args );

    return NtSetDefaultUILanguage( lang );
}


/**********************************************************************
 *           wow64_NtWow64IsProcessorFeaturePresent
 */
NTSTATUS WINAPI wow64_NtWow64IsProcessorFeaturePresent( UINT *args )
{
    UINT feature = get_ulong( &args );

    return pBTCpuIsProcessorFeaturePresent && pBTCpuIsProcessorFeaturePresent( feature );
}


/* CPU-DLL contract.
 *
 * BTCpuGetBopCode() and __wine_get_unix_opcode() return GUEST addresses, not
 * host pointers: the backend allocates the BOP / unix-call code page inside
 * this process's window (NtAllocateVirtualMemory with a guest zero_bits
 * ceiling puts it there) and publishes `host - B` itself.  The values are
 * therefore already in the namespace the 32-bit side reads, and must be
 * stored verbatim — running them through host_ptr32() subtracts B a second
 * time, which only happened to survive because B is 4 GB-aligned and the
 * result wrapped back to the same low 32 bits.
 *
 * So validate the RAW value instead: a guest address is nonzero and below
 * 4 GB.  Anything else is a broken backend; one greppable line. */
static void check_guest_addr( const char *what, const void *p )
{
    static int reported;

    if (!wow_guest_base) return;   /* classic identity: host == guest */
    if (p && (ULONG_PTR)p < 0x100000000ull) return;
    if (reported++) return;
    ERR( "[wow-window] CONTRACT VIOLATION: %s is %p, which is not a guest address "
         "(must be nonzero and < 4GB). The CPU backend must allocate this page "
         "inside the guest window [%p,%p) and return host - B.\n",
         what, p, (void *)wow_guest_base,
         (void *)(wow_guest_base + 0x100000000ull) );
}


/**********************************************************************
 *           init_image_mapping
 */
void init_image_mapping( HMODULE module )
{
    ULONG *ptr = RtlFindExportedRoutineByName( module, "Wow64Transition" );

    /* Wow64Transition is read by 32-bit code, and
     * BTCpuGetBopCode() already returns a GUEST address (see the CPU-DLL
     * contract above) — store it verbatim, do NOT apply host_ptr32(). */
    check_guest_addr( "Wow64Transition (BTCpuGetBopCode)", pBTCpuGetBopCode() );
    if (ptr) *ptr = (ULONG)(ULONG_PTR)pBTCpuGetBopCode();
}


/**********************************************************************
 *           load_64bit_module
 */
/* wow64.dll links against ntdll only, so wine_dbgstr_wn (which calls
 * IsBadStringPtrW) is unavailable here; dll names are ASCII. */
static const char *dllname_a( const WCHAR *name )
{
    static char buffer[4][64];
    static LONG pos;
    char *ret = buffer[InterlockedIncrement( &pos ) & 3];
    unsigned int i;

    for (i = 0; i < sizeof(buffer[0]) - 1 && name[i]; i++)
        ret[i] = (name[i] < 0x80) ? (char)name[i] : '?';
    ret[i] = 0;
    return ret;
}

static HMODULE try_load_64bit_module( const WCHAR *name )
{
    HMODULE module;
    UNICODE_STRING str;
    WCHAR path[MAX_PATH];
    const WCHAR *dir = get_machine_wow64_dir( IMAGE_FILE_MACHINE_TARGET_HOST );

    swprintf( path, MAX_PATH, L"%s\\%s", dir, name );
    RtlInitUnicodeString( &str, path );
    if (LdrLoadDll( dir, 0, &str, &module )) return NULL;
    return module;
}

static HMODULE load_64bit_module( const WCHAR *name )
{
    HMODULE module = try_load_64bit_module( name );

    if (!module)
    {
        ERR( "failed to load dll %s\n", dllname_a(name) );
        NtTerminateProcess( GetCurrentProcess(), STATUS_DLL_NOT_FOUND );
    }
    return module;
}


/**********************************************************************
 *           load_cpu_dll
 *
 * The CPU backend named by the registry may not exist on this host (a prefix
 * captured on another architecture records a different one — e.g. an x86_64
 * capture leaves "wow64cpu.dll" behind for \Wow64\x86).  Falling back to the
 * platform default rather than terminating the process is a generic
 * robustness fix, not a per-configuration workaround.
 */
static HMODULE load_cpu_dll( const WCHAR *name, const WCHAR *fallback )
{
    HMODULE module = try_load_64bit_module( name );

    if (!module && fallback && wcsicmp( name, fallback ))
    {
        ERR( "CPU backend %s not available, falling back to the platform default %s\n",
             dllname_a(name), dllname_a(fallback) );
        module = try_load_64bit_module( fallback );
    }
    if (!module)
    {
        ERR( "failed to load CPU backend %s\n", dllname_a(name) );
        NtTerminateProcess( GetCurrentProcess(), STATUS_DLL_NOT_FOUND );
    }
    return module;
}


/**********************************************************************
 *           get_cpu_dll_name
 */
static const WCHAR *get_cpu_dll_name( const WCHAR **platform_default )
{
    static ULONG buffer[32];
    KEY_VALUE_PARTIAL_INFORMATION *info = (KEY_VALUE_PARTIAL_INFORMATION *)buffer;
    OBJECT_ATTRIBUTES attr;
    UNICODE_STRING nameW;
    const WCHAR *ret;
    HANDLE key;
    ULONG size;

    switch (current_machine)
    {
    case IMAGE_FILE_MACHINE_I386:
        RtlInitUnicodeString( &nameW, L"\\Registry\\Machine\\Software\\Microsoft\\Wow64\\x86" );
        ret = (native_machine == IMAGE_FILE_MACHINE_ARM64 ? L"xtajit.dll" : L"wow64cpu.dll");
        break;
    case IMAGE_FILE_MACHINE_ARMNT:
        RtlInitUnicodeString( &nameW, L"\\Registry\\Machine\\Software\\Microsoft\\Wow64\\arm" );
        ret = L"wowarmhw.dll";
        break;
    default:
        ERR( "unsupported machine %04x\n", current_machine );
        RtlExitUserProcess( 1 );
    }
    *platform_default = ret;
    InitializeObjectAttributes( &attr, &nameW, OBJ_CASE_INSENSITIVE, 0, NULL );
    if (NtOpenKey( &key, KEY_READ | KEY_WOW64_64KEY, &attr )) return ret;
    RtlInitUnicodeString( &nameW, L"" );
    size = sizeof(buffer) - sizeof(WCHAR);
    if (!NtQueryValueKey( key, &nameW, KeyValuePartialInformation, buffer, size, &size ) && info->Type == REG_SZ)
    {
        ((WCHAR *)info->Data)[info->DataLength / sizeof(WCHAR)] = 0;
        ret = (WCHAR *)info->Data;
    }
    NtClose( key );
    return ret;
}


/* MADEIRA: Wine-private MEMORY_INFORMATION_CLASS that
 * maps a PE image VA to the executable JIT-pool copy of the same code.  Kept
 * local to the two files that implement and use it (this one and
 * build/ntdll-unix/virtual_ios.c); 1000..1004 are the MemoryWine* block. */
#define MemoryWineIosJitPoolAddress ((MEMORY_INFORMATION_CLASS)1005)

/**********************************************************************
 *           jit_pool_code_ptr
 *
 * On the iOS port PE code cannot execute at its mapped address: every image's
 * code is copied into the dual-mapped JIT pool and a Mach exception handler
 * redirects a PC that lands on the PE address to the pool copy.  That redirect
 * is a full kernel round-trip, so a function pointer that is CALLED repeatedly
 * must hold the pool address, not the PE address.
 *
 * Pointers that live inside a pool-copied image are repaired in bulk by the
 * ntdll-side [iat-sync] sweep, and stragglers by [stale-heal] after 256 faults.
 * Neither can repair a table that is read from the PE view of a read-only
 * section — see the comment on MemoryWineIosJitPoolAddress in virtual_ios.c.
 * This asks for the pool address explicitly instead.
 *
 * Returns `addr` unchanged on every platform whose ntdll does not know the
 * class (i.e. everywhere but the iOS port) and for any address that is not
 * inside a pool-copied image, so it is a no-op there and idempotent here.
 */
static void *jit_pool_code_ptr( void *addr )
{
    ULONG_PTR pool = 0;

    if (!addr) return NULL;
    if (NtQueryVirtualMemory( GetCurrentProcess(), addr, MemoryWineIosJitPoolAddress,
                              &pool, sizeof(pool), NULL ))
        return addr;
    return pool ? (void *)pool : addr;
}


/**********************************************************************
 *           init_syscall_table_pool_copy
 *
 * Replace one syscall table's ServiceTable with a private writable array whose
 * entries are the JIT-pool addresses of the thunks.
 *
 * syscall_tables[1] is a struct copy of wow64win.dll's exported sdwhwin32,
 * whose ServiceTable points into wow64win.dll's READ-ONLY .rdata at its PE
 * address and holds PE addresses.  Every NtUser or NtGdi call from 32-bit code
 * therefore branched to a PE address and paid one Mach exception; the pool
 * copy of that .rdata is already translated, so the [stale-heal] exact-value
 * scan found nothing to rewrite and the storm never ended (~500k redirects in
 * one minute of a windowed 32-bit program).
 *
 * Doing it here, once, is deterministic: no fault threshold, no scan, and no
 * dependence on which view of the table a later sweep happens to see.
 */
static void init_syscall_table_pool_copy( unsigned int idx, const char *name )
{
    SYSTEM_SERVICE_TABLE *table = &syscall_tables[idx];
    ULONG_PTR *copy;
    ULONG_PTR i;
    unsigned int translated = 0;

    if (!table->ServiceTable || !table->ServiceLimit) return;
    if (!(copy = RtlAllocateHeap( GetProcessHeap(), 0, table->ServiceLimit * sizeof(*copy) )))
    {
        ERR( "no memory for %s service table copy\n", name );
        return;
    }
    for (i = 0; i < table->ServiceLimit; i++)
    {
        void *pe = (void *)table->ServiceTable[i];
        void *pool = jit_pool_code_ptr( pe );

        copy[i] = (ULONG_PTR)pool;
        if (pool != pe) translated++;
    }
    table->ServiceTable = copy;
    if (translated)
        ERR( "[wow-syscall] translated %u ServiceTable entries for %s\n", translated, name );
}


/**********************************************************************
 *           create_cross_process_work_list
 */
static NTSTATUS create_cross_process_work_list( WOW64INFO *wow64info )
{
    SIZE_T map_size = 0x4000;
    LARGE_INTEGER size;
    NTSTATUS status;
    HANDLE section;
    CROSS_PROCESS_WORK_LIST *list = NULL;
    CROSS_PROCESS_WORK_ENTRY *end;
    UINT i;

    size.QuadPart = map_size;
    status = NtCreateSection( &section, SECTION_ALL_ACCESS, NULL, &size, PAGE_READWRITE, SEC_COMMIT, 0 );
    if (status) return status;
    status = NtMapViewOfSection( section, GetCurrentProcess(), (void **)&list, default_zero_bits, 0, NULL,
                                 &map_size, ViewShare, MEM_TOP_DOWN, PAGE_READWRITE );
    if (status)
    {
        NtClose( section );
        return status;
    }

    end = (CROSS_PROCESS_WORK_ENTRY *)((char *)list + map_size);
    for (i = 0; list->entries + i + 1 <= end; i++)
        RtlWow64PushCrossProcessWorkOntoFreeList( &list->free_list, &list->entries[i] );

    wow64info->SectionHandle = (ULONG_PTR)section;
    wow64info->CrossProcessWorkList = (ULONG_PTR)list;
    return STATUS_SUCCESS;
}


/**********************************************************************
 *           process_init
 */
static DWORD WINAPI process_init( RTL_RUN_ONCE *once, void *param, void **context )
{
    PEB32 *peb32;
    HMODULE module;
    UNICODE_STRING str = RTL_CONSTANT_STRING( L"ntdll.dll" );
    SYSTEM_BASIC_INFORMATION info;
    ULONG *p__wine_syscall_dispatcher, *p__wine_unix_call_dispatcher;
    const SYSTEM_SERVICE_TABLE *psdwhwin32;

    RtlWow64GetProcessMachines( GetCurrentProcess(), &current_machine, &native_machine );
    if (!current_machine) current_machine = native_machine;
    /* read B ONCE, before anything converts a pointer.
     * Stays 0 (classic identity) on every build whose ntdll does not know the
     * class, which is every platform but the iOS port. */
    if (NtQueryInformationProcess( GetCurrentProcess(), ProcessWineIosWowGuestBase,
                                   &wow_guest_base, sizeof(wow_guest_base), NULL ))
        wow_guest_base = 0;
    if (wow_guest_base)
        TRACE( "guest window base %p\n", (void *)wow_guest_base );
    args_alignment = (current_machine == IMAGE_FILE_MACHINE_I386) ? sizeof(ULONG) : sizeof(ULONG64);
    NtQuerySystemInformation( SystemEmulationBasicInformation, &info, sizeof(info), NULL );
    highest_user_address = (ULONG_PTR)info.HighestUserAddress;
    default_zero_bits = (ULONG_PTR)info.HighestUserAddress | 0x7fffffff;
    NtQueryInformationProcess( GetCurrentProcess(), ProcessWow64Information, &peb32, sizeof(peb32), NULL );
    wow64info = (WOW64INFO *)(peb32 + 1);
    wow64info->NativeSystemPageSize = 0x1000;
    wow64info->NativeMachineType    = native_machine;
    wow64info->EmulatedMachineType  = current_machine;
    NtCurrentTeb()->TlsSlots[WOW64_TLS_WOW64INFO] = wow64info;

#define GET_PTR(name) p ## name = RtlFindExportedRoutineByName( module, #name )

    LdrGetDllHandle( NULL, 0, &str, &module );
    GET_PTR( LdrSystemDllInitBlock );

    {
        const WCHAR *cpu_default = NULL;
        const WCHAR *cpu_name = get_cpu_dll_name( &cpu_default );

        module = load_cpu_dll( cpu_name, cpu_default );
    }
    GET_PTR( BTCpuGetBopCode );
    GET_PTR( BTCpuGetContext );
    GET_PTR( BTCpuIsProcessorFeaturePresent );
    GET_PTR( BTCpuProcessInit );
    GET_PTR( BTCpuThreadInit );
    GET_PTR( BTCpuResetToConsistentState );
    GET_PTR( BTCpuSetContext );
    GET_PTR( BTCpuSimulate );
    GET_PTR( BTCpuFlushInstructionCache2 );
    GET_PTR( BTCpuFlushInstructionCacheHeavy );
    GET_PTR( BTCpuNotifyMapViewOfSection );
    GET_PTR( BTCpuNotifyMemoryAlloc );
    GET_PTR( BTCpuNotifyMemoryDirty );
    GET_PTR( BTCpuNotifyMemoryFree );
    GET_PTR( BTCpuNotifyMemoryProtect );
    /* MADEIRA: the CPU backend's DEP hook.  Upstream never resolved or called it, so
     * NtSetInformationProcess(ProcessExecuteFlags) - which the 32-bit loader issues for every
     * image without IMAGE_DLLCHARACTERISTICS_NX_COMPAT (dlls/ntdll/loader.c:1930), and which
     * SetProcessDEPPolicy issues at runtime - reached the host ntdll and stopped there.  The
     * emulator therefore never learned that DEP is off and kept refusing to translate code the
     * program had written into its own PAGE_READWRITE memory.  Optional like every other hook:
     * a backend that does not export it is simply not told. */
    GET_PTR( BTCpuNotifyProcessExecuteFlagsChange );
    GET_PTR( BTCpuNotifyReadFile );
    GET_PTR( BTCpuNotifyUnmapViewOfSection );
    GET_PTR( BTCpuUpdateProcessorInformation );
    GET_PTR( BTCpuProcessTerm );
    GET_PTR( BTCpuThreadTerm );
    GET_PTR( __wine_get_unix_opcode );

    module = load_64bit_module( L"wow64win.dll" );
    GET_PTR( sdwhwin32 );
    syscall_tables[1] = *psdwhwin32;

    /* MADEIRA: every pointer resolved above is a PE image
     * address, and on this port PE code only executes out of the JIT pool.  A
     * PE address stored in a pointer that is BRANCHED THROUGH costs one Mach
     * exception per call, so translate the ones this dll calls, once, here.
     *
     * Only CALL targets are converted: pLdrSystemDllInitBlock and psdwhwin32
     * are data, and the three 32-bit-ntdll exports resolved after this point
     * live in the guest window, not in a pool-copied 64-bit image.
     * jit_pool_code_ptr() is a no-op wherever the class is unknown. */
#define XLATE_PTR(name) p ## name = jit_pool_code_ptr( p ## name )
    XLATE_PTR( BTCpuGetBopCode );
    XLATE_PTR( BTCpuGetContext );
    XLATE_PTR( BTCpuIsProcessorFeaturePresent );
    XLATE_PTR( BTCpuProcessInit );
    XLATE_PTR( BTCpuThreadInit );
    XLATE_PTR( BTCpuResetToConsistentState );
    XLATE_PTR( BTCpuSetContext );
    XLATE_PTR( BTCpuSimulate );
    XLATE_PTR( BTCpuFlushInstructionCache2 );
    XLATE_PTR( BTCpuFlushInstructionCacheHeavy );
    XLATE_PTR( BTCpuNotifyMapViewOfSection );
    XLATE_PTR( BTCpuNotifyMemoryAlloc );
    XLATE_PTR( BTCpuNotifyMemoryDirty );
    XLATE_PTR( BTCpuNotifyMemoryFree );
    XLATE_PTR( BTCpuNotifyMemoryProtect );
    XLATE_PTR( BTCpuNotifyProcessExecuteFlagsChange );
    XLATE_PTR( BTCpuNotifyReadFile );
    XLATE_PTR( BTCpuNotifyUnmapViewOfSection );
    XLATE_PTR( BTCpuUpdateProcessorInformation );
    XLATE_PTR( BTCpuProcessTerm );
    XLATE_PTR( BTCpuThreadTerm );
    XLATE_PTR( __wine_get_unix_opcode );
#undef XLATE_PTR
    init_syscall_table_pool_copy( 0, "ntdll.dll" );
    init_syscall_table_pool_copy( 1, "wow64win.dll" );

    pBTCpuProcessInit();

    /* ntdll_handle is published as the 32-bit ntdll's
     * GUEST base (like every other LdrSystemDllInitBlock entry, which end up
     * in 32-bit CONTEXT registers); turn it back into a host module here. */
    module = (HMODULE)guest_ptr32( (ULONG)pLdrSystemDllInitBlock->ntdll_handle );
    init_image_mapping( module );
    GET_PTR( KiRaiseUserExceptionDispatcher );
    GET_PTR( __wine_syscall_dispatcher );
    GET_PTR( __wine_unix_call_dispatcher );

    /* both are read by 32-bit code, and both backend entry points already
     * return GUEST addresses — store verbatim (see the CPU-DLL contract at
     * check_guest_addr) */
    check_guest_addr( "__wine_syscall_dispatcher (BTCpuGetBopCode)", pBTCpuGetBopCode() );
    check_guest_addr( "__wine_unix_call_dispatcher (__wine_get_unix_opcode)",
                      p__wine_get_unix_opcode() );
    *p__wine_syscall_dispatcher = (ULONG)(ULONG_PTR)pBTCpuGetBopCode();
    *p__wine_unix_call_dispatcher = (ULONG)(ULONG_PTR)p__wine_get_unix_opcode();

    if (wow64info->CpuFlags & WOW64_CPUFLAGS_SOFTWARE) create_cross_process_work_list( wow64info );

    if (current_machine == IMAGE_FILE_MACHINE_I386)
    {
        I386_CONTEXT ctx = { CONTEXT_I386_CONTROL };
        RtlWow64GetThreadContext( GetCurrentThread(), &ctx );
        ss32_sel = ctx.SegSs;
    }

    init_file_redirects();
    return TRUE;

#undef GET_PTR
}


/**********************************************************************
 *           thread_init
 */
/* MADEIRA: MADEIRA_WOW_INIT_CTX_RETRY=0 disables the checked initial context (thread_init). */
static BOOL wow_init_ctx_retry_enabled(void)
{
    static LONG enabled = -1;

    if (enabled < 0)
    {
        UNICODE_STRING name = RTL_CONSTANT_STRING( L"MADEIRA_WOW_INIT_CTX_RETRY" ), value;
        WCHAR buffer[8];

        value.Buffer = buffer;
        value.Length = 0;
        value.MaximumLength = sizeof(buffer);
        enabled = !(!RtlQueryEnvironmentVariable_U( NULL, &name, &value ) && value.Length && buffer[0] == '0');
    }
    return enabled;
}

static void thread_init(void)
{
    /* BTCpuGetBopCode() returns a GUEST address — store verbatim */
    check_guest_addr( "WOW32Reserved (BTCpuGetBopCode)", pBTCpuGetBopCode() );
    NtCurrentTeb32()->WOW32Reserved = (ULONG)(ULONG_PTR)pBTCpuGetBopCode();
    NtCurrentTeb()->TlsSlots[WOW64_TLS_WOW64INFO] = wow64info;
    if (pBTCpuThreadInit) pBTCpuThreadInit();

    /* update initial context to jump to 32-bit LdrInitializeThunk (cf. 32-bit call_init_thunk) */
    switch (current_machine)
    {
    case IMAGE_FILE_MACHINE_I386:
        {
            I386_CONTEXT *ctx_ptr, ctx = { CONTEXT_I386_FULL };
            ULONG *stack;
            NTSTATUS status;

            status = pBTCpuGetContext( GetCurrentThread(), GetCurrentProcess(), NULL, &ctx );
            /* MADEIRA: the result was never checked. On device a new
             * 32-bit process's first thread got Esp == 0 back (the context left as
             * initialised: the call failed, or the CPU area was not filled yet),
             * and the copy below went to 0 - sizeof(I386_CONTEXT) (wild write in
             * memcpy, c0000005 in the launcher right after its install). Ask
             * again a few times, yielding between tries, and log what came back;
             * if it never succeeds, end the process with that status instead of
             * writing through a null stack. MADEIRA_WOW_INIT_CTX_RETRY=0 keeps the
             * old unchecked path. */
            if ((status || !ctx.Esp) && wow_init_ctx_retry_enabled())
            {
                unsigned int tries;

                ERR( "[wow-init-ctx] initial context: status %#lx Esp %#lx; retrying\n",
                     (long)status, (long)ctx.Esp );
                for (tries = 0; tries < 64 && (status || !ctx.Esp); tries++)
                {
                    NtYieldExecution();
                    memset( &ctx, 0, sizeof(ctx) );
                    ctx.ContextFlags = CONTEXT_I386_FULL;
                    status = pBTCpuGetContext( GetCurrentThread(), GetCurrentProcess(), NULL, &ctx );
                }
                ERR( "[wow-init-ctx] after %u retries: status %#lx Esp %#lx\n", tries, (long)status, (long)ctx.Esp );
                if (status || !ctx.Esp)
                    NtTerminateProcess( GetCurrentProcess(), status ? status : STATUS_INVALID_PARAMETER );
            }
            ctx_ptr = (I386_CONTEXT *)guest_ptr32( ctx.Esp ) - 1;
            *ctx_ptr = ctx;
            stack = (ULONG *)ctx_ptr;
            *(--stack) = 0;
            *(--stack) = 0;
            *(--stack) = 0;
            *(--stack) = host_ptr32( ctx_ptr );
            *(--stack) = 0xdeadbabe;
            ctx.Esp = host_ptr32( stack );
            ctx.Eip = pLdrSystemDllInitBlock->pLdrInitializeThunk;
            pBTCpuSetContext( GetCurrentThread(), GetCurrentProcess(), NULL, &ctx );
        }
        break;

    case IMAGE_FILE_MACHINE_ARMNT:
        {
            ARM_CONTEXT *ctx_ptr, ctx = { CONTEXT_ARM_FULL };

            pBTCpuGetContext( GetCurrentThread(), GetCurrentProcess(), NULL, &ctx );
            ctx_ptr = (ARM_CONTEXT *)guest_ptr32( ctx.Sp & ~15 ) - 1;
            *ctx_ptr = ctx;

            ctx.R0 = host_ptr32( ctx_ptr );
            ctx.Sp = host_ptr32( ctx_ptr );
            ctx.Pc = pLdrSystemDllInitBlock->pLdrInitializeThunk;
            pBTCpuSetContext( GetCurrentThread(), GetCurrentProcess(), NULL, &ctx );
        }
        break;

    default:
        ERR( "not supported machine %x\n", current_machine );
        NtTerminateProcess( GetCurrentProcess(), STATUS_INVALID_IMAGE_FORMAT );
    }
}


/**********************************************************************
 *           free_temp_data
 */
static void free_temp_data(void)
{
    struct mem_header *next, *mem;

    for (mem = NtCurrentTeb()->TlsSlots[WOW64_TLS_TEMPLIST]; mem; mem = next)
    {
        next = mem->next;
        RtlFreeHeap( GetProcessHeap(), 0, mem );
    }
    NtCurrentTeb()->TlsSlots[WOW64_TLS_TEMPLIST] = NULL;
}


/**********************************************************************
 *           wow64_syscall
 */
#ifdef __aarch64__
NTSTATUS wow64_syscall( UINT *args, ULONG_PTR thunk );
__ASM_GLOBAL_FUNC( wow64_syscall,
                   "stp x29, x30, [sp, #-16]!\n\t"
                   ".seh_save_fplr_x 16\n\t"
                   ".seh_endprologue\n\t"
                   ".seh_handler wow64_syscall_handler, @except\n"
                   "blr x1\n\t"
                   "b 1f\n"
                   "wow64_syscall_ret:\n\t"
                   "eor w1, w0, #0xc0000000\n\t"
                   "cmp w1, #8\n\t"                /* STATUS_INVALID_HANDLE */
                   "b.ne 1f\n\t"
                   "bl call_raise_user_exception_dispatcher\n"
                   "1:\tldp x29, x30, [sp], #16\n\t"
                   "ret" )
__ASM_GLOBAL_FUNC( wow64_syscall_handler,
                   "stp x29, x30, [sp, #-16]!\n\t"
                   ".seh_save_fplr_x 16\n\t"
                   ".seh_endprologue\n\t"
                   "ldr w4, [x0, #4]\n\t"          /* record->ExceptionFlags */
                   "tst w4, #6\n\t"                /* EXCEPTION_UNWINDING | EXCEPTION_EXIT_UNWIND */
                   "b.ne 1f\n\t"
                   "mov x2, x0\n\t"                /* record */
                   "mov x0, x1\n\t"                /* frame */
                   "adr x1, wow64_syscall_ret\n\t" /* target */
                   "ldr w3, [x2]\n\t"              /* retval = record->ExceptionCode */
                   "bl RtlUnwind\n\t"
                   "1:\tmov w0, #1\n\t"            /* ExceptionContinueSearch */
                   "ldp x29, x30, [sp], #16\n\t"
                   "ret" )
#else
NTSTATUS wow64_syscall( UINT *args, ULONG_PTR thunk );
__ASM_GLOBAL_FUNC( wow64_syscall,
                   "subq $0x28, %rsp\n\t"
                   ".seh_stackalloc 0x28\n\t"
                   ".seh_endprologue\n\t"
                   ".seh_handler wow64_syscall_handler, @except\n\t"
                   "call *%rdx\n\t"
                   "jmp 1f\n"
                   "wow64_syscall_ret:\n\t"
                   "cmpl $0xc0000008,%eax\n\t"     /* STATUS_INVALID_HANDLE */
                   "jne 1f\n\t"
                   "movl %eax,%ecx\n\t"
                   "call call_raise_user_exception_dispatcher\n"
                   "1:\taddq $0x28, %rsp\n\t"
                   "ret" )
__ASM_GLOBAL_FUNC( wow64_syscall_handler,
                   "subq $0x28,%rsp\n\t"
                   ".seh_stackalloc 0x28\n\t"
                   ".seh_endprologue\n\t"
                   "movl (%rcx),%r9d\n\t"          /* retval = rec->ExceptionCode */
                   "movq %rcx,%r8\n\t"             /* rec */
                   "movq %rdx,%rcx\n\t"            /* frame */
                   "leaq wow64_syscall_ret(%rip),%rdx\n\t"
                   "call RtlUnwind\n\t"
                   "int3" )
#endif


/**********************************************************************
 *           Wow64SystemServiceEx  (wow64.@)
 */
NTSTATUS WINAPI Wow64SystemServiceEx( UINT num, UINT *args )
{
    NTSTATUS status;
    UINT id = num & 0xfff;
    const SYSTEM_SERVICE_TABLE *table = &syscall_tables[(num >> 12) & 3];

    if (id >= table->ServiceLimit)
    {
        ERR( "unsupported syscall %04x\n", num );
        return STATUS_INVALID_SYSTEM_SERVICE;
    }
    status = wow64_syscall( args, table->ServiceTable[id] );
    free_temp_data();
    return status;
}


/**********************************************************************
 *           cpu_simulate
 */
#ifdef __aarch64__
extern void DECLSPEC_NORETURN cpu_simulate(void);
__ASM_GLOBAL_FUNC( cpu_simulate,
                   "stp x29, x30, [sp, #-16]!\n\t"
                   ".seh_save_fplr_x 16\n\t"
                   ".seh_endprologue\n\t"
                   ".seh_handler cpu_simulate_handler, @except\n"
                   ".Lcpu_simulate_loop:\n\t"
                   "adrp x16, pBTCpuSimulate\n\t"
                   "ldr x16, [x16, :lo12:pBTCpuSimulate]\n\t"
                   "blr x16\n\t"
                   "b .Lcpu_simulate_loop" )
__ASM_GLOBAL_FUNC( cpu_simulate_handler,
                   "stp x29, x30, [sp, #-48]!\n\t"
                   ".seh_save_fplr_x 48\n\t"
                   "stp x19, x20, [sp, #16]\n\t"
                   ".seh_save_regp x19, 16\n\t"
                   ".seh_endprologue\n\t"
                   "mov x19, x0\n\t"            /* record */
                   "mov x20, x1\n\t"            /* frame */
                   "ldr w4, [x0, #4]\n\t"       /* record->ExceptionFlags */
                   "tst w4, #6\n\t"             /* EXCEPTION_UNWINDING | EXCEPTION_EXIT_UNWIND */
                   "b.ne 1f\n\t"
                   "stp x0, x2, [sp, #32]\n\t"  /* record, context */
                   "add x0, sp, #32\n\t"
                   "bl Wow64PassExceptionToGuest\n\t"
                   "mov x0, x20\n\t"            /* frame */
                   "adr x1, .Lcpu_simulate_loop\n\t" /* target */
                   "mov x2, x19\n\t"            /* record */
                   "bl RtlUnwind\n\t"
                   "1:\tmov w0, #1\n\t"         /* ExceptionContinueSearch */
                   "ldp x19, x20, [sp, #16]\n\t"
                   "ldp x29, x30, [sp], #48\n\t"
                   "ret" )
#else
extern void DECLSPEC_NORETURN cpu_simulate(void);
__ASM_GLOBAL_FUNC( cpu_simulate,
                   "subq $0x28, %rsp\n\t"
                   ".seh_stackalloc 0x28\n\t"
                   ".seh_endprologue\n\t"
                   ".seh_handler cpu_simulate_handler, @except\n\t"
                   ".Lcpu_simulate_loop:\n\t"
                   "call *pBTCpuSimulate(%rip)\n\t"
                   "jmp .Lcpu_simulate_loop" )
__ASM_GLOBAL_FUNC( cpu_simulate_handler,
                   "subq $0x38, %rsp\n\t"
                   ".seh_stackalloc 0x38\n\t"
                   ".seh_endprologue\n\t"
                   "movq %rcx,%rsi\n\t"         /* record */
                   "movq %rcx,0x20(%rsp)\n\t"
                   "movq %rdx,%rdi\n\t"         /* frame */
                   "movq %r8,0x28(%rsp)\n\t"    /* context */
                   "leaq 0x20(%rsp),%rcx\n\t"
                   "call Wow64PassExceptionToGuest\n\t"
                   "movq %rdi,%rcx\n\t"         /* frame */
                   "leaq .Lcpu_simulate_loop(%rip), %rdx\n\t"  /* target */
                   "movq %rsi,%r8\n\t"          /* record */
                   "call RtlUnwind\n\t"
                   "int3" )
#endif


/**********************************************************************
 *           Wow64AllocateTemp  (wow64.@)
 *
 * FIXME: probably not 100% compatible.
 */
void * WINAPI Wow64AllocateTemp( SIZE_T size )
{
    struct mem_header *mem;

    if (!(mem = RtlAllocateHeap( GetProcessHeap(), 0, offsetof( struct mem_header, data[size] ))))
        return NULL;
    mem->next = NtCurrentTeb()->TlsSlots[WOW64_TLS_TEMPLIST];
    NtCurrentTeb()->TlsSlots[WOW64_TLS_TEMPLIST] = mem;
    return mem->data;
}


/**********************************************************************
 *           Wow64ApcRoutine  (wow64.@)
 */
void WINAPI Wow64ApcRoutine( ULONG_PTR arg1, ULONG_PTR arg2, ULONG_PTR arg3, CONTEXT *context )
{
    struct user_apc_frame frame;

    frame.prev_frame = NtCurrentTeb()->TlsSlots[WOW64_TLS_APCLIST];
    frame.context    = context;
    NtCurrentTeb()->TlsSlots[WOW64_TLS_APCLIST] = &frame;

    /* cf. 32-bit call_user_apc_dispatcher */
    switch (current_machine)
    {
    case IMAGE_FILE_MACHINE_I386:
        {
            /* stack layout when calling 32-bit KiUserApcDispatcher */
            struct apc_stack_layout32
            {
                ULONG             func;          /* 000 */
                UINT              arg1;          /* 004 */
                UINT              arg2;          /* 008 */
                UINT              arg3;          /* 00c */
                UINT              alertable;     /* 010 */
                I386_CONTEXT      context;       /* 014 */
                CONTEXT_EX32      xctx;          /* 2e0 */
                UINT              unk2[4];       /* 2f8 */
            } *stack;
            I386_CONTEXT ctx = { CONTEXT_I386_FULL };

            C_ASSERT( offsetof(struct apc_stack_layout32, context) == 0x14 );
            C_ASSERT( sizeof(struct apc_stack_layout32) == 0x308 );

            pBTCpuGetContext( GetCurrentThread(), GetCurrentProcess(), NULL, &ctx );

            stack = (struct apc_stack_layout32 *)guest_ptr32( ctx.Esp & ~3 ) - 1;
            stack->func      = arg1 >> 32;
            stack->arg1      = arg1;
            stack->arg2      = arg2;
            stack->arg3      = arg3;
            stack->alertable = TRUE;
            stack->context   = ctx;
            stack->xctx.Legacy.Offset = -(LONG)sizeof(stack->context);
            stack->xctx.Legacy.Length = sizeof(stack->context);
            stack->xctx.All.Offset    = -(LONG)sizeof(stack->context);
            stack->xctx.All.Length    = sizeof(stack->context) + sizeof(stack->xctx);
            stack->xctx.XState.Offset = 25;
            stack->xctx.XState.Length = 0;

            ctx.Esp = host_ptr32( stack );
            ctx.Eip = pLdrSystemDllInitBlock->pKiUserApcDispatcher;
            frame.wow_context = &stack->context;
            pBTCpuSetContext( GetCurrentThread(), GetCurrentProcess(), NULL, &ctx );
            cpu_simulate();
        }
        break;

    case IMAGE_FILE_MACHINE_ARMNT:
        {
            struct apc_stack_layout
            {
                ULONG       func;
                ULONG       align[3];
                ARM_CONTEXT context;
            } *stack;
            ARM_CONTEXT ctx = { CONTEXT_ARM_FULL };

            pBTCpuGetContext( GetCurrentThread(), GetCurrentProcess(), NULL, &ctx );
            stack = (struct apc_stack_layout *)guest_ptr32( ctx.Sp & ~15 ) - 1;
            stack->func = arg1 >> 32;
            stack->context = ctx;
            ctx.Sp = host_ptr32( stack );
            ctx.Pc = pLdrSystemDllInitBlock->pKiUserApcDispatcher;
            ctx.R0 = host_ptr32( &stack->context );
            ctx.R1 = arg1;
            ctx.R2 = arg2;
            ctx.R3 = arg3;
            frame.wow_context = &stack->context;
            pBTCpuSetContext( GetCurrentThread(), GetCurrentProcess(), NULL, &ctx );
            cpu_simulate();
        }
        break;
    }
}


/**********************************************************************
 *           Wow64KiUserCallbackDispatcher  (wow64.@)
 */
NTSTATUS WINAPI Wow64KiUserCallbackDispatcher( ULONG id, void *args, ULONG len,
                                               void **ret_ptr, ULONG *ret_len )
{
    WOW64_CPURESERVED *cpu = NtCurrentTeb()->TlsSlots[WOW64_TLS_CPURESERVED];
    TEB32 *teb32 = NtCurrentTeb32();
    ULONG teb_frame = teb32->Tib.ExceptionList;
    struct user_callback_frame frame;
    USHORT flags = cpu->Flags;

    frame.prev_frame = NtCurrentTeb()->TlsSlots[WOW64_TLS_USERCALLBACKDATA];
    frame.temp_list  = NtCurrentTeb()->TlsSlots[WOW64_TLS_TEMPLIST];
    frame.ret_ptr    = ret_ptr;
    frame.ret_len    = ret_len;

    NtCurrentTeb()->TlsSlots[WOW64_TLS_USERCALLBACKDATA] = &frame;
    NtCurrentTeb()->TlsSlots[WOW64_TLS_TEMPLIST] = NULL;

    /* cf. 32-bit KeUserModeCallback */
    switch (current_machine)
    {
    case IMAGE_FILE_MACHINE_I386:
        {
            /* stack layout when calling 32-bit KiUserCallbackDispatcher */
            struct callback_stack_layout32
            {
                ULONG             eip;           /* 000 */
                ULONG             id;            /* 004 */
                ULONG             args;          /* 008 */
                ULONG             len;           /* 00c */
                ULONG             unk[2];        /* 010 */
                ULONG             esp;           /* 018 */
                BYTE              args_data[0];  /* 01c */
            } *stack;
            I386_CONTEXT orig_ctx, ctx = { CONTEXT_I386_FULL };

            C_ASSERT( sizeof(struct callback_stack_layout32) == 0x1c );

            pBTCpuGetContext( GetCurrentThread(), GetCurrentProcess(), NULL, &ctx );
            orig_ctx = ctx;

            stack = guest_ptr32( (ctx.Esp - offsetof(struct callback_stack_layout32,args_data[len])) & ~15 );
            stack->eip  = ctx.Eip;
            stack->id   = id;
            stack->args = host_ptr32( stack->args_data );
            stack->len  = len;
            stack->esp  = ctx.Esp;
            memcpy( stack->args_data, args, len );

            ctx.Esp = host_ptr32( stack );
            ctx.Eip = pLdrSystemDllInitBlock->pKiUserCallbackDispatcher;
            pBTCpuSetContext( GetCurrentThread(), GetCurrentProcess(), NULL, &ctx );

            if (!setjmp( frame.jmpbuf ))
                cpu_simulate();
            else
                pBTCpuSetContext( GetCurrentThread(), GetCurrentProcess(), NULL, &orig_ctx );
        }
        break;

    case IMAGE_FILE_MACHINE_ARMNT:
        {
            ARM_CONTEXT orig_ctx, ctx = { CONTEXT_ARM_FULL };
            void *args_data;

            pBTCpuGetContext( GetCurrentThread(), GetCurrentProcess(), NULL, &ctx );
            orig_ctx = ctx;

            args_data = guest_ptr32( (ctx.Sp - len) & ~15 );
            memcpy( args_data, args, len );

            ctx.R0 = id;
            ctx.R1 = host_ptr32( args_data );
            ctx.R2 = len;
            ctx.Sp = host_ptr32( args_data );
            ctx.Pc = pLdrSystemDllInitBlock->pKiUserCallbackDispatcher;
            pBTCpuSetContext( GetCurrentThread(), GetCurrentProcess(), NULL, &ctx );

            if (!setjmp( frame.jmpbuf ))
                cpu_simulate();
            else
                pBTCpuSetContext( GetCurrentThread(), GetCurrentProcess(), NULL, &orig_ctx );
        }
        break;
    }

    teb32->Tib.ExceptionList = teb_frame;
    NtCurrentTeb()->TlsSlots[WOW64_TLS_USERCALLBACKDATA] = frame.prev_frame;
    NtCurrentTeb()->TlsSlots[WOW64_TLS_TEMPLIST] = frame.temp_list;
    cpu->Flags = flags;
    return frame.status;
}


/**********************************************************************
 *           Wow64LdrpInitialize  (wow64.@)
 */
void WINAPI Wow64LdrpInitialize( CONTEXT *context )
{
    static RTL_RUN_ONCE init_done;

    RtlRunOnceExecuteOnce( &init_done, process_init, NULL, NULL );
    thread_init();
    cpu_simulate();
}


/**********************************************************************
 *           Wow64PrepareForException  (wow64.@)
 */
#ifdef __x86_64__
__ASM_GLOBAL_FUNC( Wow64PrepareForException,
                   "sub $0x38,%rsp\n\t"
                   "mov %rcx,%r10\n\t"           /* rec */
                   "movw %cs,%ax\n\t"
                   "cmpw %ax,0x38(%rdx)\n\t"     /* context->SegCs */
                   "je 1f\n\t"                   /* already in 64-bit mode? */
                   /* copy arguments to 64-bit stack */
                   "mov %rsp,%rsi\n\t"
                   "movl $0x5c0,%ecx\n"          /* cf. KiUserExceptionDispatcher */
                   "movl 0x4d4(%rdx),%edi\n\t"   /* context_ex->All.Length */
                   "cmp %edi,%ecx\n\t"
                   "cmovl %edi,%ecx\n\t"         /* max( 0x5c0, context_ex->All.Length ) */
                   "add %rdx,%rcx\n\t"
                   "sub %rsi,%rcx\n\t"           /* stack size */
                   "sub %rcx,%r14\n\t"           /* reserve same size on 64-bit stack */
                   "and $~0x0f,%r14\n\t"
                   "mov %r14,%rdi\n\t"
                   "shr $3,%rcx\n\t"
                   "rep; movsq\n\t"
                   /* update arguments to point to the new stack */
                   "mov %r14,%rax\n\t"
                   "sub %rsp,%rax\n\t"
                   "add %rax,%r10\n\t"           /* rec */
                   "add %rax,%rdx\n\t"           /* context */
                   /* switch to 64-bit stack */
                   "mov %r14,%rsp\n"
                   /* build EXCEPTION_POINTERS structure and call BTCpuResetToConsistentState */
                   "1:\tlea 0x20(%rsp),%rcx\n\t" /* pointers */
                   "mov %r10,(%rcx)\n\t"         /* rec */
                   "mov %rdx,8(%rcx)\n\t"        /* context */
                   "mov " __ASM_NAME("pBTCpuResetToConsistentState") "(%rip),%rax\n\t"
                   "call *%rax\n\t"
                   "add $0x38,%rsp\n\t"
                   "ret" )
#else
void WINAPI Wow64PrepareForException( EXCEPTION_RECORD *rec, CONTEXT *context )
{
    EXCEPTION_POINTERS ptrs = { rec, context };

    /* iOS-Madeira: this is the ONE BTCpu entry point wow64 called without a
     * NULL check (every other optional one is guarded, cf. virtual.c:167).
     * pBTCpuResetToConsistentState is only bound at GET_PTR time in
     * process_init(), i.e. AFTER load_cpu_dll() has finished; the CPU backend
     * here is a full C++ module that drags in the native ucrtbase/kernel32/
     * kernelbase, so a native fault raised while those DllMains run reaches
     * KiUserExceptionDispatcher -> Wow64PrepareForException with the pointer
     * still NULL, and `blr x8` branched to 0 -- turning one survivable access
     * violation into an unrecoverable redelivery storm.  Skipping the
     * consistency fixup is correct in that window: there is no guest context
     * to reset, the fault is native. */
    if (pBTCpuResetToConsistentState) pBTCpuResetToConsistentState( &ptrs );
}
#endif


/**********************************************************************
 *           Wow64PassExceptionToGuest  (wow64.@)
 */
void WINAPI Wow64PassExceptionToGuest( EXCEPTION_POINTERS *ptrs )
{
    EXCEPTION_RECORD32 rec32;

    exception_record_64to32( &rec32, ptrs->ExceptionRecord );
    call_user_exception_dispatcher( &rec32, NULL, ptrs->ContextRecord );
}


/**********************************************************************
 *           Wow64ProcessPendingCrossProcessItems  (wow64.@)
 */
void WINAPI Wow64ProcessPendingCrossProcessItems(void)
{
    CROSS_PROCESS_WORK_LIST *list = (void *)wow64info->CrossProcessWorkList;
    CROSS_PROCESS_WORK_ENTRY *entry;
    BOOLEAN flush = FALSE;
    UINT next;

    if (!list) return;
    entry = RtlWow64PopAllCrossProcessWorkFromWorkList( &list->work_list, &flush );

    if (flush)
    {
        if (pBTCpuFlushInstructionCacheHeavy) pBTCpuFlushInstructionCacheHeavy( NULL, 0 );
        while (entry)
        {
            next = entry->next;
            RtlWow64PushCrossProcessWorkOntoFreeList( &list->free_list, entry );
            entry = next ? CROSS_PROCESS_LIST_ENTRY( &list->work_list, next ) : NULL;
        }
        return;
    }

    while (entry)
    {
        switch (entry->id)
        {
        case CrossProcessPreVirtualAlloc:
        case CrossProcessPostVirtualAlloc:
            if (!pBTCpuNotifyMemoryAlloc) break;
            pBTCpuNotifyMemoryAlloc( (void *)entry->addr, entry->size, entry->args[0], entry->args[1],
                                     entry->id == CrossProcessPostVirtualAlloc, entry->args[2] );
            break;
        case CrossProcessPreVirtualFree:
        case CrossProcessPostVirtualFree:
            if (!pBTCpuNotifyMemoryFree) break;
            pBTCpuNotifyMemoryFree( (void *)entry->addr, entry->size, entry->args[0],
                                     entry->id == CrossProcessPostVirtualFree, entry->args[1] );
            break;
        case CrossProcessPreVirtualProtect:
        case CrossProcessPostVirtualProtect:
            if (!pBTCpuNotifyMemoryProtect) break;
            pBTCpuNotifyMemoryProtect( (void *)entry->addr, entry->size, entry->args[0],
                                       entry->id == CrossProcessPostVirtualProtect, entry->args[1] );
            break;
        case CrossProcessFlushCache:
            if (!pBTCpuFlushInstructionCache2) break;
            pBTCpuFlushInstructionCache2( (void *)entry->addr, entry->size );
            break;
        case CrossProcessFlushCacheHeavy:
            if (!pBTCpuFlushInstructionCacheHeavy) break;
            pBTCpuFlushInstructionCacheHeavy( (void *)entry->addr, entry->size );
            break;
        case CrossProcessMemoryWrite:
            if (!pBTCpuNotifyMemoryDirty) break;
            pBTCpuNotifyMemoryDirty( (void *)entry->addr, entry->size );
            break;
        }
        next = entry->next;
        RtlWow64PushCrossProcessWorkOntoFreeList( &list->free_list, entry );
        entry = next ? CROSS_PROCESS_LIST_ENTRY( &list->work_list, next ) : NULL;
    }
}


/**********************************************************************
 *           Wow64RaiseException  (wow64.@)
 */
NTSTATUS WINAPI Wow64RaiseException( int code, EXCEPTION_RECORD *rec )
{
    EXCEPTION_RECORD32 rec32;
    BOOL first_chance = TRUE;
    union
    {
        I386_CONTEXT i386;
        ARM_CONTEXT arm;
    } ctx32 = { 0 };

    switch (current_machine)
    {
    case IMAGE_FILE_MACHINE_I386:
    {
        EXCEPTION_RECORD int_rec = { 0 };

        ctx32.i386.ContextFlags = CONTEXT_I386_ALL;
        pBTCpuGetContext( GetCurrentThread(), GetCurrentProcess(), NULL, &ctx32.i386 );
        if (code == -1) break;
        /* this function SYNTHESISES a 64-bit record out
         * of guest register values, and exception_record_64to32() below then
         * applies the single uniform -B.  So anything built from a guest
         * value has to be turned into a host address here first, or it gets
         * -B applied twice.  (Same rule the FEX WoW64 module follows for the
         * records it hands back: they stay host-side.) */
        int_rec.ExceptionAddress = guest_ptr32( ctx32.i386.Eip );
        switch (code)
        {
        case 0x00:  /* division by zero */
            int_rec.ExceptionCode = EXCEPTION_INT_DIVIDE_BY_ZERO;
            break;
        case 0x01:  /* single-step */
            ctx32.i386.EFlags &= ~0x100;
            pBTCpuSetContext( GetCurrentThread(), GetCurrentProcess(), NULL, &ctx32.i386 );
            int_rec.ExceptionCode = EXCEPTION_SINGLE_STEP;
            break;
        case 0x03:  /* breakpoint */
            int_rec.ExceptionCode = EXCEPTION_BREAKPOINT;
            int_rec.ExceptionAddress = guest_ptr32( ctx32.i386.Eip - 1 );
            int_rec.NumberParameters = 1;
            break;
        case 0x04:  /* overflow */
            int_rec.ExceptionCode = EXCEPTION_INT_OVERFLOW;
            break;
        case 0x05:  /* array bounds */
            int_rec.ExceptionCode = EXCEPTION_ARRAY_BOUNDS_EXCEEDED;
            break;
        case 0x06:  /* invalid opcode */
            int_rec.ExceptionCode = EXCEPTION_ILLEGAL_INSTRUCTION;
            break;
        case 0x09:   /* coprocessor segment overrun */
            int_rec.ExceptionCode = EXCEPTION_FLT_INVALID_OPERATION;
            break;
        case 0x0c:  /* stack fault */
            int_rec.ExceptionCode = EXCEPTION_STACK_OVERFLOW;
            break;
        case 0x0d:  /* general protection fault */
            int_rec.ExceptionCode = EXCEPTION_PRIV_INSTRUCTION;
            break;
        case 0x29:  /* __fastfail */
            int_rec.ExceptionCode = STATUS_STACK_BUFFER_OVERRUN;
            int_rec.ExceptionFlags = EXCEPTION_NONCONTINUABLE;
            int_rec.NumberParameters = 1;
            int_rec.ExceptionInformation[0] = ctx32.i386.Ecx;
            first_chance = FALSE;
            break;
        case 0x2d:  /* debug service */
            ctx32.i386.Eip += 3;
            pBTCpuSetContext( GetCurrentThread(), GetCurrentProcess(), NULL, &ctx32.i386 );
            int_rec.ExceptionCode    = EXCEPTION_BREAKPOINT;
            int_rec.ExceptionAddress = guest_ptr32( ctx32.i386.Eip );
            int_rec.NumberParameters = 1;
            int_rec.ExceptionInformation[0] = ctx32.i386.Eax;
            break;
        default:
            int_rec.ExceptionCode = EXCEPTION_ACCESS_VIOLATION;
            int_rec.ExceptionAddress = guest_ptr32( ctx32.i386.Eip );
            int_rec.NumberParameters = 2;
            /* 0xffffffff is the guest-visible "unknown address" sentinel, and
             * this is an ACCESS_VIOLATION, so exception_record_64to32() will
             * apply -B to it.  Store it host-side so it round-trips back to
             * exactly 0xffffffff. */
            int_rec.ExceptionInformation[1] = (ULONG_PTR)guest_ptr32( 0xffffffff );
            break;
        }
        *rec = int_rec;
        break;
    }

    case IMAGE_FILE_MACHINE_ARMNT:
        ctx32.arm.ContextFlags = CONTEXT_ARM_ALL;
        pBTCpuGetContext( GetCurrentThread(), GetCurrentProcess(), NULL, &ctx32.arm );
        break;
    }

    exception_record_64to32( &rec32, rec );
    raise_exception( &rec32, &ctx32, first_chance, rec );

    return STATUS_SUCCESS;
}
