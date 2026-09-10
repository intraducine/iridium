/*
 * ARM64EC signal handling routines
 *
 * Copyright 1999, 2005, 2023 Alexandre Julliard
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public
 * License as published by the Free Software Foundation; either
 * version 3 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * General Public License for more details.
 *
 * You should have received a copy of the GNU General Public
 * License along with this library; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301, USA
 */

#ifdef __arm64ec__

#include <stdlib.h>
#include <stdarg.h>
#include <setjmp.h>

#include "ntstatus.h"
#include "windef.h"
#include "winternl.h"
#include "ddk/wdm.h"
#include "wine/exception.h"
#include "wine/list.h"
#include "ntdll_misc.h"
#include "unixlib.h"
#include "unwind.h"
#include "wine/debug.h"
#include "ntsyscalls.h"

WINE_DEFAULT_DEBUG_CHANNEL(seh);
WINE_DECLARE_DEBUG_CHANNEL(relay);

/* xtajit64.dll functions */
static void     (WINAPI *pBTCpu64FlushInstructionCache)(const void*,SIZE_T);
static BOOLEAN  (WINAPI *pBTCpu64IsProcessorFeaturePresent)(UINT);
/* iOS-only xtajit64 export — see BTInterface.h. On non-iOS hosts the
 * export doesn't exist and the GET_PTR call below returns NULL; the
 * pointer-null check around the unix-call invocation skips it. No
 * #ifdef guard because PE-side builds don't have an iOS-specific
 * macro (target is arm64ec-windows in all cases). */
static void     (WINAPI *pBTCpu64IosAddAliasMapping)(unsigned long long, unsigned long long, unsigned long long);
static void     (WINAPI *pBTCpu64IosSetMonoBridge)(unsigned long long);  /* ml648 */
/* ml618: iOS-only. MUST be obtained via GET_PTR (arm64ec_redirect_ptr), never via a
 * raw base+RVA lookup — see the registration comment below. */
static unsigned int (WINAPI *pBTCpu64IosReleaseThreadHolds)(void*, unsigned long long*, unsigned int*, unsigned int*);
static void     (WINAPI *pBTCpu64NotifyMemoryDirty)(void*,SIZE_T);
static void     (WINAPI *pBTCpu64NotifyReadFile)(HANDLE,void*,SIZE_T,BOOL,NTSTATUS);
static void     (WINAPI *pBeginSimulation)(void);
static void     (WINAPI *pFlushInstructionCacheHeavy)(const void*,SIZE_T);
static NTSTATUS (WINAPI *pNotifyMapViewOfSection)(void*,void*,void*,SIZE_T,ULONG,ULONG);
static void     (WINAPI *pNotifyImageMap)(void*);
static void     (WINAPI *pNotifyMemoryAlloc)(void*,SIZE_T,ULONG,ULONG,BOOL,NTSTATUS);
static void     (WINAPI *pNotifyMemoryFree)(void*,SIZE_T,ULONG,BOOL,NTSTATUS);
static void     (WINAPI *pNotifyMemoryProtect)(void*,SIZE_T,ULONG,BOOL,NTSTATUS);
static void     (WINAPI *pNotifyUnmapViewOfSection)(void*,BOOL,NTSTATUS);
static NTSTATUS (WINAPI *pProcessInit)(void);
static void     (WINAPI *pProcessTerm)(HANDLE,BOOL,NTSTATUS);
static void     (WINAPI *pResetToConsistentState)(EXCEPTION_RECORD*,CONTEXT*,ARM64_NT_CONTEXT*);
static NTSTATUS (WINAPI *pThreadInit)(void);
static void     (WINAPI *pThreadTerm)(HANDLE,LONG);
static void     (WINAPI *pUpdateProcessorInformation)(SYSTEM_CPU_INFORMATION*);

static BOOLEAN emulated_processor_features[PROCESSOR_FEATURE_MAX];
static BYTE KiUserExceptionDispatcher_orig[16]; /* to detect patching */
extern void KiUserExceptionDispatcher_thunk(void) asm("EXP+#KiUserExceptionDispatcher");

static inline CHPE_V2_CPU_AREA_INFO *get_arm64ec_cpu_area(void)
{
    return NtCurrentTeb()->ChpeV2CpuAreaInfo;
}

/* iOS-Madeira ml617: THE GUEST-STACK WINDOW FOR ONE UNWIND.
 *
 * ml616 fabricated 24,576 unwind frames and then terminated the process with
 * exit code 0xdaa1f848 — which is not a status at all, it is the low half of
 * 0x71daa1f848, a stack address from the very frame being walked. The real
 * exception (an execute AV at 0x7e8946a680, private RW heap) was destroyed and
 * replaced by garbage.
 *
 * Root cause is the third fallback below: it accepts ANY aligned, committed,
 * writable private page as a valid frame. Thread 020c's stack ended at
 * 0x71daa20000 and the walk happily accepted 0x71daa20008 and kept going.
 *
 * So bound the walk by the allocation the ORIGINAL guest RSP belongs to:
 *   - use AllocationBase and enumerate every contiguous region of that same
 *     allocation, because guard/committed regions carry different protections
 *     and a single RegionSize would cut the stack short;
 *   - the TEB stack is NOT usable for this — on this port Tib describes the
 *     NATIVE pthread stack, not the guest x64 stack (task #34).
 * Zeroed window = "not established", and the old permissive behaviour stands,
 * so no path that never sets a window can regress. */
struct ec_stack_window
{
    ULONG_PTR lo, hi;      /* validated guest-stack allocation */
    ULONG_PTR emu_lo, emu_hi; /* emulator stack: a legitimate transition target */
    ULONG_PTR last_frame;  /* monotonic baseline within the current segment */
    ULONG_PTR last_pc;
    ULONG     steps, budget;
    ULONG     repeats;
    BOOL      on_emu;      /* which segment the baseline refers to */
};
static __thread struct ec_stack_window ec_win;

static void ec_stack_window_begin( ULONG_PTR rsp )
{
    MEMORY_BASIC_INFORMATION mbi;
    SIZE_T got;
    ULONG_PTR base, probe, hi;
    CHPE_V2_CPU_AREA_INFO *area;

    memset( &ec_win, 0, sizeof(ec_win) );
    if (!rsp) return;
    if (NtQueryVirtualMemory( NtCurrentProcess(), (void *)rsp, MemoryBasicInformation,
                              &mbi, sizeof(mbi), &got )) return;
    if (mbi.State != MEM_COMMIT) return;

    base = (ULONG_PTR)mbi.AllocationBase;
    if (!base) return;

    /* Walk forward while the region still belongs to the same allocation. */
    hi = base;
    for (probe = base; ; )
    {
        if (NtQueryVirtualMemory( NtCurrentProcess(), (void *)probe, MemoryBasicInformation,
                                  &mbi, sizeof(mbi), &got )) break;
        if ((ULONG_PTR)mbi.AllocationBase != base) break;
        hi = (ULONG_PTR)mbi.BaseAddress + mbi.RegionSize;
        probe = hi;
        if (hi <= base) break;   /* paranoia: never loop on a zero-size region */
    }
    if (hi <= base) return;

    ec_win.lo = base;
    ec_win.hi = hi;
    area = get_arm64ec_cpu_area();
    if (area)
    {
        ec_win.emu_lo = area->EmulatorStackLimit;
        ec_win.emu_hi = area->EmulatorStackBase;
    }
    /* Budget proportional to the real range (one frame per 16 bytes is already
     * generous for AAPCS64), with an absolute ceiling so a huge stack cannot buy
     * an unbounded walk. Repeated (pc,frame) pairs are caught separately — a
     * non-advancing walk is corrupt no matter how much budget remains. */
    ec_win.budget = (ULONG)min( (hi - base) / 16, 65536 );
    if (ec_win.budget < 256) ec_win.budget = 256;
    ec_win.last_frame = 0;
    ec_win.on_emu = FALSE;
}

static inline BOOL is_valid_arm64ec_frame( ULONG_PTR frame )
{
    if (frame & (sizeof(void*) - 1)) return FALSE;

    /* ml617: once a window is established it is authoritative — the permissive
     * committed-RW fallback below is exactly what let the walk run away. */
    if (ec_win.hi)
    {
        if (frame >= ec_win.lo && frame < ec_win.hi) return TRUE;
        if (ec_win.emu_hi && frame >= ec_win.emu_lo && frame <= ec_win.emu_hi) return TRUE;
        return FALSE;
    }

    if (is_valid_frame( frame )) return TRUE;
    /* ml382: NULL-safe — this runs during exception dispatch, where a second
     * fault is far worse than a missed range check (see the enter/leave
     * _syscall_callback comment below for why the CPU area can be NULL here). */
    {
        CHPE_V2_CPU_AREA_INFO *area = get_arm64ec_cpu_area();
        if (area && frame >= area->EmulatorStackLimit &&
            frame <= area->EmulatorStackBase) return TRUE;
    }
    /* iOS-Madeira task#34: EC threads here run on THREE stacks — Tib holds
     * the NATIVE pthread stack, the CpuArea holds the emulator stack, and
     * the guest x64 frames live on the GUEST stack that neither range
     * covers (ml65: frame 0x7ecafb0008 vs Tib 0x153c88000-0x153d80000 →
     * "unable to dispatch exception" killed steamwebhelper; same failure
     * class as the old FEX-2607 bootstrapper fault). Windows proper has
     * Tib = the x64 stack, our port cannot (native code needs the pthread
     * stack there). Fallback: accept a frame that points into committed
     * writable private memory — i.e. SOME plausible stack. */
    {
        MEMORY_BASIC_INFORMATION mbi;
        SIZE_T got;
        if (!NtQueryVirtualMemory( NtCurrentProcess(), (void *)frame, MemoryBasicInformation,
                                   &mbi, sizeof(mbi), &got ) &&
            mbi.State == MEM_COMMIT && (mbi.Protect & (PAGE_READWRITE | PAGE_WRITECOPY)))
        {
            static LONG gsf_n;
            if (gsf_n < 20 && InterlockedIncrement( &gsf_n ) <= 20)
                ERR( "[guest-frame] accepting frame %I64x outside Tib/emulator stacks (committed RW region %p+%Ix)\n",
                     (ULONG64)frame, mbi.BaseAddress, mbi.RegionSize );
            return TRUE;
        }
    }
    return FALSE;
}

/* ml617: per-step unwind guard. Returns NULL to continue, else the reason.
 *
 * Monotonic progress is required WITHIN a segment only; a validated transition
 * between the guest stack and the emulator stack legitimately moves the frame
 * pointer anywhere, so the baseline is reset there — but only for a transition
 * we recognise, so a corrupt frame cannot escape the check by pretending to
 * switch stacks. */
static const char *ec_stack_window_step( ULONG_PTR frame, ULONG_PTR pc )
{
    BOOL on_emu;

    if (!ec_win.hi) return NULL;   /* no window established: legacy behaviour */

    if (++ec_win.steps > ec_win.budget) return "budget exceeded";

    if (frame == ec_win.last_frame && pc == ec_win.last_pc)
    {
        if (++ec_win.repeats >= 4) return "no progress (repeated pc/frame)";
        return NULL;
    }
    ec_win.repeats = 0;

    on_emu = (ec_win.emu_hi && frame >= ec_win.emu_lo && frame <= ec_win.emu_hi);
    if (on_emu != ec_win.on_emu)
    {
        /* Recognised stack transition: re-baseline, do not compare across it. */
        ec_win.on_emu = on_emu;
        ec_win.last_frame = frame;
        ec_win.last_pc = pc;
        return NULL;
    }
    /* iOS-Madeira ml627: `<=` WAS A FALSE POSITIVE. `<` IS THE CORRECT TEST.
     *
     * Unwinding walks UP the stack, so a frame pointer must never move BACKWARDS
     * -- but it may legitimately stay EQUAL across consecutive steps while
     * ControlPc changes (several unwind steps can resolve within one frame). The
     * genuinely-stuck case is already covered above by the identical
     * (frame, pc) repeat counter, so `<=` bought nothing and cost correctness.
     *
     * It fired on ULTRAKILL/Mono's thread-naming exception: Mono raises
     * EXCEPTION_WINE_NAME_THREAD (0x406D1388) from mono_native_thread_set_name and
     * expects to resume at `add rsp,0x48; ret`. This guard aborted that unwind at
     * steps=3 with the frame merely equal, flagged the stack invalid, and left the
     * handler/unwind state inconsistent -- after which 0x406D1388+8 was read as a
     * pointer, degrading into 0xC000000D, a 256-deep redelivery storm and a stack
     * overflow. The guard was mine (ml617) and it was the bug. */
    if (ec_win.last_frame && frame < ec_win.last_frame)
        return "frame moved backwards";

    if (ec_win.last_frame && frame == ec_win.last_frame)
    {
        /* Confirmation that this case is real and now allowed. Capped: this runs
         * per unwind step, and formatting in an exception path is what killed
         * ml620. One short line, bounded by construction. */
        static int ml627_same_frame;
        if (ml627_same_frame < 16)
            ERR( "[unwind-guard] ml627 same-frame step #%d frame=%p pc %p -> %p (ALLOWED, was a false stop)\n",
                 ++ml627_same_frame, (void *)frame, (void *)ec_win.last_pc, (void *)pc );
    }

    ec_win.last_frame = frame;
    ec_win.last_pc = pc;
    return NULL;
}

/* iOS-Madeira ml382: the CPU area can legitimately be NULL on this port.
 *
 * get_arm64ec_cpu_area() is NtCurrentTeb()->ChpeV2CpuAreaInfo, and
 * init_thread_stack deliberately does NOT set it for the native-aarch64
 * session — logged three times in the ml382 run:
 *   "iOS arm64ec: NOT setting cpu_area (owner machine=0xaa64 session is_arm64ec=0)"
 * But ARM64EC ntdll code still executes on those threads (every SYSCALL_API
 * wrapper here calls enter/leave_syscall_callback), so the unguarded
 * dereference is a NULL store.
 *
 * That is exactly what killed the SESSION process in ml380 AND ml382 — and
 * killing the session kills the whole app, which is why it capped both runs.
 * Decoded from our own ntdll at the faulting RVA 0x582e4:
 *     ldr  x8, [x18, #0x1788]     ; x8 = TEB->ChpeV2CpuAreaInfo  == 0
 *     strb wzr, [x8, #0x1]        ; InSyscallCallback = 0  -> FAULTS at 0x1
 * matching the log's `addr=0x1 insn=3900051f` and
 * `CPUArea(teb+0x1788)=0x0(ok=1)`.
 *
 * With no CPU area the thread is not running emulated code, so the
 * re-entrancy flag is vacuous: report "not already in a callback" and skip the
 * bookkeeping. Deliberately returning TRUE rather than FALSE — FALSE would
 * route callers to the raw syscall and skip pNotifyMemoryAlloc, and stale FEX
 * memory notifications are what caused the ml36 NOEXEC wall. Proceeding keeps
 * behaviour identical to every thread that does have a CPU area. */
static inline BOOL enter_syscall_callback(void)
{
    CHPE_V2_CPU_AREA_INFO *area = get_arm64ec_cpu_area();

    if (!area) return TRUE;
    if (area->InSyscallCallback) return FALSE;
    area->InSyscallCallback = 1;
    return TRUE;
}

static inline void leave_syscall_callback(void)
{
    CHPE_V2_CPU_AREA_INFO *area = get_arm64ec_cpu_area();

    if (area) area->InSyscallCallback = 0;
}

/**********************************************************************
 *           create_cross_process_work_list
 */
static NTSTATUS create_cross_process_work_list( CHPEV2_PROCESS_INFO *info )
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
    status = NtMapViewOfSection( section, GetCurrentProcess(), (void **)&list, 0, 0, NULL,
                                 &map_size, ViewShare, MEM_TOP_DOWN, PAGE_READWRITE );
    if (status)
    {
        NtClose( section );
        return status;
    }

    end = (CROSS_PROCESS_WORK_ENTRY *)((char *)list + map_size);
    for (i = 0; list->entries + i + 1 <= end; i++)
        RtlWow64PushCrossProcessWorkOntoFreeList( &list->free_list, &list->entries[i] );

    info->SectionHandle = section;
    info->CrossProcessWorkList = list;
    return STATUS_SUCCESS;
}


/**********************************************************************
 *           send_cross_process_notification
 */
static BOOL send_cross_process_notification( HANDLE process, UINT id, const void *addr, SIZE_T size,
                                             int nb_args, ... )
{
    CROSS_PROCESS_WORK_LIST *list;
    CROSS_PROCESS_WORK_ENTRY *entry;
    void *unused;
    HANDLE section;
    va_list args;
    int i;

    RtlOpenCrossProcessEmulatorWorkConnection( process, &section, (void **)&list );
    if (!list) return FALSE;
    if ((entry = RtlWow64PopCrossProcessWorkFromFreeList( &list->free_list )))
    {
        entry->id = id;
        entry->addr = (ULONG_PTR)addr;
        entry->size = size;
        if (nb_args)
        {
            va_start( args, nb_args );
            for (i = 0; i < nb_args; i++) entry->args[i] = va_arg( args, int );
            va_end( args );
        }
        RtlWow64PushCrossProcessWorkOntoWorkList( &list->work_list, entry, &unused );
    }
    NtUnmapViewOfSection( GetCurrentProcess(), list );
    NtClose( section );
    return TRUE;
}


/* iOS: PE .text sections are non-executable at their unix VA; an executable
 * alias lives in the JIT pool. arm64ec_redirect_ptr resolves to unix .text
 * addresses, so on iOS every return path must be translated to the JIT alias.
 *
 * `p_ios_jit_translate_addr` holds the address of unix-side
 * ios_jit_translate_addr (a native ARM64 function), set by unix-side
 * load_ntdll_functions. NULL on non-iOS / pre-init.
 *
 * `xlate_ios_jit` is a naked PE-side thunk that does `br x16` to the unix
 * function — bypassing arm64x_check_call which would otherwise misroute a
 * non-EC target through x86 emulation. Same trick as __wine_unix_call_arm64ec.
 *
 * The pointer is exported via ntdll.spec so unix-side can install the address. */
void *p_ios_jit_translate_addr = NULL;

void *__attribute__((naked)) xlate_ios_jit( void *ptr )
{
    asm( ".seh_proc \"#xlate_ios_jit\"\n\t"
         ".seh_endprologue\n\t"
         "cbz x0, 1f\n\t"                                 /* NULL → return NULL */
         "adrp x16, p_ios_jit_translate_addr\n\t"
         "ldr x16, [x16, #:lo12:p_ios_jit_translate_addr]\n\t"
         "cbz x16, 1f\n\t"                                /* fn-ptr unset → identity */
         "br x16\n"                                       /* tail-call unix fn */
         "1: ret\n\t"
         ".seh_endproc" );
}

/* iOS: the reverse mapping (JIT-pool alias → original PE VA). Exception
 * contexts capture POOL VAs (that's where code physically executes), but
 * function tables / unwind info are registered for PE VAs — so unwinding a
 * pool pc finds no tables, the leaf-frame fallback cycles, and SEH handlers
 * are never found (one boot-time RPC raise spun 1.2e9 unwind steps on a
 * pegged core; with the no-progress guard it became an unhandled-exception
 * process death). virtual_unwind reverse-translates each step's pc through
 * this hook so the walk runs in PE space and handlers resolve. */
void *p_ios_jit_reverse_translate_addr = NULL;

void *__attribute__((naked)) xlate_ios_jit_rev( void *ptr )
{
    asm( ".seh_proc \"#xlate_ios_jit_rev\"\n\t"
         ".seh_endprologue\n\t"
         "cbz x0, 1f\n\t"                                 /* NULL → return NULL */
         "adrp x16, p_ios_jit_reverse_translate_addr\n\t"
         "ldr x16, [x16, #:lo12:p_ios_jit_reverse_translate_addr]\n\t"
         "cbz x16, 1f\n\t"                                /* fn-ptr unset → identity */
         "br x16\n"                                       /* tail-call unix fn */
         "1: ret\n\t"
         ".seh_endproc" );
}


void *arm64ec_redirect_ptr( HMODULE module, void *ptr, const IMAGE_ARM64EC_METADATA *metadata )
{
    const IMAGE_ARM64EC_REDIRECTION_ENTRY *map = get_rva( module, metadata->RedirectionMetadata );
    int min = 0, max = metadata->RedirectionMetadataCount - 1;
    ULONG_PTR rva = (ULONG_PTR)ptr - (ULONG_PTR)module;

    if (!ptr) return NULL;
    while (min <= max)
    {
        int pos = (min + max) / 2;
        if (map[pos].Source == rva)
        {
            /* iOS-Madeira 2026-07-10 (Steam S3 run 7): validate the Destination
             * RVA before trusting it. A corrupt entry once produced
             * module+0xC483974 (far past SizeOfImage); xlate_ios_jit then
             * matched that VA against ANOTHER process's module mapping and a
             * poison pool pointer landed in kernelbase's IAT — the
             * steamerrorreporter64 2000-fault storm. Out-of-image → treat as
             * no-entry and let the thunk-decode / runtime check_call resolve. */
            const IMAGE_NT_HEADERS *nt = RtlImageNtHeader( module );
            if (!nt || map[pos].Destination < nt->OptionalHeader.SizeOfImage)
                return xlate_ios_jit( get_rva( module, map[pos].Destination ) );
            break;
        }
        if (map[pos].Source < rva) min = pos + 1;
        else max = pos - 1;
    }

    /* No entry in the redirection table — but the export may still be a
     * .hexpthk x86_64 thunk in one of two forms:
     *   (a) Forwarder: `jmp qword ptr [rip+offset]` (ff 25 NN NN NN NN) —
     *       loads target from import slot. Used for cross-module forwards
     *       (e.g. kernel32!lstrcmpW → kernelbase!lstrcmpW).
     *   (b) Fast-forward: `mov rsp,rax; mov [rax+0x20],rbx; push rbp;
     *       pop rbp; jmp arm_code` (14 bytes: 48 8b c4 48 89 58 20 55 5d
     *       e9 NN NN NN NN) — the ARM64 target is at thunk+14+offset
     *       within the same module. arm64x_check_call recognizes this at
     *       runtime; we replicate the decode here so direct callers don't
     *       have to dispatch through it. */
    {
        const unsigned char *bytes = ptr;
        /* (b) fast-forward sequence */
        if (bytes[0] == 0x48 && bytes[1] == 0x8b && bytes[2] == 0xc4 &&
            bytes[3] == 0x48 && bytes[4] == 0x89 && bytes[5] == 0x58 &&
            bytes[6] == 0x20 && bytes[7] == 0x55 && bytes[8] == 0x5d &&
            bytes[9] == 0xe9)
        {
            LONG off = *(const LONG *)&bytes[10];
            void *target = (char *)ptr + 14 + off;
            return xlate_ios_jit( target );
        }
        /* (a) simple forwarder thunk */
        if (bytes[0] == 0xff && bytes[1] == 0x25)
        {
            LONG off = *(const LONG *)&bytes[2];
            void **imp = (void **)(bytes + 6 + off);
            void *target = *imp;
            /* Only follow the forwarder if the IAT slot is actually bound to
             * a usable pointer. At import-binding time the target module's
             * IAT may still hold raw IBN RVAs (small 32-bit values) — chasing
             * those returns a low integer that gets stored as a "function
             * pointer" and crashes later when called. Require the value to
             * look like a real address (above the lowest module DllBase).
             * If it doesn't, fall through to `return ptr;` so the IAT entry
             * gets the thunk address, and runtime arm64x_check_call handles
             * the (now-bound) forwarder on first call. */
            if (target && target != ptr && (ULONG_PTR)target >= 0x10000000)
            {
                /* Find the module containing the target and redirect within
                 * it. If the target is also a thunk, this recurses. */
                LDR_DATA_TABLE_ENTRY *mod_entry;
                LIST_ENTRY *list = &RtlGetCurrentPeb()->LdrData->InLoadOrderModuleList;
                LIST_ENTRY *entry;
                for (entry = list->Flink; entry != list; entry = entry->Flink)
                {
                    mod_entry = CONTAINING_RECORD( entry, LDR_DATA_TABLE_ENTRY, InLoadOrderLinks );
                    if ((char *)target >= (char *)mod_entry->DllBase &&
                        (char *)target < (char *)mod_entry->DllBase + mod_entry->SizeOfImage)
                    {
                        const IMAGE_ARM64EC_METADATA *target_metadata =
                            arm64ec_get_module_metadata( mod_entry->DllBase );
                        /* Recursive call already applies xlate_ios_jit at its
                         * own return paths; passing through unchanged is correct. */
                        if (target_metadata)
                            return arm64ec_redirect_ptr( mod_entry->DllBase, target, target_metadata );
                        return xlate_ios_jit( target );
                    }
                }
                /* NOTE (2026-07-10): do NOT reject targets missing from the
                 * module list here — during early loader phases (hybrid
                 * metadata patching) legit targets live in modules not yet
                 * linked in, and returning `ptr` instead zeroed ucrtbase's
                 * dispatch_call_no_redirect slot (blr x16=0 at boot). */
                return xlate_ios_jit( target );
            }
        }
    }
    return xlate_ios_jit( ptr );
}

static void arm64x_check_call(void);

/*******************************************************************
 *         arm64ec_process_init
 */
/*******************************************************************
 *         arm64ec_process_init_dispatchers
 *
 * Phase 1 of arm64ec init: set up dispatcher pointers and FEX function
 * pointers. Must run BEFORE the PE-side DllMain dependency walk so that
 * exception dispatch (KiUserExceptionDispatcher uses
 * __os_arm64x_dispatch_call_no_redirect) and dispatch_emulation
 * (uses pBeginSimulation) work during DllMain.
 *
 * Note: pProcessInit is captured here but NOT called — that's deferred
 * to phase 2 (arm64ec_process_init_finish), which runs AFTER DllMains
 * because FEX's CRT init requires ucrtbase to be initialized.
 */
NTSTATUS arm64ec_process_init_dispatchers( HMODULE module )
{
    CHPEV2_PROCESS_INFO *info = (CHPEV2_PROCESS_INFO *)(RtlGetCurrentPeb() + 1);
    const IMAGE_ARM64EC_METADATA *metadata = arm64ec_get_module_metadata( module );

    /* Stash arm64x_check_call's address in PEB.WerRegistrationData (unused
     * on iOS) BEFORE pProcessInit runs, so ntdll-unix's SEGV handler can
     * dump arm64x_check_call's first instructions if FEX's ProcessInit
     * crashes inside arm64x_check_call. */
    RtlGetCurrentPeb()->WerRegistrationData = arm64x_check_call;

    __os_arm64x_dispatch_call_no_redirect = RtlFindExportedRoutineByName( module, "ExitToX64" );
    __os_arm64x_dispatch_fptr = RtlFindExportedRoutineByName( module, "DispatchJump" );
    __os_arm64x_dispatch_ret = RtlFindExportedRoutineByName( module, "RetToEntryThunk" );

    /* The dispatcher globals were 0 when EVERY ARM64EC module's
     * arm64ec_update_hybrid_metadata ran (because the globals only get set
     * here, AFTER xtajit64 finishes loading — but kernel32/ucrtbase/kernelbase
     * are loaded BEFORE xtajit64 finishes). So every loaded ARM64EC module's
     * hybrid pointer slots currently hold 0. Without this re-patch,
     * kernel32's exit thunks would `blr x16` with x16=0 → branch to NULL.
     *
     * Walk loaded modules and re-patch their hybrid metadata. SKIP ntdll
     * itself: re-running arm64ec_update_hybrid_metadata on ntdll's .data
     * triggers the iOS NtProtect IAT-sync path (in our virtual_ios.c) which
     * over-aggressively rewrites one pointer in ntdll's .data to a JIT-pool
     * address, breaking ntdll's own internals immediately after. ntdll's
     * slots happen to already be functional (the EC dispatcher slots that
     * matter for ntdll are written elsewhere during ntdll's special
     * loader-init path, not via arm64ec_update_hybrid_metadata). */
    {
        LIST_ENTRY *list = &RtlGetCurrentPeb()->LdrData->InLoadOrderModuleList;
        LIST_ENTRY *entry;
        void *self_module = (void *)NtCurrentTeb()->Peb->ImageBaseAddress;  /* unused but harmless */
        (void)self_module;
        void *ntdll_base = (void *)RtlGetCurrentPeb();
        (void)ntdll_base;
        for (entry = list->Flink; entry != list; entry = entry->Flink)
        {
            LDR_DATA_TABLE_ENTRY *mod_entry =
                CONTAINING_RECORD( entry, LDR_DATA_TABLE_ENTRY, InLoadOrderLinks );
            const IMAGE_ARM64EC_METADATA *mod_metadata =
                arm64ec_get_module_metadata( mod_entry->DllBase );
            if (!mod_metadata) continue;
            /* Skip ntdll — re-patch breaks it via iOS NtProtect-sync side
             * effects, and ntdll doesn't need it anyway. Match by base name. */
            if (mod_entry->BaseDllName.Buffer &&
                !wcscmp( mod_entry->BaseDllName.Buffer, L"ntdll.dll" ))
            {
                ERR( "arm64ec_process_init_dispatchers: SKIP ntdll re-patch\n" );
                continue;
            }
            ERR( "arm64ec_process_init_dispatchers: re-patching %s metadata\n",
                 debugstr_w(mod_entry->BaseDllName.Buffer) );
            arm64ec_update_hybrid_metadata( mod_entry->DllBase,
                                            RtlImageNtHeader( mod_entry->DllBase ),
                                            (IMAGE_ARM64EC_METADATA *)mod_metadata );
        }
    }

    /* ml755: print xtajit64's VA band selector log, which nothing else can.
     *
     * ios_fex_band_select() runs during rpmalloc init, before the ARM64EC TEB
     * exists, so it cannot call any logging API -- it appends to a static byte
     * buffer instead. ml751 flushed that buffer from FEX's own Module.cpp after
     * the [build-id] line, which works only when FEX gets far enough to print
     * it. When the selector finds NO BAND, FEX dies long before that on a null
     * allocation result, and every [va-profile] line is lost precisely in the
     * failure that needs explaining.
     *
     * Here is early, it demonstrably runs in those failed launches, it has
     * working logging, and it holds the correct module handle for THIS
     * pseudo-process -- pseudo-processes carry separate libarm64ecfex mappings
     * inside one Mach task, so a native-side symbol lookup could read the wrong
     * copy. Read it as exported DATA; never call a PE export from native code.
     * A stale flush is harmless: FEX's own later flush is bounded by the same
     * length and simply reprints. */
    {
        const int *len = RtlFindExportedRoutineByName( module, "ios_va_log_len" );
        const char *log = RtlFindExportedRoutineByName( module, "ios_va_log" );
        if (len && log && *len > 0)
            ERR( "[va-profile] ml755 selector log (%d bytes, early flush):\n%.*s\n",
                 *len, *len, log );
        else
            ERR( "[va-profile] ml755 selector log EMPTY at dispatcher init "
                 "(len=%p log=%p) -- band selection has not run yet\n", len, log );
    }

#define GET_PTR(name) p ## name = arm64ec_redirect_ptr( module, \
                                      RtlFindExportedRoutineByName( module, #name ), metadata )
    GET_PTR( BTCpu64FlushInstructionCache );
    GET_PTR( BTCpu64IosAddAliasMapping );  /* iOS-only; NULL on non-iOS hosts. */
    GET_PTR( BTCpu64IosReleaseThreadHolds );  /* iOS-only; ml618 leaked-hold release. */
    GET_PTR( BTCpu64IosSetMonoBridge );  /* iOS-only; ml648 Mono backpatcher bridge. */
    GET_PTR( BTCpu64IsProcessorFeaturePresent );
    GET_PTR( BTCpu64NotifyMemoryDirty );
    GET_PTR( BTCpu64NotifyReadFile );
    GET_PTR( BeginSimulation );
    GET_PTR( FlushInstructionCacheHeavy );
    GET_PTR( NotifyImageMap );  /* iOS-only loader-safe fallback; NULL on other hosts. */
    GET_PTR( NotifyMapViewOfSection );
    GET_PTR( NotifyMemoryAlloc );
    GET_PTR( NotifyMemoryFree );
    GET_PTR( NotifyMemoryProtect );
    GET_PTR( NotifyUnmapViewOfSection );
    GET_PTR( ProcessInit );
    GET_PTR( ProcessTerm );
    GET_PTR( ResetToConsistentState );
    GET_PTR( ThreadInit );
    GET_PTR( ThreadTerm );
    GET_PTR( UpdateProcessorInformation );
#undef GET_PTR

    RtlGetCurrentPeb()->ChpeV2ProcessInfo = info;
    info->NativeMachineType = IMAGE_FILE_MACHINE_ARM64;
    info->EmulatedMachineType = IMAGE_FILE_MACHINE_AMD64;
    memcpy( KiUserExceptionDispatcher_orig, KiUserExceptionDispatcher_thunk, sizeof(KiUserExceptionDispatcher_orig) );

    /* iOS-only: push the iOS JIT-pool alias table to xtajit64 so FEX can
     * recognize alias addresses as executable. Without this, x86 sub-ranges
     * inside any copied ARM64EC DLL (sechost, msvcrt, msvcp140, etc.) hit
     * NoExecOp during translation and trap when executed.
     *
     * No #ifdef guard — on non-iOS hosts, pBTCpu64IosAddAliasMapping is NULL
     * (export doesn't exist) and we skip silently. The unix-side handler
     * also returns success with zero mappings on non-iOS. */
    if (pBTCpu64IosAddAliasMapping)
    {
        struct ios_push_jit_aliases_params params = { (void *)pBTCpu64IosAddAliasMapping };
        NTSTATUS push_status = WINE_UNIX_CALL( unix_ios_push_jit_aliases, &params );
        if (push_status)
            ERR( "arm64ec_process_init_dispatchers: unix_ios_push_jit_aliases failed: %lx\n", push_status );
    }
    /* No else — on non-iOS hosts pBTCpu64IosAddAliasMapping is naturally NULL,
     * which is silent + correct: the bridge has nothing to do off-iOS. */

    /* iOS-Madeira ml648: HAND FEX THE MONO-BACKPATCHER BRIDGE.
     *
     * Two hops, both in safe directions. PE -> unix via WINE_UNIX_CALL gets the
     * shared struct's address; PE -> PE via the arm64ec_redirect_ptr'd export
     * hands it to FEX. Nothing here calls an ARM64EC export from native Mach-O
     * code, which is what crashed every ml613 launch.
     *
     * FEX publishes its struct offsets on receipt but leaves mono_base at 0, so
     * the native Mach handler stays inert until InvalidationTracker recognises
     * the Mono module. Off iOS the export is absent, the pointer is NULL, and
     * this is silently skipped. */
    if (pBTCpu64IosSetMonoBridge)
    {
        ULONG64 bridge = 0;
        NTSTATUS st = WINE_UNIX_CALL( unix_ios_mono_bridge_ptr, &bridge );
        if (!st && bridge)
            pBTCpu64IosSetMonoBridge( bridge );
        else
            ERR( "ml648: mono bridge unavailable (status %lx, ptr %s)\n",
                 st, bridge ? "set" : "NULL" );
    }

    /* iOS-Madeira ml618: REGISTER THE LEAKED-HOLD RELEASE CALLBACK.
     *
     * ml611/ml616/ml617 all froze the whole app the same way: a thread dies in
     * abnormal exit still owning one CodeInvalidationMutex reader, a writer
     * queues behind it, write-priority blocks every later reader, and JIT
     * compilation stops process-wide (ml617: callret-gen 312 -> 0 at the exact
     * line the hold leaked).
     *
     * 🔑 PROVENANCE IS THE WHOLE FIX. ml613 resolved this same export with
     * ios_pe_find_export() — plain module_base + export_rva — which yields the
     * raw x64 ENTRY THUNK. Native ARM64 then executed `48 8b c4 48...` and every
     * launch died. GET_PTR above goes through arm64ec_redirect_ptr(), which
     * resolves the EC redirection entry and xlate_ios_jit()s it into an
     * executable ARM64 alias in the JIT pool. That pointer IS natively callable
     * — which is why pBTCpu64IosAddAliasMapping has always worked when called
     * from unix code, including long after the original unix call returned.
     *
     * ⛔ NEVER register a pointer obtained any other way.
     *
     * The self-test below is the cheap insurance: invoke with a NULL TEB, which
     * the callback answers with REL_SELFTEST and nothing else. If we ever bind a
     * raw thunk again, this faults here at init instead of on a dying thread. */
    if (pBTCpu64IosReleaseThreadHolds)
    {
        unsigned int probe = pBTCpu64IosReleaseThreadHolds( NULL, NULL, NULL, NULL );
        if (probe != 0x10u)
        {
            ERR( "[hold-release] ml618 SELF-TEST FAILED (got %#x, want 0x10) — NOT registering; "
                 "the bound pointer is not the redirected ARM64 alias\n", probe );
        }
        else
        {
            struct ios_register_hold_release_params params;
            NTSTATUS reg_status;
            params.size     = sizeof(params);
            params.version  = 1;
            params.peb      = RtlGetCurrentPeb();
            params.callback = (void *)pBTCpu64IosReleaseThreadHolds;
            reg_status = WINE_UNIX_CALL( unix_ios_register_hold_release, &params );
            ERR( "[hold-release] ml618 self-test OK; registered cb=%p peb=%p -> %lx\n",
                 (void *)pBTCpu64IosReleaseThreadHolds, params.peb, reg_status );
        }
    }

    return STATUS_SUCCESS;
}


/*******************************************************************
 *         arm64ec_process_init
 *
 * Phase 2 of arm64ec init: invoke FEX's pProcessInit and pThreadInit,
 * then set the call-checker slots. Must run AFTER all module DllMains
 * so that ucrtbase's CRT (lock_table etc.) is initialized when FEX's
 * CRT static constructors fire.
 */
NTSTATUS arm64ec_process_init( HMODULE module )
{
    NTSTATUS status = STATUS_SUCCESS;
    CHPEV2_PROCESS_INFO *info = RtlGetCurrentPeb()->ChpeV2ProcessInfo;
    (void)module;

    enter_syscall_callback();
    if (pProcessInit) status = pProcessInit();
    ERR( "arm64ec_process_init: pProcessInit -> %lx (info=%p)\n", status, info );
    if (!status)
    {
        for (unsigned int i = 0; i < PROCESSOR_FEATURE_MAX; i++)
            emulated_processor_features[i] = pBTCpu64IsProcessorFeaturePresent( i );
        status = create_cross_process_work_list( info );
        ERR( "arm64ec_process_init: create_cross_process_work_list -> %lx\n", status );
    }
    if (!status && pThreadInit)
    {
        status = pThreadInit();
        ERR( "arm64ec_process_init: pThreadInit -> %lx\n", status );
    }
    leave_syscall_callback();
    __os_arm64x_check_call = arm64x_check_call;
    __os_arm64x_check_icall = arm64x_check_call;
    __os_arm64x_check_icall_cfg = arm64x_check_call;
    return status;
}


/*******************************************************************
 *         arm64ec_thread_init
 */
NTSTATUS arm64ec_thread_init(void)
{
    NTSTATUS status = STATUS_SUCCESS;

    enter_syscall_callback();
    if (pThreadInit) status = pThreadInit();
    leave_syscall_callback();
    return status;
}


/**********************************************************************
 *           arm64ec_get_module_metadata
 */
IMAGE_ARM64EC_METADATA *arm64ec_get_module_metadata( HMODULE module )
{
    IMAGE_LOAD_CONFIG_DIRECTORY *cfg;
    ULONG size;

    if (!(cfg = RtlImageDirectoryEntryToData( module, TRUE,
                                              IMAGE_DIRECTORY_ENTRY_LOAD_CONFIG, &size )))
        return NULL;

    size = min( size, cfg->Size );
    if (size <= offsetof( IMAGE_LOAD_CONFIG_DIRECTORY, CHPEMetadataPointer )) return NULL;
    return (IMAGE_ARM64EC_METADATA *)cfg->CHPEMetadataPointer;
}


static void update_hybrid_pointer( void *module, const IMAGE_SECTION_HEADER *sec, UINT rva, void *ptr )
{
    if (!rva) return;

    if (rva < sec->VirtualAddress || rva >= sec->VirtualAddress + sec->Misc.VirtualSize)
        ERR( "rva %x outside of section %s (%lx-%lx)\n", rva,
             sec->Name, sec->VirtualAddress, sec->VirtualAddress + sec->Misc.VirtualSize );
    else
        *(void **)get_rva( module, rva ) = ptr;
}

/*******************************************************************
 *         arm64ec_update_hybrid_metadata
 */
void arm64ec_update_hybrid_metadata( void *module, IMAGE_NT_HEADERS *nt,
                                     const IMAGE_ARM64EC_METADATA *metadata )
{
    DWORD i, protect_old;
    const IMAGE_SECTION_HEADER *sec = IMAGE_FIRST_SECTION( nt );

    /* assume that all pointers are in the same section */
    ERR( "arm64ec_update_hybrid_metadata: module=%p dispatch_call_rva=%lx check_call=%p\n",
         module, (unsigned long)metadata->__os_arm64x_dispatch_call, arm64x_check_call );

    for (i = 0; i < nt->FileHeader.NumberOfSections; i++, sec++)
    {
        if ((sec->VirtualAddress <= metadata->__os_arm64x_dispatch_call) &&
            (sec->VirtualAddress + sec->Misc.VirtualSize > metadata->__os_arm64x_dispatch_call))
        {
            void *base = get_rva( module, sec->VirtualAddress );
            SIZE_T size = sec->Misc.VirtualSize;

            NtProtectVirtualMemory( NtCurrentProcess(), &base, &size, PAGE_READWRITE, &protect_old );

#define SET_FUNC(func,val) update_hybrid_pointer( module, sec, metadata->func, val )
            SET_FUNC( __os_arm64x_dispatch_call, arm64x_check_call );
            SET_FUNC( __os_arm64x_dispatch_call_no_redirect, __os_arm64x_dispatch_call_no_redirect );
            SET_FUNC( __os_arm64x_dispatch_fptr, __os_arm64x_dispatch_fptr );
            SET_FUNC( __os_arm64x_dispatch_icall, arm64x_check_call );
            SET_FUNC( __os_arm64x_dispatch_icall_cfg, arm64x_check_call );
            SET_FUNC( __os_arm64x_dispatch_ret, __os_arm64x_dispatch_ret );
            SET_FUNC( __os_arm64x_helper3, __os_arm64x_helper3 );
            SET_FUNC( __os_arm64x_helper4, __os_arm64x_helper4 );
            SET_FUNC( __os_arm64x_helper5, __os_arm64x_helper5 );
            SET_FUNC( __os_arm64x_helper6, __os_arm64x_helper6 );
            SET_FUNC( __os_arm64x_helper7, __os_arm64x_helper7 );
            SET_FUNC( __os_arm64x_helper8, __os_arm64x_helper8 );
            SET_FUNC( GetX64InformationFunctionPointer, __os_arm64x_get_x64_information );
            SET_FUNC( SetX64InformationFunctionPointer, __os_arm64x_set_x64_information );
#undef SET_FUNC

            NtProtectVirtualMemory( NtCurrentProcess(), &base, &size, protect_old, &protect_old );
            return;
        }
    }
    ERR( "module %p no section found for %lx\n", module, metadata->__os_arm64x_dispatch_call );
}


/*******************************************************************
 *         syscalls
 */
enum syscall_ids
{
#define SYSCALL_ENTRY(id,name,args) __id_##name = id,
ALL_SYSCALLS
#undef SYSCALL_ENTRY
    __nb_syscalls
};

#define DEFINE_SYSCALL_(ret,name,args) \
    ret __attribute__((naked, hybrid_patchable)) name args { __ASM_SYSCALL_FUNC( __id_##name, name ); }

#define DEFINE_SYSCALL(name,args) DEFINE_SYSCALL_(NTSTATUS,name,args)

#define DEFINE_WRAPPED_SYSCALL(name,args) \
    static NTSTATUS __attribute__((naked)) syscall_##name args { __ASM_SYSCALL_FUNC( __id_##name, syscall_##name ); }

#define SYSCALL_API __attribute__((hybrid_patchable))

DEFINE_SYSCALL(NtAcceptConnectPort, (HANDLE *handle, ULONG id, LPC_MESSAGE *msg, BOOLEAN accept, LPC_SECTION_WRITE *write, LPC_SECTION_READ *read))
DEFINE_SYSCALL(NtAccessCheck, (PSECURITY_DESCRIPTOR descr, HANDLE token, ACCESS_MASK access, GENERIC_MAPPING *mapping, PRIVILEGE_SET *privs, ULONG *retlen, ULONG *access_granted, NTSTATUS *access_status))
DEFINE_SYSCALL(NtAccessCheckAndAuditAlarm, (UNICODE_STRING *subsystem, HANDLE handle, UNICODE_STRING *typename, UNICODE_STRING *objectname, PSECURITY_DESCRIPTOR descr, ACCESS_MASK access, GENERIC_MAPPING *mapping, BOOLEAN creation, ACCESS_MASK *access_granted, NTSTATUS *access_status, BOOLEAN *onclose))
DEFINE_SYSCALL(NtAccessCheckByTypeAndAuditAlarm, (UNICODE_STRING *subsystem, HANDLE handle, UNICODE_STRING *typename, UNICODE_STRING *objectname, PSECURITY_DESCRIPTOR descr, PSID sid, ACCESS_MASK access, AUDIT_EVENT_TYPE audit_type, ULONG flags, OBJECT_TYPE_LIST *obj_list, ULONG list_len, GENERIC_MAPPING *mapping, BOOLEAN creation, ACCESS_MASK *access_granted, NTSTATUS *access_status, BOOLEAN *onclose))
DEFINE_SYSCALL(NtAddAtom, (const WCHAR *name, ULONG length, RTL_ATOM *atom))
DEFINE_SYSCALL(NtAdjustGroupsToken, (HANDLE token, BOOLEAN reset, TOKEN_GROUPS *groups, ULONG length, TOKEN_GROUPS *prev, ULONG *retlen))
DEFINE_SYSCALL(NtAdjustPrivilegesToken, (HANDLE token, BOOLEAN disable, TOKEN_PRIVILEGES *privs, DWORD length, TOKEN_PRIVILEGES *prev, DWORD *retlen))
DEFINE_SYSCALL(NtAlertMultipleThreadByThreadId, (HANDLE *tids, ULONG count, void *unk1, void *unk2))
DEFINE_SYSCALL(NtAlertResumeThread, (HANDLE handle, ULONG *count))
DEFINE_SYSCALL(NtAlertThread, (HANDLE handle))
DEFINE_SYSCALL(NtAlertThreadByThreadId, (HANDLE tid))
DEFINE_SYSCALL(NtAllocateLocallyUniqueId, (LUID *luid))
DEFINE_SYSCALL(NtAllocateReserveObject, (HANDLE *handle, const OBJECT_ATTRIBUTES *attr, MEMORY_RESERVE_OBJECT_TYPE type))
DEFINE_SYSCALL(NtAllocateUuids, (ULARGE_INTEGER *time, ULONG *delta, ULONG *sequence, UCHAR *seed))
DEFINE_WRAPPED_SYSCALL(NtAllocateVirtualMemory, (HANDLE process, PVOID *ret, ULONG_PTR zero_bits, SIZE_T *size_ptr, ULONG type, ULONG protect))
DEFINE_WRAPPED_SYSCALL(NtAllocateVirtualMemoryEx, (HANDLE process, PVOID *ret, SIZE_T *size_ptr, ULONG type, ULONG protect, MEM_EXTENDED_PARAMETER *parameters, ULONG count))
DEFINE_SYSCALL(NtApphelpCacheControl, (ULONG class, void *context))
DEFINE_SYSCALL(NtAreMappedFilesTheSame, (PVOID addr1, PVOID addr2))
DEFINE_SYSCALL(NtAssignProcessToJobObject, (HANDLE job, HANDLE process))
DEFINE_SYSCALL(NtCallbackReturn, (void *ret_ptr, ULONG ret_len, NTSTATUS status))
DEFINE_SYSCALL(NtCancelIoFile, (HANDLE handle, IO_STATUS_BLOCK *io_status))
DEFINE_SYSCALL(NtCancelIoFileEx, (HANDLE handle, IO_STATUS_BLOCK *io, IO_STATUS_BLOCK *io_status))
DEFINE_SYSCALL(NtCancelSynchronousIoFile, (HANDLE handle, IO_STATUS_BLOCK *io, IO_STATUS_BLOCK *io_status))
DEFINE_SYSCALL(NtCancelTimer, (HANDLE handle, BOOLEAN *state))
DEFINE_SYSCALL(NtClearEvent, (HANDLE handle))
DEFINE_WRAPPED_SYSCALL(NtClose, (HANDLE handle))
DEFINE_SYSCALL(NtCloseObjectAuditAlarm, (UNICODE_STRING *subsystem, HANDLE handle, BOOLEAN onclose))
DEFINE_SYSCALL(NtCommitTransaction, (HANDLE transaction, BOOLEAN wait))
DEFINE_SYSCALL(NtCompareObjects, (HANDLE first, HANDLE second))
DEFINE_SYSCALL(NtCompareTokens, (HANDLE first, HANDLE second, BOOLEAN *equal))
DEFINE_SYSCALL(NtCompleteConnectPort, (HANDLE handle))
DEFINE_SYSCALL(NtConnectPort, (HANDLE *handle, UNICODE_STRING *name, SECURITY_QUALITY_OF_SERVICE *qos, LPC_SECTION_WRITE *write, LPC_SECTION_READ *read, ULONG *max_len, void *info, ULONG *info_len))
DEFINE_WRAPPED_SYSCALL(NtContinue, (ARM64_NT_CONTEXT *context, BOOLEAN alertable))
DEFINE_WRAPPED_SYSCALL(NtContinueEx, (ARM64_NT_CONTEXT *context, KCONTINUE_ARGUMENT *args))
DEFINE_SYSCALL(NtConvertBetweenAuxiliaryCounterAndPerformanceCounter, (ULONG flag, ULONGLONG *from, ULONGLONG *to, ULONGLONG *error))
DEFINE_SYSCALL(NtCreateDebugObject, (HANDLE *handle, ACCESS_MASK access, OBJECT_ATTRIBUTES *attr, ULONG flags))
DEFINE_SYSCALL(NtCreateDirectoryObject, (HANDLE *handle, ACCESS_MASK access, OBJECT_ATTRIBUTES *attr))
DEFINE_WRAPPED_SYSCALL(NtCreateEvent, (HANDLE *handle, ACCESS_MASK access, const OBJECT_ATTRIBUTES *attr, EVENT_TYPE type, BOOLEAN state))
DEFINE_SYSCALL(NtCreateFile, (HANDLE *handle, ACCESS_MASK access, OBJECT_ATTRIBUTES *attr, IO_STATUS_BLOCK *io, LARGE_INTEGER *alloc_size, ULONG attributes, ULONG sharing, ULONG disposition, ULONG options, void *ea_buffer, ULONG ea_length))
DEFINE_SYSCALL(NtCreateIoCompletion, (HANDLE *handle, ACCESS_MASK access, OBJECT_ATTRIBUTES *attr, ULONG threads))
DEFINE_SYSCALL(NtCreateJobObject, (HANDLE *handle, ACCESS_MASK access, const OBJECT_ATTRIBUTES *attr))
DEFINE_SYSCALL(NtCreateKey, (HANDLE *key, ACCESS_MASK access, const OBJECT_ATTRIBUTES *attr, ULONG index, const UNICODE_STRING *class, ULONG options, ULONG *dispos))
DEFINE_SYSCALL(NtCreateKeyTransacted, (HANDLE *key, ACCESS_MASK access, const OBJECT_ATTRIBUTES *attr, ULONG index, const UNICODE_STRING *class, ULONG options, HANDLE transacted, ULONG *dispos))
DEFINE_SYSCALL(NtCreateKeyedEvent, (HANDLE *handle, ACCESS_MASK access, const OBJECT_ATTRIBUTES *attr, ULONG flags))
DEFINE_SYSCALL(NtCreateLowBoxToken, (HANDLE *token_handle, HANDLE token, ACCESS_MASK access, OBJECT_ATTRIBUTES *attr, SID *sid, ULONG count, SID_AND_ATTRIBUTES *capabilities, ULONG handle_count, HANDLE *handle))
DEFINE_SYSCALL(NtCreateMailslotFile, (HANDLE *handle, ULONG access, OBJECT_ATTRIBUTES *attr, IO_STATUS_BLOCK *io, ULONG options, ULONG quota, ULONG msg_size, LARGE_INTEGER *timeout))
DEFINE_WRAPPED_SYSCALL(NtCreateMutant, (HANDLE *handle, ACCESS_MASK access, const OBJECT_ATTRIBUTES *attr, BOOLEAN owned))
DEFINE_SYSCALL(NtCreateNamedPipeFile, (HANDLE *handle, ULONG access, OBJECT_ATTRIBUTES *attr, IO_STATUS_BLOCK *io, ULONG sharing, ULONG dispo, ULONG options, ULONG pipe_type, ULONG read_mode, ULONG completion_mode, ULONG max_inst, ULONG inbound_quota, ULONG outbound_quota, LARGE_INTEGER *timeout))
DEFINE_SYSCALL(NtCreatePagingFile, (UNICODE_STRING *name, LARGE_INTEGER *min_size, LARGE_INTEGER *max_size, LARGE_INTEGER *actual_size))
DEFINE_SYSCALL(NtCreatePort, (HANDLE *handle, OBJECT_ATTRIBUTES *attr, ULONG info_len, ULONG data_len, ULONG *reserved))
DEFINE_SYSCALL(NtCreateProcessEx, (HANDLE *handle, ACCESS_MASK access, OBJECT_ATTRIBUTES *attr, HANDLE parent, ULONG flags, HANDLE section, HANDLE debug, HANDLE token, ULONG reserved))
DEFINE_WRAPPED_SYSCALL(NtCreateSection, (HANDLE *handle, ACCESS_MASK access, const OBJECT_ATTRIBUTES *attr, const LARGE_INTEGER *size, ULONG protect, ULONG sec_flags, HANDLE file))
DEFINE_SYSCALL(NtCreateSectionEx, (HANDLE *handle, ACCESS_MASK access, const OBJECT_ATTRIBUTES *attr, const LARGE_INTEGER *size, ULONG protect, ULONG sec_flags, HANDLE file, MEM_EXTENDED_PARAMETER *parameters, ULONG count))
DEFINE_SYSCALL(NtCreateSemaphore, (HANDLE *handle, ACCESS_MASK access, const OBJECT_ATTRIBUTES *attr, LONG initial, LONG max))
DEFINE_SYSCALL(NtCreateSymbolicLinkObject, (HANDLE *handle, ACCESS_MASK access, OBJECT_ATTRIBUTES *attr, UNICODE_STRING *target))
DEFINE_SYSCALL(NtCreateThread, (HANDLE *handle, ACCESS_MASK access, OBJECT_ATTRIBUTES *attr, HANDLE process, CLIENT_ID *id, CONTEXT *ctx, INITIAL_TEB *teb, BOOLEAN suspended))
DEFINE_SYSCALL(NtCreateThreadEx, (HANDLE *handle, ACCESS_MASK access, OBJECT_ATTRIBUTES *attr, HANDLE process, PRTL_THREAD_START_ROUTINE start, void *param, ULONG flags, ULONG_PTR zero_bits, SIZE_T stack_commit, SIZE_T stack_reserve, PS_ATTRIBUTE_LIST *attr_list))
DEFINE_SYSCALL(NtCreateTimer, (HANDLE *handle, ACCESS_MASK access, const OBJECT_ATTRIBUTES *attr, TIMER_TYPE type))
DEFINE_SYSCALL(NtCreateToken, (HANDLE *handle, ACCESS_MASK access, OBJECT_ATTRIBUTES *attr, TOKEN_TYPE type, LUID *token_id, LARGE_INTEGER *expire, TOKEN_USER *user, TOKEN_GROUPS *groups, TOKEN_PRIVILEGES *privs, TOKEN_OWNER *owner, TOKEN_PRIMARY_GROUP *group, TOKEN_DEFAULT_DACL *dacl, TOKEN_SOURCE *source))
DEFINE_SYSCALL(NtCreateTransaction, (HANDLE *handle, ACCESS_MASK mask, OBJECT_ATTRIBUTES *obj_attr, GUID *guid, HANDLE tm, ULONG options, ULONG isol_level, ULONG isol_flags, PLARGE_INTEGER timeout, UNICODE_STRING *description))
DEFINE_SYSCALL(NtCreateUserProcess, (HANDLE *process_handle_ptr, HANDLE *thread_handle_ptr, ACCESS_MASK process_access, ACCESS_MASK thread_access, OBJECT_ATTRIBUTES *process_attr, OBJECT_ATTRIBUTES *thread_attr, ULONG process_flags, ULONG thread_flags, RTL_USER_PROCESS_PARAMETERS *params, PS_CREATE_INFO *info, PS_ATTRIBUTE_LIST *ps_attr))
DEFINE_SYSCALL(NtDebugActiveProcess, (HANDLE process, HANDLE debug))
DEFINE_SYSCALL(NtDebugContinue, (HANDLE handle, CLIENT_ID *client, NTSTATUS status))
DEFINE_WRAPPED_SYSCALL(NtDelayExecution, (BOOLEAN alertable, const LARGE_INTEGER *timeout))
DEFINE_SYSCALL(NtDeleteAtom, (RTL_ATOM atom))
DEFINE_SYSCALL(NtDeleteFile, (OBJECT_ATTRIBUTES *attr))
DEFINE_SYSCALL(NtDeleteKey, (HANDLE key))
DEFINE_SYSCALL(NtDeleteValueKey, (HANDLE key, const UNICODE_STRING *name))
DEFINE_WRAPPED_SYSCALL(NtDeviceIoControlFile, (HANDLE handle, HANDLE event, PIO_APC_ROUTINE apc, void *apc_context, IO_STATUS_BLOCK *io, ULONG code, void *in_buffer, ULONG in_size, void *out_buffer, ULONG out_size))
DEFINE_SYSCALL(NtDisplayString, (UNICODE_STRING *string))
DEFINE_SYSCALL(NtDuplicateObject, (HANDLE source_process, HANDLE source, HANDLE dest_process, HANDLE *dest, ACCESS_MASK access, ULONG attributes, ULONG options))
DEFINE_SYSCALL(NtDuplicateToken, (HANDLE token, ACCESS_MASK access, OBJECT_ATTRIBUTES *attr, BOOLEAN effective_only, TOKEN_TYPE type, HANDLE *handle))
DEFINE_SYSCALL(NtEnumerateKey, (HANDLE handle, ULONG index, KEY_INFORMATION_CLASS info_class, void *info, DWORD length, DWORD *result_len))
DEFINE_SYSCALL(NtEnumerateValueKey, (HANDLE handle, ULONG index, KEY_VALUE_INFORMATION_CLASS info_class, void *info, DWORD length, DWORD *result_len))
DEFINE_SYSCALL(NtFilterToken, (HANDLE token, ULONG flags, TOKEN_GROUPS *disable_sids, TOKEN_PRIVILEGES *privileges, TOKEN_GROUPS *restrict_sids, HANDLE *new_token))
DEFINE_SYSCALL(NtFindAtom, (const WCHAR *name, ULONG length, RTL_ATOM *atom))
DEFINE_SYSCALL(NtFlushBuffersFile, (HANDLE handle, IO_STATUS_BLOCK *io))
DEFINE_SYSCALL(NtFlushBuffersFileEx, (HANDLE handle, ULONG flags, void *params, ULONG size, IO_STATUS_BLOCK *io))
DEFINE_WRAPPED_SYSCALL(NtFlushInstructionCache, (HANDLE handle, const void *addr, SIZE_T size))
DEFINE_SYSCALL(NtFlushKey, (HANDLE key))
DEFINE_SYSCALL(NtFlushProcessWriteBuffers, (void))
DEFINE_SYSCALL(NtFlushVirtualMemory, (HANDLE process, LPCVOID *addr_ptr, SIZE_T *size_ptr, ULONG unknown))
DEFINE_WRAPPED_SYSCALL(NtFreeVirtualMemory, (HANDLE process, PVOID *addr_ptr, SIZE_T *size_ptr, ULONG type))
DEFINE_SYSCALL(NtFsControlFile, (HANDLE handle, HANDLE event, PIO_APC_ROUTINE apc, void *apc_context, IO_STATUS_BLOCK *io, ULONG code, void *in_buffer, ULONG in_size, void *out_buffer, ULONG out_size))
DEFINE_WRAPPED_SYSCALL(NtGetContextThread, (HANDLE handle, ARM64_NT_CONTEXT *context))
DEFINE_SYSCALL_(ULONG, NtGetCurrentProcessorNumber, (void))
DEFINE_SYSCALL(NtGetNextProcess, (HANDLE process, ACCESS_MASK access, ULONG attributes, ULONG flags, HANDLE *handle))
DEFINE_SYSCALL(NtGetNextThread, (HANDLE process, HANDLE thread, ACCESS_MASK access, ULONG attributes, ULONG flags, HANDLE *handle))
DEFINE_SYSCALL(NtGetNlsSectionPtr, (ULONG type, ULONG id, void *unknown, void **ptr, SIZE_T *size))
DEFINE_SYSCALL(NtGetWriteWatch, (HANDLE process, ULONG flags, PVOID base, SIZE_T size, PVOID *addresses, ULONG_PTR *count, ULONG *granularity))
DEFINE_SYSCALL(NtImpersonateAnonymousToken, (HANDLE thread))
DEFINE_SYSCALL(NtImpersonateClientOfPort, (HANDLE handle, LPC_MESSAGE *request))
DEFINE_SYSCALL(NtInitializeNlsFiles, (void **ptr, LCID *lcid, LARGE_INTEGER *size))
DEFINE_SYSCALL(NtInitiatePowerAction, (POWER_ACTION action, SYSTEM_POWER_STATE state, ULONG flags, BOOLEAN async))
DEFINE_SYSCALL(NtIsProcessInJob, (HANDLE process, HANDLE job))
DEFINE_SYSCALL(NtListenPort, (HANDLE handle, LPC_MESSAGE *msg))
DEFINE_SYSCALL(NtLoadDriver, (const UNICODE_STRING *name))
DEFINE_SYSCALL(NtLoadKey, (const OBJECT_ATTRIBUTES *attr, OBJECT_ATTRIBUTES *file))
DEFINE_SYSCALL(NtLoadKey2, (const OBJECT_ATTRIBUTES *attr, OBJECT_ATTRIBUTES *file, ULONG flags))
DEFINE_SYSCALL(NtLoadKeyEx, (const OBJECT_ATTRIBUTES *attr, OBJECT_ATTRIBUTES *file, ULONG flags, HANDLE trustkey, HANDLE event, ACCESS_MASK access, HANDLE *roothandle, IO_STATUS_BLOCK *iostatus))
DEFINE_SYSCALL(NtLockFile, (HANDLE file, HANDLE event, PIO_APC_ROUTINE apc, void* apc_user, IO_STATUS_BLOCK *io_status, LARGE_INTEGER *offset, LARGE_INTEGER *count, ULONG *key, BOOLEAN dont_wait, BOOLEAN exclusive))
DEFINE_SYSCALL(NtLockVirtualMemory, (HANDLE process, PVOID *addr, SIZE_T *size, ULONG unknown))
DEFINE_SYSCALL(NtMakePermanentObject, (HANDLE handle))
DEFINE_SYSCALL(NtMakeTemporaryObject, (HANDLE handle))
DEFINE_SYSCALL(NtMapUserPhysicalPagesScatter, (void **addr, SIZE_T count, ULONG_PTR *pages))
DEFINE_WRAPPED_SYSCALL(NtMapViewOfSection, (HANDLE handle, HANDLE process, PVOID *addr_ptr, ULONG_PTR zero_bits, SIZE_T commit_size, const LARGE_INTEGER *offset_ptr, SIZE_T *size_ptr, SECTION_INHERIT inherit, ULONG alloc_type, ULONG protect))
DEFINE_WRAPPED_SYSCALL(NtMapViewOfSectionEx, (HANDLE handle, HANDLE process, PVOID *addr_ptr, const LARGE_INTEGER *offset_ptr, SIZE_T *size_ptr, ULONG alloc_type, ULONG protect, MEM_EXTENDED_PARAMETER *parameters, ULONG count))
DEFINE_SYSCALL(NtNotifyChangeDirectoryFile, (HANDLE handle, HANDLE event, PIO_APC_ROUTINE apc, void *apc_context, IO_STATUS_BLOCK *iosb, void *buffer, ULONG buffer_size, ULONG filter, BOOLEAN subtree))
DEFINE_SYSCALL(NtNotifyChangeKey, (HANDLE key, HANDLE event, PIO_APC_ROUTINE apc, void *apc_context, IO_STATUS_BLOCK *io, ULONG filter, BOOLEAN subtree, void *buffer, ULONG length, BOOLEAN async))
DEFINE_SYSCALL(NtNotifyChangeMultipleKeys, (HANDLE key, ULONG count, OBJECT_ATTRIBUTES *attr, HANDLE event, PIO_APC_ROUTINE apc, void *apc_context, IO_STATUS_BLOCK *io, ULONG filter, BOOLEAN subtree, void *buffer, ULONG length, BOOLEAN async))
DEFINE_SYSCALL(NtOpenDirectoryObject, (HANDLE *handle, ACCESS_MASK access, const OBJECT_ATTRIBUTES *attr))
DEFINE_WRAPPED_SYSCALL(NtOpenEvent, (HANDLE *handle, ACCESS_MASK access, const OBJECT_ATTRIBUTES *attr))
DEFINE_SYSCALL(NtOpenFile, (HANDLE *handle, ACCESS_MASK access, OBJECT_ATTRIBUTES *attr, IO_STATUS_BLOCK *io, ULONG sharing, ULONG options))
DEFINE_SYSCALL(NtOpenIoCompletion, (HANDLE *handle, ACCESS_MASK access, const OBJECT_ATTRIBUTES *attr))
DEFINE_SYSCALL(NtOpenJobObject, (HANDLE *handle, ACCESS_MASK access, const OBJECT_ATTRIBUTES *attr))
DEFINE_SYSCALL(NtOpenKey, (HANDLE *key, ACCESS_MASK access, const OBJECT_ATTRIBUTES *attr))
DEFINE_SYSCALL(NtOpenKeyEx, (HANDLE *key, ACCESS_MASK access, const OBJECT_ATTRIBUTES *attr, ULONG options))
DEFINE_SYSCALL(NtOpenKeyTransacted, (HANDLE *key, ACCESS_MASK access, const OBJECT_ATTRIBUTES *attr, HANDLE transaction))
DEFINE_SYSCALL(NtOpenKeyTransactedEx, (HANDLE *key, ACCESS_MASK access, const OBJECT_ATTRIBUTES *attr, ULONG options, HANDLE transaction))
DEFINE_SYSCALL(NtOpenKeyedEvent, (HANDLE *handle, ACCESS_MASK access, const OBJECT_ATTRIBUTES *attr))
DEFINE_WRAPPED_SYSCALL(NtOpenMutant, (HANDLE *handle, ACCESS_MASK access, const OBJECT_ATTRIBUTES *attr))
DEFINE_SYSCALL(NtOpenProcess, (HANDLE *handle, ACCESS_MASK access, const OBJECT_ATTRIBUTES *attr, const CLIENT_ID *id))
DEFINE_SYSCALL(NtOpenProcessToken, (HANDLE process, DWORD access, HANDLE *handle))
DEFINE_SYSCALL(NtOpenProcessTokenEx, (HANDLE process, DWORD access, DWORD attributes, HANDLE *handle))
DEFINE_WRAPPED_SYSCALL(NtOpenSection, (HANDLE *handle, ACCESS_MASK access, const OBJECT_ATTRIBUTES *attr))
DEFINE_SYSCALL(NtOpenSemaphore, (HANDLE *handle, ACCESS_MASK access, const OBJECT_ATTRIBUTES *attr))
DEFINE_SYSCALL(NtOpenSymbolicLinkObject, (HANDLE *handle, ACCESS_MASK access, const OBJECT_ATTRIBUTES *attr))
DEFINE_SYSCALL(NtOpenThread, (HANDLE *handle, ACCESS_MASK access, const OBJECT_ATTRIBUTES *attr, const CLIENT_ID *id))
DEFINE_SYSCALL(NtOpenThreadToken, (HANDLE thread, DWORD access, BOOLEAN self, HANDLE *handle))
DEFINE_SYSCALL(NtOpenThreadTokenEx, (HANDLE thread, DWORD access, BOOLEAN self, DWORD attributes, HANDLE *handle))
DEFINE_SYSCALL(NtOpenTimer, (HANDLE *handle, ACCESS_MASK access, const OBJECT_ATTRIBUTES *attr))
DEFINE_SYSCALL(NtPowerInformation, (POWER_INFORMATION_LEVEL level, void *input, ULONG in_size, void *output, ULONG out_size))
DEFINE_SYSCALL(NtPrivilegeCheck, (HANDLE token, PRIVILEGE_SET *privs, BOOLEAN *res))
DEFINE_WRAPPED_SYSCALL(NtProtectVirtualMemory, (HANDLE process, PVOID *addr_ptr, SIZE_T *size_ptr, ULONG new_prot, ULONG *old_prot))
DEFINE_SYSCALL(NtPulseEvent, (HANDLE handle, LONG *prev_state))
DEFINE_SYSCALL(NtQueryAttributesFile, (const OBJECT_ATTRIBUTES *attr, FILE_BASIC_INFORMATION *info))
DEFINE_SYSCALL(NtQueryDefaultLocale, (BOOLEAN user, LCID *lcid))
DEFINE_SYSCALL(NtQueryDefaultUILanguage, (LANGID *lang))
DEFINE_SYSCALL(NtQueryDirectoryFile, (HANDLE handle, HANDLE event, PIO_APC_ROUTINE apc_routine, void *apc_context, IO_STATUS_BLOCK *io, void *buffer, ULONG length, FILE_INFORMATION_CLASS info_class, BOOLEAN single_entry, UNICODE_STRING *mask, BOOLEAN restart_scan))
DEFINE_SYSCALL(NtQueryDirectoryObject, (HANDLE handle, DIRECTORY_BASIC_INFORMATION *buffer, ULONG size, BOOLEAN single_entry, BOOLEAN restart, ULONG *context, ULONG *ret_size))
DEFINE_SYSCALL(NtQueryEaFile, (HANDLE handle, IO_STATUS_BLOCK *io, void *buffer, ULONG length, BOOLEAN single_entry, void *list, ULONG list_len, ULONG *index, BOOLEAN restart))
DEFINE_SYSCALL(NtQueryEvent, (HANDLE handle, EVENT_INFORMATION_CLASS class, void *info, ULONG len, ULONG *ret_len))
DEFINE_SYSCALL(NtQueryFullAttributesFile, (const OBJECT_ATTRIBUTES *attr, FILE_NETWORK_OPEN_INFORMATION *info))
DEFINE_SYSCALL(NtQueryInformationAtom, (RTL_ATOM atom, ATOM_INFORMATION_CLASS class, void *ptr, ULONG size, ULONG *retsize))
DEFINE_SYSCALL(NtQueryInformationFile, (HANDLE handle, IO_STATUS_BLOCK *io, void *ptr, ULONG len, FILE_INFORMATION_CLASS class))
DEFINE_SYSCALL(NtQueryInformationJobObject, (HANDLE handle, JOBOBJECTINFOCLASS class, void *info, ULONG len, ULONG *ret_len))
DEFINE_SYSCALL(NtQueryInformationProcess, (HANDLE handle, PROCESSINFOCLASS class, void *info, ULONG size, ULONG *ret_len))
DEFINE_SYSCALL(NtQueryInformationThread, (HANDLE handle, THREADINFOCLASS class, void *data, ULONG length, ULONG *ret_len))
DEFINE_SYSCALL(NtQueryInformationToken, (HANDLE token, TOKEN_INFORMATION_CLASS class, void *info, ULONG length, ULONG *retlen))
DEFINE_SYSCALL(NtQueryInstallUILanguage, (LANGID *lang))
DEFINE_SYSCALL(NtQueryIoCompletion, (HANDLE handle, IO_COMPLETION_INFORMATION_CLASS class, void *buffer, ULONG len, ULONG *ret_len))
DEFINE_SYSCALL(NtQueryKey, (HANDLE handle, KEY_INFORMATION_CLASS info_class, void *info, DWORD length, DWORD *result_len))
DEFINE_SYSCALL(NtQueryLicenseValue, (const UNICODE_STRING *name, ULONG *type, void *data, ULONG length, ULONG *retlen))
DEFINE_SYSCALL(NtQueryMultipleValueKey, (HANDLE key, KEY_MULTIPLE_VALUE_INFORMATION *info, ULONG count, void *buffer, ULONG length, ULONG *retlen))
DEFINE_SYSCALL(NtQueryMutant, (HANDLE handle, MUTANT_INFORMATION_CLASS class, void *info, ULONG len, ULONG *ret_len))
DEFINE_SYSCALL(NtQueryObject, (HANDLE handle, OBJECT_INFORMATION_CLASS info_class, void *ptr, ULONG len, ULONG *used_len))
DEFINE_SYSCALL(NtQueryPerformanceCounter, (LARGE_INTEGER *counter, LARGE_INTEGER *frequency))
DEFINE_SYSCALL(NtQuerySection, (HANDLE handle, SECTION_INFORMATION_CLASS class, void *ptr, SIZE_T size, SIZE_T *ret_size))
DEFINE_SYSCALL(NtQuerySecurityObject, (HANDLE handle, SECURITY_INFORMATION info, PSECURITY_DESCRIPTOR descr, ULONG length, ULONG *retlen))
DEFINE_SYSCALL(NtQuerySemaphore, (HANDLE handle, SEMAPHORE_INFORMATION_CLASS class, void *info, ULONG len, ULONG *ret_len))
DEFINE_SYSCALL(NtQuerySymbolicLinkObject, (HANDLE handle, UNICODE_STRING *target, ULONG *length))
DEFINE_SYSCALL(NtQuerySystemEnvironmentValue, (UNICODE_STRING *name, WCHAR *buffer, ULONG length, ULONG *retlen))
DEFINE_SYSCALL(NtQuerySystemEnvironmentValueEx, (UNICODE_STRING *name, GUID *vendor, void *buffer, ULONG *retlen, ULONG *attrib))
DEFINE_WRAPPED_SYSCALL(NtQuerySystemInformation, (SYSTEM_INFORMATION_CLASS class, void *info, ULONG size, ULONG *ret_size))
DEFINE_SYSCALL(NtQuerySystemInformationEx, (SYSTEM_INFORMATION_CLASS class, void *query, ULONG query_len, void *info, ULONG size, ULONG *ret_size))
DEFINE_SYSCALL(NtQuerySystemTime, (LARGE_INTEGER *time))
DEFINE_SYSCALL(NtQueryTimer, (HANDLE handle, TIMER_INFORMATION_CLASS class, void *info, ULONG len, ULONG *ret_len))
DEFINE_SYSCALL(NtQueryTimerResolution, (ULONG *min_res, ULONG *max_res, ULONG *current_res))
DEFINE_SYSCALL(NtQueryValueKey, (HANDLE handle, const UNICODE_STRING *name, KEY_VALUE_INFORMATION_CLASS info_class, void *info, DWORD length, DWORD *result_len))
DEFINE_SYSCALL(NtQueryVirtualMemory, (HANDLE process, LPCVOID addr, MEMORY_INFORMATION_CLASS info_class, PVOID buffer, SIZE_T len, SIZE_T *res_len))
DEFINE_SYSCALL(NtQueryVolumeInformationFile, (HANDLE handle, IO_STATUS_BLOCK *io, void *buffer, ULONG length, FS_INFORMATION_CLASS info_class))
DEFINE_SYSCALL(NtQueueApcThread, (HANDLE handle, PNTAPCFUNC func, ULONG_PTR arg1, ULONG_PTR arg2, ULONG_PTR arg3))
DEFINE_SYSCALL(NtQueueApcThreadEx, (HANDLE handle, HANDLE reserve_handle, PNTAPCFUNC func, ULONG_PTR arg1, ULONG_PTR arg2, ULONG_PTR arg3))
DEFINE_SYSCALL(NtQueueApcThreadEx2, (HANDLE handle, HANDLE reserve_handle, ULONG flags, PNTAPCFUNC func, ULONG_PTR arg1, ULONG_PTR arg2, ULONG_PTR arg3))
DEFINE_WRAPPED_SYSCALL(NtRaiseException, (EXCEPTION_RECORD *rec, ARM64_NT_CONTEXT *context, BOOL first_chance))
DEFINE_SYSCALL(NtRaiseHardError, (NTSTATUS status, ULONG count, ULONG params_mask, void **params, HARDERROR_RESPONSE_OPTION option, HARDERROR_RESPONSE *response))
DEFINE_WRAPPED_SYSCALL(NtReadFile, (HANDLE handle, HANDLE event, PIO_APC_ROUTINE apc, void *apc_user, IO_STATUS_BLOCK *io, void *buffer, ULONG length, LARGE_INTEGER *offset, ULONG *key))
DEFINE_SYSCALL(NtReadFileScatter, (HANDLE file, HANDLE event, PIO_APC_ROUTINE apc, void *apc_user, IO_STATUS_BLOCK *io, FILE_SEGMENT_ELEMENT *segments, ULONG length, LARGE_INTEGER *offset, ULONG *key))
DEFINE_SYSCALL(NtReadRequestData, (HANDLE handle, LPC_MESSAGE *request, ULONG id, void *buffer, ULONG len, ULONG *retlen))
DEFINE_SYSCALL(NtReadVirtualMemory, (HANDLE process, const void *addr, void *buffer, SIZE_T size, SIZE_T *bytes_read))
DEFINE_SYSCALL(NtRegisterThreadTerminatePort, (HANDLE handle))
DEFINE_SYSCALL(NtReleaseKeyedEvent, (HANDLE handle, const void *key, BOOLEAN alertable, const LARGE_INTEGER *timeout))
DEFINE_WRAPPED_SYSCALL(NtReleaseMutant, (HANDLE handle, LONG *prev_count))
DEFINE_SYSCALL(NtReleaseSemaphore, (HANDLE handle, ULONG count, ULONG *previous))
DEFINE_SYSCALL(NtRemoveIoCompletion, (HANDLE handle, ULONG_PTR *key, ULONG_PTR *value, IO_STATUS_BLOCK *io, LARGE_INTEGER *timeout))
DEFINE_SYSCALL(NtRemoveIoCompletionEx, (HANDLE handle, FILE_IO_COMPLETION_INFORMATION *info, ULONG count, ULONG *written, LARGE_INTEGER *timeout, BOOLEAN alertable))
DEFINE_SYSCALL(NtRemoveProcessDebug, (HANDLE process, HANDLE debug))
DEFINE_SYSCALL(NtRenameKey, (HANDLE key, UNICODE_STRING *name))
DEFINE_SYSCALL(NtReplaceKey, (OBJECT_ATTRIBUTES *attr, HANDLE key, OBJECT_ATTRIBUTES *replace))
DEFINE_SYSCALL(NtReplyPort, (HANDLE handle, LPC_MESSAGE *reply))
DEFINE_SYSCALL(NtReplyWaitReceivePort, (HANDLE handle, ULONG *id, LPC_MESSAGE *reply, LPC_MESSAGE *msg))
DEFINE_SYSCALL(NtReplyWaitReceivePortEx, (HANDLE handle, ULONG *id, LPC_MESSAGE *reply, LPC_MESSAGE *msg, LARGE_INTEGER *timeout))
DEFINE_SYSCALL(NtRequestWaitReplyPort, (HANDLE handle, LPC_MESSAGE *msg_in, LPC_MESSAGE *msg_out))
DEFINE_SYSCALL(NtResetEvent, (HANDLE handle, LONG *prev_state))
DEFINE_SYSCALL(NtResetWriteWatch, (HANDLE process, PVOID base, SIZE_T size))
DEFINE_SYSCALL(NtRestoreKey, (HANDLE key, HANDLE file, ULONG flags))
DEFINE_SYSCALL(NtResumeProcess, (HANDLE handle))
DEFINE_SYSCALL(NtResumeThread, (HANDLE handle, ULONG *count))
DEFINE_SYSCALL(NtRollbackTransaction, (HANDLE transaction, BOOLEAN wait))
DEFINE_SYSCALL(NtSaveKey, (HANDLE key, HANDLE file))
DEFINE_SYSCALL(NtSecureConnectPort, (HANDLE *handle, UNICODE_STRING *name, SECURITY_QUALITY_OF_SERVICE *qos, LPC_SECTION_WRITE *write, PSID sid, LPC_SECTION_READ *read, ULONG *max_len, void *info, ULONG *info_len))
DEFINE_WRAPPED_SYSCALL(NtSetContextThread, (HANDLE handle, const ARM64_NT_CONTEXT *context))
DEFINE_SYSCALL(NtSetDebugFilterState, (ULONG component_id, ULONG level, BOOLEAN state))
DEFINE_SYSCALL(NtSetDefaultLocale, (BOOLEAN user, LCID lcid))
DEFINE_SYSCALL(NtSetDefaultUILanguage, (LANGID lang))
DEFINE_SYSCALL(NtSetEaFile, (HANDLE handle, IO_STATUS_BLOCK *io, void *buffer, ULONG length))
DEFINE_WRAPPED_SYSCALL(NtSetEvent, (HANDLE handle, LONG *prev_state))
DEFINE_SYSCALL(NtSetEventBoostPriority, (HANDLE handle))
DEFINE_SYSCALL(NtSetInformationDebugObject, (HANDLE handle, DEBUGOBJECTINFOCLASS class, void *info, ULONG len, ULONG *ret_len))
DEFINE_SYSCALL(NtSetInformationFile, (HANDLE handle, IO_STATUS_BLOCK *io, void *ptr, ULONG len, FILE_INFORMATION_CLASS class))
DEFINE_SYSCALL(NtSetInformationJobObject, (HANDLE handle, JOBOBJECTINFOCLASS class, void *info, ULONG len))
DEFINE_SYSCALL(NtSetInformationKey, (HANDLE key, int class, void *info, ULONG length))
DEFINE_SYSCALL(NtSetInformationObject, (HANDLE handle, OBJECT_INFORMATION_CLASS info_class, void *ptr, ULONG len))
DEFINE_SYSCALL(NtSetInformationProcess, (HANDLE handle, PROCESSINFOCLASS class, void *info, ULONG size))
DEFINE_SYSCALL(NtSetInformationThread, (HANDLE handle, THREADINFOCLASS class, const void *data, ULONG length))
DEFINE_SYSCALL(NtSetInformationToken, (HANDLE token, TOKEN_INFORMATION_CLASS class, void *info, ULONG length))
DEFINE_SYSCALL(NtSetInformationVirtualMemory, (HANDLE process, VIRTUAL_MEMORY_INFORMATION_CLASS info_class, ULONG_PTR count, PMEMORY_RANGE_ENTRY addresses, PVOID ptr, ULONG size))
DEFINE_SYSCALL(NtSetIntervalProfile, (ULONG interval, KPROFILE_SOURCE source))
DEFINE_SYSCALL(NtSetIoCompletion, (HANDLE handle, ULONG_PTR key, ULONG_PTR value, NTSTATUS status, SIZE_T count))
DEFINE_SYSCALL(NtSetIoCompletionEx, (HANDLE completion_handle, HANDLE completion_reserve_handle, ULONG_PTR key, ULONG_PTR value, NTSTATUS status, SIZE_T count))
DEFINE_SYSCALL(NtSetLdtEntries, (ULONG sel1, ULONG entry1_low, ULONG entry1_high, ULONG sel2, ULONG entry2_low, ULONG entry2_high))
DEFINE_SYSCALL(NtSetSecurityObject, (HANDLE handle, SECURITY_INFORMATION info, PSECURITY_DESCRIPTOR descr))
DEFINE_SYSCALL(NtSetSystemInformation, (SYSTEM_INFORMATION_CLASS class, void *info, ULONG length))
DEFINE_SYSCALL(NtSetSystemTime, (const LARGE_INTEGER *new, LARGE_INTEGER *old))
DEFINE_SYSCALL(NtSetThreadExecutionState, (EXECUTION_STATE new_state, EXECUTION_STATE *old_state))
DEFINE_SYSCALL(NtSetTimer, (HANDLE handle, const LARGE_INTEGER *when, PTIMER_APC_ROUTINE callback, void *arg, BOOLEAN resume, ULONG period, BOOLEAN *state))
DEFINE_SYSCALL(NtSetTimerResolution, (ULONG res, BOOLEAN set, ULONG *current_res))
DEFINE_SYSCALL(NtSetValueKey, (HANDLE key, const UNICODE_STRING *name, ULONG index, ULONG type, const void *data, ULONG count))
DEFINE_SYSCALL(NtSetVolumeInformationFile, (HANDLE handle, IO_STATUS_BLOCK *io, void *info, ULONG length, FS_INFORMATION_CLASS class))
DEFINE_SYSCALL(NtShutdownSystem, (SHUTDOWN_ACTION action))
DEFINE_SYSCALL(NtSignalAndWaitForSingleObject, (HANDLE signal, HANDLE wait, BOOLEAN alertable, const LARGE_INTEGER *timeout))
DEFINE_SYSCALL(NtSuspendProcess, (HANDLE handle))
DEFINE_SYSCALL(NtSuspendThread, (HANDLE handle, ULONG *count))
DEFINE_SYSCALL(NtSystemDebugControl, (SYSDBG_COMMAND command, void *in_buff, ULONG in_len, void *out_buff, ULONG out_len, ULONG *retlen))
DEFINE_SYSCALL(NtTerminateJobObject, (HANDLE handle, NTSTATUS status))
DEFINE_WRAPPED_SYSCALL(NtTerminateProcess, (HANDLE handle, LONG exit_code))
DEFINE_WRAPPED_SYSCALL(NtTerminateThread, (HANDLE handle, LONG exit_code))
DEFINE_SYSCALL(NtTestAlert, (void))
DEFINE_SYSCALL(NtTraceControl, (ULONG code, void *inbuf, ULONG inbuf_len, void *outbuf, ULONG outbuf_len, ULONG *size))
DEFINE_SYSCALL(NtTraceEvent, (HANDLE handle, ULONG flags, ULONG size, void *data))
DEFINE_SYSCALL(NtUnloadDriver, (const UNICODE_STRING *name))
DEFINE_SYSCALL(NtUnloadKey, (OBJECT_ATTRIBUTES *attr))
DEFINE_SYSCALL(NtUnlockFile, (HANDLE handle, IO_STATUS_BLOCK *io_status, LARGE_INTEGER *offset, LARGE_INTEGER *count, ULONG *key))
DEFINE_SYSCALL(NtUnlockVirtualMemory, (HANDLE process, PVOID *addr, SIZE_T *size, ULONG unknown))
DEFINE_WRAPPED_SYSCALL(NtUnmapViewOfSection, (HANDLE process, PVOID addr))
DEFINE_WRAPPED_SYSCALL(NtUnmapViewOfSectionEx, (HANDLE process, PVOID addr, ULONG flags))
DEFINE_WRAPPED_SYSCALL(NtWaitForAlertByThreadId, (const void *address, const LARGE_INTEGER *timeout))
DEFINE_SYSCALL(NtWaitForDebugEvent, (HANDLE handle, BOOLEAN alertable, LARGE_INTEGER *timeout, DBGUI_WAIT_STATE_CHANGE *state))
DEFINE_SYSCALL(NtWaitForKeyedEvent, (HANDLE handle, const void *key, BOOLEAN alertable, const LARGE_INTEGER *timeout))
DEFINE_WRAPPED_SYSCALL(NtWaitForMultipleObjects, (DWORD count, const HANDLE *handles, WAIT_TYPE type, BOOLEAN alertable, const LARGE_INTEGER *timeout))
DEFINE_SYSCALL(NtWaitForMultipleObjects32, (ULONG count, LONG *handles, WAIT_TYPE type, BOOLEAN alertable, const LARGE_INTEGER *timeout))
DEFINE_WRAPPED_SYSCALL(NtWaitForSingleObject, (HANDLE handle, BOOLEAN alertable, const LARGE_INTEGER *timeout))
DEFINE_SYSCALL(NtWorkerFactoryWorkerReady, (HANDLE handle))
DEFINE_SYSCALL(NtWriteFile, (HANDLE handle, HANDLE event, PIO_APC_ROUTINE apc, void *apc_user, IO_STATUS_BLOCK *io, const void *buffer, ULONG length, LARGE_INTEGER *offset, ULONG *key))
DEFINE_SYSCALL(NtWriteFileGather, (HANDLE file, HANDLE event, PIO_APC_ROUTINE apc, void *apc_user, IO_STATUS_BLOCK *io, FILE_SEGMENT_ELEMENT *segments, ULONG length, LARGE_INTEGER *offset, ULONG *key))
DEFINE_SYSCALL(NtWriteRequestData, (HANDLE handle, LPC_MESSAGE *request, ULONG id, void *buffer, ULONG len, ULONG *retlen))
DEFINE_SYSCALL(NtWriteVirtualMemory, (HANDLE process, void *addr, const void *buffer, SIZE_T size, SIZE_T *bytes_written))
DEFINE_WRAPPED_SYSCALL(NtYieldExecution, (void))

NTSTATUS SYSCALL_API NtAllocateVirtualMemory( HANDLE process, PVOID *ret, ULONG_PTR zero_bits,
                                              SIZE_T *size_ptr, ULONG type, ULONG protect )
{
    BOOL is_current = RtlIsCurrentProcess( process );
    NTSTATUS status;

    if (!enter_syscall_callback())
        return syscall_NtAllocateVirtualMemory( process, ret, zero_bits, size_ptr, type, protect );

    if (!*ret && (type & MEM_COMMIT)) type |= MEM_RESERVE;

    if (!is_current) send_cross_process_notification( process, CrossProcessPreVirtualAlloc,
                                                      *ret, *size_ptr, 3, type, protect, 0 );
    else if (pNotifyMemoryAlloc) pNotifyMemoryAlloc( *ret, *size_ptr, type, protect, FALSE, 0 );

    status = syscall_NtAllocateVirtualMemory( process, ret, zero_bits, size_ptr, type, protect );

    if (!is_current) send_cross_process_notification( process, CrossProcessPostVirtualAlloc,
                                                      *ret, *size_ptr, 3, type, protect, status );
    else if (pNotifyMemoryAlloc) pNotifyMemoryAlloc( *ret, *size_ptr, type, protect, TRUE, status );

    /* ml387 probe: each new guest thread costs 2x128MB of un-named
     * reserve-only VA ([guest-reserve] census) and the guest band hit 38MB
     * free. Name the owner: ret= is the PE caller for wine/FEX-PE callers or
     * the FEX syscall stub for guest x86 callers; ZERO hits while the unix
     * census still grows means the reserves are FEX host-side (unixlib). */
    if (is_current && !status && (type & MEM_RESERVE) && !(type & MEM_COMMIT) && *size_ptr >= 0x4000000)
    {
        static ULONG big_n;
        if (big_n < 24)
        {
            big_n++;
            ERR( "[big-reserve] addr=%p size=%Ix type=%lx prot=%lx ret=%p\n",
                 *ret, *size_ptr, type, protect, __builtin_return_address(0) );
        }
    }

    leave_syscall_callback();
    return status;
}

NTSTATUS SYSCALL_API NtAllocateVirtualMemoryEx( HANDLE process, PVOID *ret, SIZE_T *size_ptr, ULONG type,
                                                ULONG protect, MEM_EXTENDED_PARAMETER *parameters, ULONG count )
{
    BOOL is_current = RtlIsCurrentProcess( process );
    NTSTATUS status;

    if (!enter_syscall_callback())
        return syscall_NtAllocateVirtualMemoryEx( process, ret, size_ptr, type, protect, parameters, count );

    if (!*ret && (type & MEM_COMMIT)) type |= MEM_RESERVE;

    if (!is_current) send_cross_process_notification( process, CrossProcessPreVirtualAlloc,
                                                      *ret, *size_ptr, 3, type, protect, 0 );
    else if (pNotifyMemoryAlloc) pNotifyMemoryAlloc( *ret, *size_ptr, type, protect, FALSE, 0 );

    status = syscall_NtAllocateVirtualMemoryEx( process, ret, size_ptr, type, protect, parameters, count );

    if (!is_current) send_cross_process_notification( process, CrossProcessPostVirtualAlloc,
                                                      *ret, *size_ptr, 3, type, protect, status );
    else if (pNotifyMemoryAlloc) pNotifyMemoryAlloc( *ret, *size_ptr, type, protect, TRUE, status );

    leave_syscall_callback();
    return status;
}

NTSTATUS SYSCALL_API NtContinue( CONTEXT *context, BOOLEAN alertable )
{
    ARM64_NT_CONTEXT arm_ctx;

    context_x64_to_arm( &arm_ctx, (ARM64EC_NT_CONTEXT *)context );
    return syscall_NtContinue( &arm_ctx, alertable );
}

NTSTATUS SYSCALL_API NtContinueEx( CONTEXT *context, KCONTINUE_ARGUMENT *args )
{
    ARM64_NT_CONTEXT arm_ctx;

    context_x64_to_arm( &arm_ctx, (ARM64EC_NT_CONTEXT *)context );
    return syscall_NtContinueEx( &arm_ctx, args );
}

NTSTATUS SYSCALL_API NtFlushInstructionCache( HANDLE process, const void *addr, SIZE_T size )
{
    NTSTATUS status = syscall_NtFlushInstructionCache( process, addr, size );

    if (!status && enter_syscall_callback())
    {
        if (!RtlIsCurrentProcess( process ))
            send_cross_process_notification( process, CrossProcessFlushCache, addr, size, 0 );
        else if (pBTCpu64FlushInstructionCache)
            pBTCpu64FlushInstructionCache( addr, size );
        leave_syscall_callback();
    }
    return status;
}

NTSTATUS SYSCALL_API NtDeviceIoControlFile( HANDLE handle, HANDLE event, PIO_APC_ROUTINE apc,
                                            void *apc_context, IO_STATUS_BLOCK *io, ULONG code,
                                            void *in_buffer, ULONG in_size, void *out_buffer,
                                            ULONG out_size )
{
    /* ml388 (task #66): three runs died writing the IO_STATUS_BLOCK from the
     * unix side of THIS syscall — NULL (ml385: server_ioctl_file `stp` through
     * x9=0), pool-band garbage (ml386), and misaligned 0x7200000103 (ml388:
     * set_async_direct_result <- sock_send, a BUS not a SEGV, which is what
     * gives the family away: the pointer is not merely unmapped, it is
     * MALFORMED). wine writes into it unconditionally (set_sync_iosb), so a
     * malformed one is an unrecoverable native fault mid-pseudo-process.
     *
     * Reject cheaply — this is the hot socket path (every AFD send/recv), so
     * NO SEH probe and no NtQueryVirtualMemory here: an IO_STATUS_BLOCK is
     * pointer-aligned by contract, and both observed bad values fail that in
     * one AND. Returning a status keeps the pseudo-process alive and the
     * [iosb-guard] line names the caller so the corruption source can be
     * chased offline. */
    if (!io || ((ULONG_PTR)io & (sizeof(void *) - 1)) || (ULONG_PTR)io >= 0x8000000000ull)
    {
        static ULONG bogus_n;
        if (bogus_n < 16)
        {
            bogus_n++;
            ERR( "[iosb-guard] #%lu MALFORMED iosb %p (handle=%p code=%lx in=%p/%lu out=%p/%lu "
                 "ret=%p) — failing the call instead of faulting unix-side\n",
                 bogus_n, io, handle, code, in_buffer, in_size, out_buffer, out_size,
                 __builtin_return_address(0) );
        }
        return STATUS_ACCESS_VIOLATION;
    }
    return syscall_NtDeviceIoControlFile( handle, event, apc, apc_context, io, code,
                                          in_buffer, in_size, out_buffer, out_size );
}

/* ml392 (task #60): SteamChrome named-object sniffer.  Section sharing is
 * fixed ([sec-test] MATCH) yet the webhelper-init hello still never reaches
 * CSteamUISharedJSController.  The handshake objects are known by name
 * (SteamChrome_MasterStream_spid%u / _Event_spid%u / _mutex / ClientStream);
 * log every create/open touching them, with result status, so the next run
 * maps the topology: who created what, whose open failed, where the chain
 * stops.  Substring match over a non-terminated UNICODE_STRING. */
static BOOL ios_name_is_steamchrome( const OBJECT_ATTRIBUTES *attr )
{
    const WCHAR *p;
    static const WCHAR key[] = {'S','t','e','a','m','C','h','r','o','m','e'};
    ULONG i, n;

    if (!attr || !attr->ObjectName || !attr->ObjectName->Buffer) return FALSE;
    p = attr->ObjectName->Buffer;
    n = attr->ObjectName->Length / sizeof(WCHAR);
    if (n < ARRAY_SIZE(key)) return FALSE;
    for (i = 0; i + ARRAY_SIZE(key) <= n; i++)
        if (!memcmp( p + i, key, sizeof(key) )) return TRUE;
    return FALSE;
}

/* ml394: data-plane tracking.  Creates/opens all succeed and steam retries
 * its client-connect 4x — the break is now in the signal/wait/read ping-pong.
 * Track SteamChrome handles at create/open, then log Set/Wait/Release/Close
 * ops on them (rate-limited).  Table is per-process (EC ntdll data is a
 * per-pseudo-process copy); races with the probe are tolerable. */
#define IOS_CHROME_HANDLES 64
static struct { HANDLE h; void *view; char tag[40]; } ios_chrome_handles[IOS_CHROME_HANDLES];
static LONG ios_chrome_handle_count;

static void ios_chrome_track( HANDLE h, const OBJECT_ATTRIBUTES *attr )
{
    int i, j, n;
    const WCHAR *p;
    LONG idx;

    if (!h) return;
    p = attr->ObjectName->Buffer;
    n = attr->ObjectName->Length / sizeof(WCHAR);
    for (i = 0; i < ios_chrome_handle_count && i < IOS_CHROME_HANDLES; i++)
        if (ios_chrome_handles[i].h == h) break;
    if (i >= IOS_CHROME_HANDLES) return;
    if (i == ios_chrome_handle_count)
    {
        idx = InterlockedIncrement( &ios_chrome_handle_count ) - 1;
        if (idx >= IOS_CHROME_HANDLES) return;
        i = idx;
    }
    /* keep the tail of the name (the distinctive part), narrowed */
    j = n > 38 ? n - 38 : 0;
    for (n = 0; j + n < (int)(attr->ObjectName->Length / sizeof(WCHAR)) && n < 38; n++)
        ios_chrome_handles[i].tag[n] = (char)p[j + n];
    ios_chrome_handles[i].tag[n] = 0;
    ios_chrome_handles[i].h = h;
}

static const char *ios_chrome_lookup( HANDLE h )
{
    int i;
    if (!ios_chrome_handle_count) return NULL;
    for (i = 0; i < ios_chrome_handle_count && i < IOS_CHROME_HANDLES; i++)
        if (ios_chrome_handles[i].h == h) return ios_chrome_handles[i].tag;
    return NULL;
}

/* ml398 (task #60, last hop): pump wakes on MasterStream_Event but never
 * replies and never re-waits.  Leading hypothesis: steam's hello write into
 * the master _mem never becomes visible through webhelper's view (the one
 * sharing direction [sec-test] never exercised).  Record where each tracked
 * SteamChrome section gets mapped, then hex-dump the first 64 bytes of every
 * "_mem" view at the three decisive moments: steam SetEvent(_written)
 * [what steam wrote], pump Wait1(Stream_Event)==0 [what webhelper sees],
 * steam Wait1(_written)==0x102 [is the hello still there at timeout].
 * Reads go through NtReadVirtualMemory so a stale view can't fault the
 * observed thread. */
static void ios_chrome_set_view( HANDLE h, void *base )
{
    int i;
    for (i = 0; i < ios_chrome_handle_count && i < IOS_CHROME_HANDLES; i++)
        if (ios_chrome_handles[i].h == h)
        {
            ios_chrome_handles[i].view = base;
            ERR( "[chrome-ipc] MapView %s base=%p\n", ios_chrome_handles[i].tag, base );
            return;
        }
}

static void ios_chrome_clear_view( void *base )
{
    int i;
    if (!base || !ios_chrome_handle_count) return;
    for (i = 0; i < ios_chrome_handle_count && i < IOS_CHROME_HANDLES; i++)
        if (ios_chrome_handles[i].view == base)
        {
            ERR( "[chrome-ipc] Unmap %s base=%p\n", ios_chrome_handles[i].tag, base );
            ios_chrome_handles[i].view = NULL;
        }
}

static const char *ios_strstr( const char *s, const char *sub )
{
    int i, j;
    for (i = 0; s[i]; i++)
    {
        for (j = 0; sub[j] && s[i + j] == sub[j]; j++) ;
        if (!sub[j]) return s + i;
    }
    return NULL;
}

static void ios_chrome_dump_views( const char *when )
{
    int i;
    static LONG dumps;
    if (dumps >= 64) return;
    for (i = 0; i < ios_chrome_handle_count && i < IOS_CHROME_HANDLES; i++)
    {
        ULONGLONG buf[8] = { 0 };
        SIZE_T got = 0;
        NTSTATUS st;
        if (!ios_chrome_handles[i].h || !ios_chrome_handles[i].view) continue;
        if (!ios_strstr( ios_chrome_handles[i].tag, "_mem" )) continue;
        if (InterlockedIncrement( &dumps ) > 64) return;
        st = NtReadVirtualMemory( GetCurrentProcess(), ios_chrome_handles[i].view, buf, sizeof(buf), &got );
        ERR( "[chrome-mem] %s %s @%p st=%lx: %016llx %016llx %016llx %016llx %016llx %016llx %016llx %016llx\n",
             when, ios_chrome_handles[i].tag, ios_chrome_handles[i].view, (ULONG)st,
             buf[0], buf[1], buf[2], buf[3], buf[4], buf[5], buf[6], buf[7] );
    }
}

#define SNIFF_STEAMCHROME(op, attr, status, handle_ptr) \
    do { if (ios_name_is_steamchrome( attr )) { \
        ERR( "[chrome-ipc] %s %s -> status=%lx handle=%p\n", op, \
             debugstr_us( (attr)->ObjectName ), (ULONG)(status), \
             (handle_ptr) ? *(handle_ptr) : NULL ); \
        if (!(status & 0x80000000) && (handle_ptr)) ios_chrome_track( *(handle_ptr), attr ); \
    } } while (0)

NTSTATUS SYSCALL_API NtCreateEvent( HANDLE *handle, ACCESS_MASK access, const OBJECT_ATTRIBUTES *attr,
                                    EVENT_TYPE type, BOOLEAN state )
{
    NTSTATUS status = syscall_NtCreateEvent( handle, access, attr, type, state );
    SNIFF_STEAMCHROME( "CreateEvent", attr, status, handle );
    /* ml399: the server thread stalled BEFORE its first park (last line =
     * this very CreateEvent), so the pump-wake beacon never armed.  Stamp the
     * CREATOR of the master event (status 0 = created, not opened-existing)
     * so [pump-sample] covers it from birth. */
    if (status == 0 && handle)
    {
        const char *tag = ios_chrome_lookup( *handle );
        if (tag && ios_strstr( tag, "Stream_Event" ))
        {
            NtCurrentTeb()->Instrumentation[10] = (void *)(ULONG_PTR)0x504d5550; /* 'PUMP' */
            ERR( "[pump-op] beacon armed on creator of %s\n", tag );
        }
    }
    return status;
}

NTSTATUS SYSCALL_API NtOpenEvent( HANDLE *handle, ACCESS_MASK access, const OBJECT_ATTRIBUTES *attr )
{
    NTSTATUS status = syscall_NtOpenEvent( handle, access, attr );
    SNIFF_STEAMCHROME( "OpenEvent", attr, status, handle );
    return status;
}

NTSTATUS SYSCALL_API NtCreateMutant( HANDLE *handle, ACCESS_MASK access, const OBJECT_ATTRIBUTES *attr,
                                     BOOLEAN owned )
{
    NTSTATUS status = syscall_NtCreateMutant( handle, access, attr, owned );
    SNIFF_STEAMCHROME( "CreateMutant", attr, status, handle );
    return status;
}

NTSTATUS SYSCALL_API NtOpenMutant( HANDLE *handle, ACCESS_MASK access, const OBJECT_ATTRIBUTES *attr )
{
    NTSTATUS status = syscall_NtOpenMutant( handle, access, attr );
    SNIFF_STEAMCHROME( "OpenMutant", attr, status, handle );
    return status;
}

NTSTATUS SYSCALL_API NtCreateSection( HANDLE *handle, ACCESS_MASK access, const OBJECT_ATTRIBUTES *attr,
                                      const LARGE_INTEGER *size, ULONG protect, ULONG sec_flags,
                                      HANDLE file )
{
    NTSTATUS status = syscall_NtCreateSection( handle, access, attr, size, protect, sec_flags, file );
    SNIFF_STEAMCHROME( "CreateSection", attr, status, handle );
    return status;
}

NTSTATUS SYSCALL_API NtOpenSection( HANDLE *handle, ACCESS_MASK access, const OBJECT_ATTRIBUTES *attr )
{
    NTSTATUS status = syscall_NtOpenSection( handle, access, attr );
    SNIFF_STEAMCHROME( "OpenSection", attr, status, handle );
    return status;
}

NTSTATUS SYSCALL_API NtSetEvent( HANDLE handle, LONG *prev_state )
{
    NTSTATUS status = syscall_NtSetEvent( handle, prev_state );
    const char *tag = ios_chrome_lookup( handle );
    static LONG n;
    if (tag && n < 200) { InterlockedIncrement( &n );
        ERR( "[chrome-ipc] SetEvent %s -> %lx\n", tag, (ULONG)status ); }
    if (tag && ios_strstr( tag, "_written" )) ios_chrome_dump_views( "set-written" );
    return status;
}

NTSTATUS SYSCALL_API NtReleaseMutant( HANDLE handle, LONG *prev_count )
{
    NTSTATUS status = syscall_NtReleaseMutant( handle, prev_count );
    const char *tag = ios_chrome_lookup( handle );
    static LONG n;
    if (tag && n < 200) { InterlockedIncrement( &n );
        ERR( "[chrome-ipc] ReleaseMutant %s -> %lx\n", tag, (ULONG)status ); }
    return status;
}

NTSTATUS SYSCALL_API NtWaitForSingleObject( HANDLE handle, BOOLEAN alertable, const LARGE_INTEGER *timeout )
{
    const char *tag = ios_chrome_lookup( handle );
    NTSTATUS status;
    static LONG n;
    if (tag && n < 200) { InterlockedIncrement( &n );
        ERR( "[chrome-ipc] Wait1 %s timeout=%s...\n", tag,
             timeout ? wine_dbgstr_longlong( timeout->QuadPart ) : "INF" ); }
    status = syscall_NtWaitForSingleObject( handle, alertable, timeout );
    if (tag && n < 200) { InterlockedIncrement( &n );
        ERR( "[chrome-ipc] Wait1 %s -> %lx\n", tag, (ULONG)status ); }
    if (tag && status == STATUS_SUCCESS && ios_strstr( tag, "Stream_Event" ))
    {
        ios_chrome_dump_views( "pump-wake" );
        /* ml398: beacon for the unix-side [pump-sample] Mach sampler — the
         * pump goes silent after this wake; mark its TEB so the census thread
         * can sample pc/run-state and settle spin vs blocked vs dead. */
        NtCurrentTeb()->Instrumentation[10] = (void *)(ULONG_PTR)0x504d5550; /* 'PUMP' */
    }
    if (tag && status == STATUS_TIMEOUT && ios_strstr( tag, "_written" ))
        ios_chrome_dump_views( "timeout" );
    return status;
}

NTSTATUS SYSCALL_API NtWaitForMultipleObjects( DWORD count, const HANDLE *handles, WAIT_TYPE type,
                                               BOOLEAN alertable, const LARGE_INTEGER *timeout )
{
    NTSTATUS status;
    DWORD i;
    int tracked = -1;
    static LONG n;
    if (ios_chrome_handle_count && handles)
        for (i = 0; i < count && i < 64; i++)
            if (ios_chrome_lookup( handles[i] )) { tracked = i; break; }
    if (tracked >= 0 && n < 200) { InterlockedIncrement( &n );
        ERR( "[chrome-ipc] WaitN count=%lu [%d]=%s timeout=%s...\n", (ULONG)count, tracked,
             ios_chrome_lookup( handles[tracked] ),
             timeout ? wine_dbgstr_longlong( timeout->QuadPart ) : "INF" ); }
    status = syscall_NtWaitForMultipleObjects( count, handles, type, alertable, timeout );
    if (tracked >= 0 && n < 200) { InterlockedIncrement( &n );
        ERR( "[chrome-ipc] WaitN [%d]=%s -> %lx\n", tracked,
             ios_chrome_lookup( handles[tracked] ), (ULONG)status ); }
    return status;
}

/* ml398: once the pump beacon is set, log the wait-family syscalls our
 * handle-tag sniffing can't see (critical sections block in
 * NtWaitForAlertByThreadId; sleeps and yields have no handle at all).  If the
 * silent pump lands in one of these, the log names the blocker. */
#define IOS_PUMP_MARKED() (NtCurrentTeb()->Instrumentation[10] == (void *)(ULONG_PTR)0x504d5550)

NTSTATUS SYSCALL_API NtWaitForAlertByThreadId( const void *address, const LARGE_INTEGER *timeout )
{
    NTSTATUS status;
    static LONG n;
    BOOL marked = IOS_PUMP_MARKED();
    if (marked && n < 40) { InterlockedIncrement( &n );
        ERR( "[pump-op] WaitForAlertByThreadId addr=%p timeout=%s...\n", address,
             timeout ? wine_dbgstr_longlong( timeout->QuadPart ) : "INF" ); }
    status = syscall_NtWaitForAlertByThreadId( address, timeout );
    if (marked && n < 40) { InterlockedIncrement( &n );
        ERR( "[pump-op] WaitForAlertByThreadId -> %lx\n", (ULONG)status ); }
    return status;
}

NTSTATUS SYSCALL_API NtDelayExecution( BOOLEAN alertable, const LARGE_INTEGER *timeout )
{
    static LONG n;
    if (IOS_PUMP_MARKED() && n < 40) { InterlockedIncrement( &n );
        ERR( "[pump-op] DelayExecution timeout=%s\n",
             timeout ? wine_dbgstr_longlong( timeout->QuadPart ) : "INF" ); }
    return syscall_NtDelayExecution( alertable, timeout );
}

NTSTATUS SYSCALL_API NtYieldExecution(void)
{
    static LONG n;
    if (IOS_PUMP_MARKED() && n < 40) { InterlockedIncrement( &n );
        ERR( "[pump-op] YieldExecution\n" ); }
    return syscall_NtYieldExecution();
}

NTSTATUS SYSCALL_API NtClose( HANDLE handle )
{
    if (ios_chrome_handle_count)
    {
        int i;
        for (i = 0; i < ios_chrome_handle_count && i < IOS_CHROME_HANDLES; i++)
            if (ios_chrome_handles[i].h == handle)
            {
                ERR( "[chrome-ipc] Close %s\n", ios_chrome_handles[i].tag );
                ios_chrome_handles[i].h = NULL;
                ios_chrome_handles[i].view = NULL;
                break;
            }
    }
    return syscall_NtClose( handle );
}

NTSTATUS SYSCALL_API NtFreeVirtualMemory( HANDLE process, PVOID *addr_ptr, SIZE_T *size_ptr, ULONG type )
{
    BOOL is_current = RtlIsCurrentProcess( process );
    NTSTATUS status;

    if (!enter_syscall_callback())
        return syscall_NtFreeVirtualMemory( process, addr_ptr, size_ptr, type );

    if (!is_current) send_cross_process_notification( process, CrossProcessPreVirtualFree,
                                                      *addr_ptr, *size_ptr, 2, type, 0 );
    else if (pNotifyMemoryFree) pNotifyMemoryFree( *addr_ptr, *size_ptr, type, FALSE, 0 );

    status = syscall_NtFreeVirtualMemory( process, addr_ptr, size_ptr, type );

    if (!is_current) send_cross_process_notification( process, CrossProcessPostVirtualFree,
                                                      *addr_ptr, *size_ptr, 2, type, status );
    else if (pNotifyMemoryFree) pNotifyMemoryFree( *addr_ptr, *size_ptr, type, TRUE, status );

    /* ml386 probe (task #57): same-region free livelock — CEF calls
     * NtFreeVirtualMemory on ONE 64KB range thousands of times while making no
     * progress (ml364: 5,901x; ml386: 1,787+ and climbing). Discriminate the
     * two possible drivers in one run: (a) our free silently fails (region
     * still committed/reserved after SUCCESS → the caller's retry is sane), or
     * (b) the free works and the caller loops for its own reasons (→ map the
     * host return address to a guest RIP offline via the JIT dump). */
    if (is_current)
    {
        static void *loop_addr;
        static ULONG loop_type, loop_n, loop_prints;
        if (*addr_ptr == loop_addr && type == loop_type)
        {
            loop_n++;
            if (loop_prints < 16 && (loop_n == 8 || (loop_n & 0x3ff) == 0))
            {
                MEMORY_BASIC_INFORMATION mbi = { 0 };
                SIZE_T got = 0;
                NtQueryVirtualMemory( NtCurrentProcess(), *addr_ptr, MemoryBasicInformation,
                                      &mbi, sizeof(mbi), &got );
                loop_prints++;
                ERR( "[free-loop] addr=%p size=%Ix type=%lx status=%lx repeats=%lu ret=%p | "
                     "after: state=%lx protect=%lx region=%p+%Ix\n",
                     *addr_ptr, *size_ptr, type, status, loop_n, __builtin_return_address(0),
                     mbi.State, mbi.Protect, mbi.BaseAddress, mbi.RegionSize );
            }
        }
        else
        {
            loop_addr = *addr_ptr;
            loop_type = type;
            loop_n = 1;
        }
    }

    leave_syscall_callback();
    return status;
}

NTSTATUS SYSCALL_API NtGetContextThread( HANDLE handle, CONTEXT *context )
{
    ARM64_NT_CONTEXT arm_ctx = { .ContextFlags = ctx_flags_x64_to_arm( context->ContextFlags ) };
    NTSTATUS status = syscall_NtGetContextThread( handle, &arm_ctx );

    if (!status) context_arm_to_x64( (ARM64EC_NT_CONTEXT *)context, &arm_ctx );

    /* ml715: WHAT THE CALLER ACTUALLY RECEIVES.
     *
     * This wrapper unconditionally asks for the NATIVE ARM context and converts it, and
     * context_arm_to_x64() maps Pc directly into Rip. That is right only while the target
     * is executing genuine ARM64EC code. If it is parked in FEX JIT, the dispatcher, or
     * plain Mach-O (libsystem_kernel __ulock_wait2), the "x64 RIP" handed back is not an
     * x64 address at all and the integer registers are ARM ABI values reinterpreted --
     * even though the server captured a perfectly good saved AMD64 context at the same
     * instant (see [srv-getctx]).
     *
     * RtlIsEcCode(native_pc) is logged because it is the likely selector for the fix:
     * EC code -> convert the native context; JIT/dispatcher/Mach-O -> return the saved
     * AMD64 context; neither available -> fail rather than manufacture one. InSimulation
     * alone is NOT sufficient, since a translated thread inside a Wine/Mach syscall can
     * have it clear while its correct Windows context is still the saved AMD64 one.
     *
     * Correlate with [srv-getctx] on native_pc (and tid), not on ordering. Capped. */
    {
        static LONG ec_getctx_n;
        LONG n = InterlockedIncrement( &ec_getctx_n );
        if (n <= 48)
        {
            ARM64EC_NT_CONTEXT *ec = (ARM64EC_NT_CONTEXT *)context;
            ERR( "[ec-getctx] ml715 #%d handle=%p status=%08x native_pc=%p is_ec=%d -> "
                 "returned rip=%p rsp=%p flags=%08x\n",
                 (int)n, handle, (unsigned int)status, (void *)arm_ctx.Pc,
                 status ? -1 : (RtlIsEcCode( arm_ctx.Pc ) ? 1 : 0),
                 status ? NULL : (void *)ec->Pc, status ? NULL : (void *)ec->Sp,
                 status ? 0 : (unsigned int)ec->ContextFlags );
        }
    }
    return status;
}

/* iOS-Madeira ml188: SELF-TARGETING FILTER.
 *
 * A global cap is the wrong design when the event of interest is LATE: the ml187/ml188
 * probes burned their whole budget on early loader traffic (unexec #400 at log line 3048)
 * and went blind 2100 lines BEFORE libcef was even mapped (line 5176), so "0 events
 * touching libcef" was a blind spot, not a result.
 *
 * Instead: remember the range of any BIG image as it is mapped (libcef is 0xD3CA000; no
 * Wine DLL comes close), then log protect/unmap events ONLY when they fall inside one.
 * That is immune to ordering and keeps the log small. */
#define IOS_BIGIMG_MAX 4
static struct { ULONG_PTR base, size; } ios_bigimg[IOS_BIGIMG_MAX];
static unsigned ios_bigimg_n;

static void ios_note_big_image( void *addr, SIZE_T size )
{
    if (size < 0x1000000 || ios_bigimg_n >= IOS_BIGIMG_MAX) return;
    ios_bigimg[ios_bigimg_n].base = (ULONG_PTR)addr;
    ios_bigimg[ios_bigimg_n].size = size;
    ios_bigimg_n++;
    ERR( "[bigimg] tracking %p +%p for protect/unmap events\n", addr, (void *)size );
}

static int ios_in_big_image( ULONG_PTR a )
{
    unsigned i;
    for (i = 0; i < ios_bigimg_n; i++)
        if (a >= ios_bigimg[i].base && a < ios_bigimg[i].base + ios_bigimg[i].size) return 1;
    return 0;
}

/* iOS-Madeira ml187: unmap ALSO removes executable intervals
 * (InvalidationTracker::InvalidateContainingSection -> XIntervals.Remove), and this port
 * purges stale image mappings (#33). If libcef's view is unmapped and not re-notified, its
 * .text leaves XIntervals and every later decode there is NOEXEC. Log unmaps in the guest
 * PE band so they can be correlated against libcef's base. */
static void ios_log_unmap( void *addr )
{
    static int unmap_n;
    if (ios_in_big_image( (ULONG_PTR)addr ) && unmap_n < 200)
    {
        unmap_n++;
        ERR( "[unmap] #%d addr=%p\n", unmap_n, addr );
    }
}

static void notify_map_view_of_section( HANDLE handle, void *addr, SIZE_T size, ULONG alloc,
                                        ULONG protect, NTSTATUS *ret_status )
{
    SECTION_IMAGE_INFORMATION info;
    NTSTATUS status;

    /* iOS-Madeira ml184 PROBE. FEX only treats a guest range as executable if
     * InvalidationTracker::XIntervals covers it, and that is populated ONLY from
     * HandleImageMap(), which runs off this notification. A skipped notify means every
     * later decode in that image returns NOEXEC -> NoExecOp -> FAULT_SIGSEGV -> the
     * GuestSignal_SIGSEGV trampoline -> dead thread. libcef.dll+0x1900733 and +0x3b508f0
     * still hit that trampoline after relaxing FEX's own ThreadState guard, so log which
     * of these three gates is dropping it. */
    {
        static int notify_probe;
        if (notify_probe < 40)
        {
            notify_probe++;
            ERR( "[map-notify] addr=%p size=%p alloc=%x prot=%x pfn=%d aup=%p\n",
                 addr, (void *)size, alloc, protect, !!pNotifyMapViewOfSection,
                 NtCurrentTeb()->Tib.ArbitraryUserPointer );
        }
    }
    if (!pNotifyMapViewOfSection) return;
    if (!NtCurrentTeb()->Tib.ArbitraryUserPointer)
    {
        static int skip_aup;
        if (skip_aup < 20)
        { skip_aup++; ERR( "[map-notify] SKIP (no ArbitraryUserPointer) addr=%p size=%p\n", addr, (void *)size ); }
        return;
    }
    if (NtQuerySection( handle, SectionImageInformation, &info, sizeof(info), NULL ))
    {
        static int skip_qs;
        if (skip_qs < 20)
        { skip_qs++; ERR( "[map-notify] SKIP (not an image section) addr=%p size=%p\n", addr, (void *)size ); }
        return;
    }
    ios_note_big_image( addr, size );
    status = pNotifyMapViewOfSection( NULL, addr, NULL, size, alloc, protect );
    if (NT_SUCCESS(status)) return;
    NtUnmapViewOfSection( GetCurrentProcess(), addr );
    *ret_status = status;
}

/* iOS-Madeira ml709: WHICH GATE DROPS THE IMAGE NOTIFICATION?
 *
 * FEX only treats a guest range as executable if InvalidationTracker::XIntervals
 * covers it, and that is populated ONLY from HandleImageMap(), which runs off
 * notify_map_view_of_section(). In the GTA V run the child pseudo-process
 * registered just two images -- the main exe and ntdll, both of which FEX's own
 * ProcessInit inserts directly -- and every native x64 dependency was absent, so
 * the first one whose code was executed (d3dx9_43) decoded as NOEXEC, raised
 * NoExecOp, and took the GuestSignal_SIGSEGV trampoline that deliberately reads
 * address 0. That synthetic fault is what surfaced as c0000005; it is NOT a bad
 * pointer in the guest.
 *
 * The existing [map-notify] probe sits INSIDE the helper, which is only entered
 * after three outer gates, so its silence was ambiguous between four causes:
 *   (a) this wrapper is never called (images mapped by unix code directly),
 *   (b) the map failed,
 *   (c) RtlIsCurrentProcess() is false for a pseudo-process,
 *   (d) enter_syscall_callback() refused -- InSyscallCallback already set, which
 *       once stuck stays stuck and silently drops every later notification.
 * Log outside every gate so one run separates them. Zero [map-gate] lines
 * alongside the [jit-pool] image lines means (a) and nothing else. */

/* iOS-Madeira ml709: REGISTER IMAGES AT THE LOADER BOUNDARY, NOT THE SYSCALL BOUNDARY.
 *
 * FEX only treats a guest range as executable if InvalidationTracker::XIntervals covers
 * it, and that is populated from HandleImageMap(), which until now ran ONLY off
 * NtMapViewOfSection's notification. In a child pseudo-process that notification never
 * arrived: the GTA V run registered just two images -- the main exe and ntdll, both
 * inserted directly by FEX's own ProcessInit -- while every native x64 dependency was
 * absent, so the first one whose code was executed (d3dx9_43) decoded as NOEXEC, raised
 * NoExecOp, and took the GuestSignal_SIGSEGV trampoline that deliberately reads address
 * zero. The resulting c0000005 looked exactly like a bad pointer in the guest and is not
 * one. The direct-launch case registers 14 images and works, which is the control.
 *
 * The syscall notification stays (applications may map executable images without ever
 * loading them as modules), but it is no longer the only path. This one fires from the
 * loader's semantic "module is mapped, relocated and imported, no DllMain has run yet"
 * boundary, which is in safe PE/ARM64EC context, is keyed to the correct pseudo-process
 * by construction, and does not depend on any of the four syscall-path gates.
 *
 * Symmetry matters as much as the map: if registration bypasses the broken gate but
 * removal still depends on it, FEX keeps stale executable intervals across a DLL unload
 * and a later address reuse inherits them. So the unload boundary is wired too.
 *
 * Duplicate registration is harmless -- HandleImageMap re-inserts the same intervals --
 * so the direct-launch path can and does notify twice for the same image. */
void arm64ec_notify_image_map( void *base )
{
    static unsigned int n_map;

    /* ml710: must be the intervals-only entry point, NEVER NotifyMapViewOfSection.
     * The latter also drives ImageTracker, which takes FEX's CodeInvalidationMutex
     * EXCLUSIVELY; we are called from the loader on a thread that may already hold it
     * SHARED from executing translated code, and there is no read-to-write upgrade. That
     * combination froze Marvel Cosmic Invasion on cryptbase.dll for 88s with wine's
     * loader lock held. If pNotifyImageMap is absent, do nothing: the syscall path is
     * still authoritative, and a wedge is far worse than a missed registration. */
    if (!base || !pNotifyImageMap) return;
    n_map++;
    if (n_map <= 64)
        ERR( "[ldr-image] ml710 MAP #%u base=%p peb=%p\n", n_map, base, RtlGetCurrentPeb() );
    pNotifyImageMap( base );
}

/* ml709b: UNUSED, deliberately. The loader must not call this -- see the long comment
 * at the removed call site in loader.c free_modref(). Kept only so the reasoning has a
 * home next to its map counterpart; wiring it up again re-freezes the process. */
void arm64ec_notify_image_unmap( void *base )
{
    static unsigned int n_unmap;

    if (!base || !pNotifyUnmapViewOfSection) return;
    n_unmap++;
    if (n_unmap <= 64)
        ERR( "[ldr-image] ml709 UNMAP #%u base=%p peb=%p\n", n_unmap, base, RtlGetCurrentPeb() );
    pNotifyUnmapViewOfSection( base, FALSE, 0 );
    pNotifyUnmapViewOfSection( base, TRUE, STATUS_SUCCESS );
}

static void ios_map_gate_probe( const char *who, HANDLE handle, HANDLE process, NTSTATUS status,
                                void *base, SIZE_T size, int is_cur, void *area,
                                int insc_before, int entered )
{
    static int n;
    if (n >= 48) return;
    n++;
    ERR( "[map-gate] ml709 %s handle=%p process=%p status=%x ok=%d cur=%d area=%p "
         "insc_before=%d entered=%d base=%p size=%p\n",
         who, handle, process, (unsigned int)status, NT_SUCCESS(status) ? 1 : 0, is_cur,
         area, insc_before, entered, base, (void *)size );
}

NTSTATUS SYSCALL_API NtMapViewOfSection( HANDLE handle, HANDLE process, PVOID *addr_ptr,
                                         ULONG_PTR zero_bits, SIZE_T commit_size,
                                         const LARGE_INTEGER *offset, SIZE_T *size_ptr,
                                         SECTION_INHERIT inherit, ULONG alloc_type, ULONG protect )
{
    NTSTATUS status = syscall_NtMapViewOfSection( handle, process, addr_ptr, zero_bits, commit_size,
                                                  offset, size_ptr, inherit, alloc_type, protect );

    if (NT_SUCCESS(status) && RtlIsCurrentProcess( process ) && ios_chrome_lookup( handle ))
        ios_chrome_set_view( handle, *addr_ptr );
    {
        CHPE_V2_CPU_AREA_INFO *area = get_arm64ec_cpu_area();
        int is_cur = RtlIsCurrentProcess( process ) ? 1 : 0;
        int insc_before = area ? !!area->InSyscallCallback : 0;
        int entered = 0;

        if (NT_SUCCESS(status) && is_cur) entered = enter_syscall_callback() ? 1 : 0;
        ios_map_gate_probe( "NtMapViewOfSection", handle, process, status,
                            NT_SUCCESS(status) ? *addr_ptr : NULL,
                            NT_SUCCESS(status) ? *size_ptr : 0,
                            is_cur, area, insc_before, entered );
        if (entered)
        {
            notify_map_view_of_section( handle, *addr_ptr, *size_ptr, alloc_type, protect, &status );
            leave_syscall_callback();
        }
    }
    return status;
}

NTSTATUS SYSCALL_API NtMapViewOfSectionEx( HANDLE handle, HANDLE process, PVOID *addr_ptr,
                                           const LARGE_INTEGER *offset, SIZE_T *size_ptr, ULONG alloc_type,
                                           ULONG protect, MEM_EXTENDED_PARAMETER *parameters, ULONG count )
{
    NTSTATUS status = syscall_NtMapViewOfSectionEx( handle, process, addr_ptr, offset, size_ptr,
                                                    alloc_type, protect, parameters, count );

    if (NT_SUCCESS(status) && RtlIsCurrentProcess( process ) && ios_chrome_lookup( handle ))
        ios_chrome_set_view( handle, *addr_ptr );
    {
        CHPE_V2_CPU_AREA_INFO *area = get_arm64ec_cpu_area();
        int is_cur = RtlIsCurrentProcess( process ) ? 1 : 0;
        int insc_before = area ? !!area->InSyscallCallback : 0;
        int entered = 0;

        if (NT_SUCCESS(status) && is_cur) entered = enter_syscall_callback() ? 1 : 0;
        ios_map_gate_probe( "NtMapViewOfSectionEx", handle, process, status,
                            NT_SUCCESS(status) ? *addr_ptr : NULL,
                            NT_SUCCESS(status) ? *size_ptr : 0,
                            is_cur, area, insc_before, entered );
        if (entered)
        {
            notify_map_view_of_section( handle, *addr_ptr, *size_ptr, alloc_type, protect, &status );
            leave_syscall_callback();
        }
    }
    return status;
}

/* iOS-Madeira ml206: shared guard for ALL THREE NotifyMemoryProtect paths.
 *
 * A protect spanning >= 1GB is never a code-permission change; it is an allocator managing
 * a reservation. FEX, however, treats any protect without EXEC as "this range is no longer
 * executable" and REMOVES it from InvalidationTracker::XIntervals
 * (InvalidationTracker.cpp:69-71), so forwarding one 16GB PartitionAlloc protect
 *   [iOS-xrem] via=protect 0x7000000000-0x7400000000
 * wipes the executable interval of EVERY module inside the range. Modules keep their own
 * real mappings and protections, so suppressing the notification cannot lose a genuine
 * executability transition — whereas forwarding it loses all of them at once. */
static BOOL ios_bulk_protect_suppressed( const char *via, void *addr, SIZE_T size, ULONG prot )
{
    static int suppressed;

    if (size < (1ull << 30)) return FALSE;
    if (prot & (PAGE_EXECUTE | PAGE_EXECUTE_READ | PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY))
        return FALSE;

    if (suppressed < 20)
    {
        suppressed++;
        ERR( "[protect-wall] SUPPRESSED via=%s %p+%p prot=%x (>=1GB non-exec would nuke all "
             "module exec intervals in range)\n", via, addr, (void *)size, prot );
    }
    return TRUE;
}

NTSTATUS SYSCALL_API NtProtectVirtualMemory( HANDLE process, PVOID *addr_ptr, SIZE_T *size_ptr,
                                             ULONG new_prot, ULONG *old_prot )
{
    BOOL is_current = RtlIsCurrentProcess( process );
    NTSTATUS status;

    if (!enter_syscall_callback())
        return syscall_NtProtectVirtualMemory( process, addr_ptr, size_ptr, new_prot, old_prot );

    if (!is_current) send_cross_process_notification( process, CrossProcessPreVirtualProtect,
                                                      *addr_ptr, *size_ptr, 2, new_prot, 0 );
    else if (pNotifyMemoryProtect)
    {
        /* iOS-Madeira ml203 ROOT-CAUSE FIX. FEX treats a protect notification without EXEC
         * as "this range is no longer executable" and REMOVES it from
         * InvalidationTracker::XIntervals (InvalidationTracker.cpp:69-71). A single
         * PartitionAlloc protect over its own 16GB soft pool
         *   [iOS-xrem] via=protect 0x7000000000-0x7400000000
         * therefore wiped the executable intervals of EVERY module in the furniture window
         * — libcef included (mapped at 0x73858d0000) — after which the decoder reported
         * NOEXEC at libcef code addresses, raised FAULT_SIGSEGV, branched to the
         * GuestSignal_SIGSEGV trampoline, and killed webhelper threads. That is the whole
         * chain we have been chasing, and it is a consequence of our lazy-reservation
         * geometry: soft-pool slot 0 aliases the region where PE modules are mapped.
         *
         * A protect spanning >= 1GB is never a code-permission change; it is an allocator
         * managing a reservation. Modules inside it keep their own real mappings and their
         * own protections, so suppressing the notification cannot lose a genuine
         * executability transition — whereas forwarding it loses ALL of them. */
        if (!ios_bulk_protect_suppressed( "cur-pre", *addr_ptr, *size_ptr, new_prot ))
            pNotifyMemoryProtect( *addr_ptr, *size_ptr, new_prot, FALSE, 0 );
    }

    /* iOS-Madeira ml186 PROBE. libcef IS registered at map time ([map-notify] addr=...
     * size=0xD3CA000 pfn=1), so its .text reaches InvalidationTracker::XIntervals — yet
     * the decoder still reports NOEXEC at libcef+0x1900733 / +0x3b508f0. The only thing
     * that REMOVES an XInterval is HandleMemoryProtectionNotification being told a
     * protection without EXEC (InvalidationTracker.cpp:69-71). We forward the REQUESTED
     * prot here, which is correct emulation — so log every non-exec protect landing in the
     * guest PE band, whoever the caller is (Chromium, Wine's loader, or our own JIT-pool
     * machinery touching the PE mapping). Correlate the address against the [jit-pool]
     * image lines to see if it covers libcef .text. */
    if (is_current && ios_in_big_image( (ULONG_PTR)*addr_ptr )
        && !(new_prot & (PAGE_EXECUTE | PAGE_EXECUTE_READ | PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY)))
    {
        static int unexec_n;
        if (unexec_n < 200)
        {
            unexec_n++;
            ERR( "[unexec] #%d addr=%p size=%p new_prot=%x\n",
                 unexec_n, *addr_ptr, (void *)*size_ptr, new_prot );
        }
    }

    /* ml283: log every protect that REQUESTS execute, anywhere, with its result.
     *
     * The [unexec] probe above cannot answer this: it filters to ios_in_big_image() AND to
     * protections WITHOUT execute. I nonetheless used its output to claim "the guest never
     * requests an execute protection", and retracted the V8-JIT theory on that basis. The
     * claim was unfounded -- that probe is structurally incapable of showing an exec
     * request, and doubly so outside a big PE image.
     *
     * What we actually know (ml273/ml283): libcef.dll+0x59ef805 calls a pointer landing at
     * 0x7e600f0080, inside a 6.7MB MEM_PRIVATE PAGE_READWRITE region based at
     * 0x7E60000000, and the target is COMMITTED but NOT EXECUTABLE. A private multi-MB
     * region entered at a 64KB-slot offset is V8 code-space shape. So the question is
     * precisely: does anything ask for EXECUTE on it, and does the request SUCCEED?
     * No address filter, no protection filter, and the status is printed -- so silence
     * here means "never requested", not "filtered out". */
    {
        static int execreq_n;
        const ULONG exec_mask = PAGE_EXECUTE | PAGE_EXECUTE_READ | PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY;

        if ((new_prot & exec_mask) && execreq_n < 64)
        {
            void *req_addr = *addr_ptr;
            SIZE_T req_size = *size_ptr;
            NTSTATUS st = syscall_NtProtectVirtualMemory( process, addr_ptr, size_ptr, new_prot, old_prot );

            execreq_n++;
            ERR( "[exec-req] #%d addr=%p size=%p new_prot=%lx -> status=%08x%s%s\n",
                 execreq_n, req_addr, (void *)req_size, new_prot, (unsigned)st,
                 st ? "  <== FAILED" : "",
                 is_current ? "" : "  (cross-process)" );

            if (!is_current) send_cross_process_notification( process, CrossProcessPostVirtualProtect,
                                                             *addr_ptr, *size_ptr, 2, new_prot, st );
            else if (pNotifyMemoryProtect
                     && !ios_bulk_protect_suppressed( "cur-post", *addr_ptr, *size_ptr, new_prot ))
                pNotifyMemoryProtect( *addr_ptr, *size_ptr, new_prot, TRUE, st );
            return st;
        }
    }

    status = syscall_NtProtectVirtualMemory( process, addr_ptr, size_ptr, new_prot, old_prot );

    if (!is_current) send_cross_process_notification( process, CrossProcessPostVirtualProtect,
                                                      *addr_ptr, *size_ptr, 2, new_prot, status );
    else if (pNotifyMemoryProtect
             && !ios_bulk_protect_suppressed( "cur-post", *addr_ptr, *size_ptr, new_prot ))
        pNotifyMemoryProtect( *addr_ptr, *size_ptr, new_prot, TRUE, status );

    leave_syscall_callback();
    return status;
}

NTSTATUS SYSCALL_API NtQuerySystemInformation( SYSTEM_INFORMATION_CLASS class, void *info, ULONG size, ULONG *ret_size )
{
    NTSTATUS status = syscall_NtQuerySystemInformation( class, info, size, ret_size );

    if (!status && class == SystemCpuInformation && pUpdateProcessorInformation) pUpdateProcessorInformation( info );
    return status;
}

NTSTATUS SYSCALL_API NtRaiseException( EXCEPTION_RECORD *rec, CONTEXT *context, BOOL first_chance )
{
    ARM64_NT_CONTEXT arm_ctx;

    context_x64_to_arm( &arm_ctx, (ARM64EC_NT_CONTEXT *)context );
    return syscall_NtRaiseException( rec, &arm_ctx, first_chance );
}

NTSTATUS SYSCALL_API NtReadFile( HANDLE handle, HANDLE event, PIO_APC_ROUTINE apc, void *apc_user,
                                 IO_STATUS_BLOCK *io, void *buffer, ULONG length,
                                 LARGE_INTEGER *offset, ULONG *key )
{
    NTSTATUS status;

    if (pBTCpu64NotifyReadFile && enter_syscall_callback())
    {
        pBTCpu64NotifyReadFile( handle, buffer, length, FALSE, 0 );
        status = syscall_NtReadFile( handle, event, apc, apc_user, io, buffer, length, offset, key );
        if (pBTCpu64NotifyReadFile) pBTCpu64NotifyReadFile( handle, buffer, length, TRUE, status );
        leave_syscall_callback();
        return status;
    }
    return syscall_NtReadFile( handle, event, apc, apc_user, io, buffer, length, offset, key );
}

NTSTATUS SYSCALL_API NtSetContextThread( HANDLE handle, const CONTEXT *context )
{
    ARM64_NT_CONTEXT arm_ctx;

    context_x64_to_arm( &arm_ctx, (ARM64EC_NT_CONTEXT *)context );
    return syscall_NtSetContextThread( handle, &arm_ctx );
}

NTSTATUS SYSCALL_API NtTerminateProcess( HANDLE handle, LONG exit_code )
{
    NTSTATUS status;

    if (!handle && pProcessTerm && enter_syscall_callback())
    {
        pProcessTerm( handle, FALSE, 0 );
        status = syscall_NtTerminateProcess( handle, exit_code );
        pProcessTerm( handle, TRUE, status );
        leave_syscall_callback();
        return status;
    }
    return syscall_NtTerminateProcess( handle, exit_code );
}

NTSTATUS SYSCALL_API NtTerminateThread( HANDLE handle, LONG exit_code )
{
    NTSTATUS status;

    if (pThreadTerm && enter_syscall_callback())
    {
        pThreadTerm( handle, exit_code );
        status = syscall_NtTerminateThread( handle, exit_code );
        leave_syscall_callback();
        return status;
    }
    return syscall_NtTerminateThread( handle, exit_code );
}

NTSTATUS SYSCALL_API NtUnmapViewOfSection( HANDLE process, void *addr )
{
    BOOL is_current = RtlIsCurrentProcess( process );
    NTSTATUS status;

    if (is_current) ios_chrome_clear_view( addr );
    if (is_current && pNotifyUnmapViewOfSection && enter_syscall_callback())
    {
        ios_log_unmap( addr );
        pNotifyUnmapViewOfSection( addr, FALSE, 0 );
        status = syscall_NtUnmapViewOfSection( process, addr );
        pNotifyUnmapViewOfSection( addr, TRUE, status );
        leave_syscall_callback();
        return status;
    }
    return syscall_NtUnmapViewOfSection( process, addr );
}

NTSTATUS SYSCALL_API NtUnmapViewOfSectionEx( HANDLE process, void *addr, ULONG flags )
{
    BOOL is_current = RtlIsCurrentProcess( process );
    NTSTATUS status;

    if (is_current) ios_chrome_clear_view( addr );
    if (is_current && pNotifyUnmapViewOfSection && enter_syscall_callback())
    {
        ios_log_unmap( addr );
        pNotifyUnmapViewOfSection( addr, FALSE, 0 );
        status = syscall_NtUnmapViewOfSectionEx( process, addr, flags );
        pNotifyUnmapViewOfSection( addr, TRUE, status );
        leave_syscall_callback();
        return status;
    }
    return syscall_NtUnmapViewOfSectionEx( process, addr, flags );
}


asm( ".section .rdata, \"dr\"\n\t"
     ".balign 8\n\t"
     ".globl arm64ec_syscalls\n"
     "arm64ec_syscalls:\n\t"
#define SYSCALL_ENTRY(id,name,args) ".quad \"#" #name "$hp_target\"\n\t"
     ALL_SYSCALLS
#undef SYSCALL_ENTRY
     ".text" );


/***********************************************************************
 *           LdrpGetX64Information
 */
static NTSTATUS WINAPI LdrpGetX64Information( ULONG type, void *output, void *extra_info )
{
    switch (type)
    {
    case 0:
    {
        UINT64 fpcr, fpsr;

        __asm__ __volatile__( "mrs %0, fpcr; mrs %1, fpsr" : "=r" (fpcr), "=r" (fpsr) );
        *(UINT *)output = fpcsr_to_mxcsr( fpcr, fpsr );
        return STATUS_SUCCESS;
    }
    case 2:
        *(UINT *)output = 0x27f;  /* hard-coded x87 control word */
        return STATUS_SUCCESS;
    default:
        FIXME( "not implemented type %lu\n", type );
        return STATUS_INVALID_PARAMETER;
    }
}

/***********************************************************************
 *           LdrpSetX64Information
 */
static NTSTATUS WINAPI LdrpSetX64Information( ULONG type, ULONG_PTR input, void *extra_info )
{
    switch (type)
    {
    case 0:
    {
        UINT64 fpcsr = mxcsr_to_fpcsr( input );
        __asm__ __volatile__( "msr fpcr, %0; msr fpsr, %1" :: "r" (fpcsr), "r" (fpcsr >> 32) );
        return STATUS_SUCCESS;
    }
    default:
        FIXME( "not implemented type %lu\n", type );
        return STATUS_INVALID_PARAMETER;
    }
}


/**********************************************************************
 *           ProcessPendingCrossProcessEmulatorWork  (ntdll.@)
 */
void WINAPI ProcessPendingCrossProcessEmulatorWork(void)
{
    CHPEV2_PROCESS_INFO *info = RtlGetCurrentPeb()->ChpeV2ProcessInfo;
    CROSS_PROCESS_WORK_LIST *list = (void *)info->CrossProcessWorkList;
    CROSS_PROCESS_WORK_ENTRY *entry;
    BOOLEAN flush = FALSE;
    UINT next;

    if (!list) return;
    entry = RtlWow64PopAllCrossProcessWorkFromWorkList( &list->work_list, &flush );

    if (flush)
    {
        if (pFlushInstructionCacheHeavy) pFlushInstructionCacheHeavy( NULL, 0 );
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
            if (!pNotifyMemoryAlloc) break;
            pNotifyMemoryAlloc( (void *)entry->addr, entry->size, entry->args[0], entry->args[1],
                                entry->id == CrossProcessPostVirtualAlloc, entry->args[2] );
            break;
        case CrossProcessPreVirtualFree:
        case CrossProcessPostVirtualFree:
            if (!pNotifyMemoryFree) break;
            pNotifyMemoryFree( (void *)entry->addr, entry->size, entry->args[0],
                               entry->id == CrossProcessPostVirtualFree, entry->args[1] );
            break;
        case CrossProcessPreVirtualProtect:
        case CrossProcessPostVirtualProtect:
            if (!pNotifyMemoryProtect) break;
            /* iOS-Madeira ml206: THE path the 16GB wipe actually arrived on. Our
             * pseudo-processes share one address space, so RtlIsCurrentProcess() is FALSE
             * for a sibling handle and the protect is queued here rather than taking the
             * is_current branch ml203 guarded — which is why that fix logged nothing while
             * the wipe still happened. Guard it identically. */
            if (ios_bulk_protect_suppressed( "xproc", (void *)entry->addr, entry->size,
                                             entry->args[0] )) break;
            pNotifyMemoryProtect( (void *)entry->addr, entry->size, entry->args[0],
                                  entry->id == CrossProcessPostVirtualProtect, entry->args[1] );
            break;
        case CrossProcessFlushCache:
            if (!pBTCpu64FlushInstructionCache) break;
            pBTCpu64FlushInstructionCache( (void *)entry->addr, entry->size );
            break;
        case CrossProcessFlushCacheHeavy:
            if (!pFlushInstructionCacheHeavy) break;
            pFlushInstructionCacheHeavy( (void *)entry->addr, entry->size );
            break;
        case CrossProcessMemoryWrite:
            if (!pBTCpu64NotifyMemoryDirty) break;
            pBTCpu64NotifyMemoryDirty( (void *)entry->addr, entry->size );
            break;
        }
        next = entry->next;
        RtlWow64PushCrossProcessWorkOntoFreeList( &list->free_list, entry );
        entry = next ? CROSS_PROCESS_LIST_ENTRY( &list->work_list, next ) : NULL;
    }
}


/**********************************************************************
 *           virtual_unwind
 */
static NTSTATUS virtual_unwind( ULONG type, DISPATCHER_CONTEXT_ARM64EC *dispatch,
                                ARM64EC_NT_CONTEXT *context )
{
    DISPATCHER_CONTEXT_NONVOLREG_ARM64 *nonvol_regs;
    DWORD64 pc = context->Pc;
    int i;

    /* iOS: pc is a JIT-pool VA when captured from executing code; the
     * function tables live at PE VAs. Reverse-translate so the walk runs
     * in PE space (identity for non-pool addresses / pre-init). */
    pc = (DWORD64)xlate_ios_jit_rev( (void *)pc );

    dispatch->ScopeIndex = 0;
    dispatch->ControlPc  = pc;
    dispatch->ControlPcIsUnwound = (context->ContextFlags & CONTEXT_UNWOUND_TO_CALL) != 0;
    if (dispatch->ControlPcIsUnwound && RtlIsEcCode( pc )) pc -= 4;

    nonvol_regs = (DISPATCHER_CONTEXT_NONVOLREG_ARM64 *)dispatch->NonVolatileRegisters;
    nonvol_regs->GpNvRegs[0]  = context->X19;
    nonvol_regs->GpNvRegs[1]  = context->X20;
    nonvol_regs->GpNvRegs[2]  = context->X21;
    nonvol_regs->GpNvRegs[3]  = context->X22;
    nonvol_regs->GpNvRegs[4]  = 0;
    nonvol_regs->GpNvRegs[5]  = 0;
    nonvol_regs->GpNvRegs[6]  = context->X25;
    nonvol_regs->GpNvRegs[7]  = context->X26;
    nonvol_regs->GpNvRegs[8]  = context->X27;
    nonvol_regs->GpNvRegs[9]  = 0;
    nonvol_regs->GpNvRegs[10] = context->Fp;
    for (i = 0; i < 8; i++) nonvol_regs->FpNvRegs[i] = context->V[i + 8].D[0];

    dispatch->FunctionEntry = RtlLookupFunctionEntry( pc, &dispatch->ImageBase, dispatch->HistoryTable );

    if (RtlVirtualUnwind2( type, dispatch->ImageBase, pc, dispatch->FunctionEntry, &context->AMD64_Context,
                           NULL, &dispatch->HandlerData, &dispatch->EstablisherFrame,
                           NULL, NULL, NULL, &dispatch->LanguageHandler, 0 ))
    {
        WARN( "exception data not found for pc %p\n", (void *)pc );
        return STATUS_INVALID_DISPOSITION;
    }
    return STATUS_SUCCESS;
}


/**********************************************************************
 *           unwind_exception_handler
 *
 * Handler for exceptions happening while calling an unwind handler.
 */
EXCEPTION_DISPOSITION WINAPI unwind_exception_handler( EXCEPTION_RECORD *record, void *frame,
                                                       CONTEXT *context, DISPATCHER_CONTEXT_ARM64EC *dispatch )
{
    DISPATCHER_CONTEXT_ARM64EC *orig_dispatch = ((DISPATCHER_CONTEXT_ARM64EC **)frame)[-2];

    /* copy the original dispatcher into the current one, except for the TargetPc */
    dispatch->ControlPc          = orig_dispatch->ControlPc;
    dispatch->ImageBase          = orig_dispatch->ImageBase;
    dispatch->FunctionEntry      = orig_dispatch->FunctionEntry;
    dispatch->EstablisherFrame   = orig_dispatch->EstablisherFrame;
    dispatch->LanguageHandler    = orig_dispatch->LanguageHandler;
    dispatch->HandlerData        = orig_dispatch->HandlerData;
    dispatch->HistoryTable       = orig_dispatch->HistoryTable;
    dispatch->ScopeIndex         = orig_dispatch->ScopeIndex;
    dispatch->ControlPcIsUnwound = orig_dispatch->ControlPcIsUnwound;
    *dispatch->ContextRecord     = *orig_dispatch->ContextRecord;
    memcpy( dispatch->NonVolatileRegisters, orig_dispatch->NonVolatileRegisters,
            sizeof(DISPATCHER_CONTEXT_NONVOLREG_ARM64) );
    TRACE( "detected collided unwind\n" );
    return ExceptionCollidedUnwind;
}


/**********************************************************************
 *           call_unwind_handler
 */
static DWORD __attribute__((naked)) call_unwind_handler( EXCEPTION_RECORD *rec, ULONG_PTR frame,
                                                         CONTEXT *context, void *dispatch,
                                                         PEXCEPTION_ROUTINE handler )
{
    asm( ".seh_proc call_unwind_handler\n\t"
         "stp x29, x30, [sp, #-32]!\n\t"
         ".seh_save_fplr_x 32\n\t"
         ".seh_endprologue\n\t"
         ".seh_handler unwind_exception_handler, @except\n\t"
         "str x3, [sp, #16]\n\t"    /* frame[-2] = dispatch */
         "mov x11, x4\n\t" /* handler */
         "adr x10, $iexit_thunk$cdecl$i8$i8i8i8i8\n\t"
         "adrp x16, __os_arm64x_dispatch_icall\n\t"
         "ldr x16, [x16, #:lo12:__os_arm64x_dispatch_icall]\n\t"
         "blr x16\n\t"
         "blr x11\n\t"
         "ldp x29, x30, [sp], #32\n\t"
         "ret\n\t"
         ".seh_endproc" );
}


/*******************************************************************
 *         nested_exception_handler
 */
EXCEPTION_DISPOSITION WINAPI nested_exception_handler( EXCEPTION_RECORD *rec, void *frame,
                                                       CONTEXT *context, void *dispatch )
{
    if (rec->ExceptionFlags & (EXCEPTION_UNWINDING | EXCEPTION_EXIT_UNWIND)) return ExceptionContinueSearch;
    return ExceptionNestedException;
}


/***********************************************************************
 *		call_seh_handler
 */
static DWORD __attribute__((naked)) call_seh_handler( EXCEPTION_RECORD *rec, ULONG_PTR frame,
                                                      CONTEXT *context, void *dispatch, PEXCEPTION_ROUTINE handler )
{
    asm( ".seh_proc call_seh_handler\n\t"
         "stp x29, x30, [sp, #-16]!\n\t"
         ".seh_save_fplr_x 16\n\t"
         ".seh_endprologue\n\t"
         ".seh_handler nested_exception_handler, @except\n\t"
         "mov x11, x4\n\t" /* handler */
         "adr x10, $iexit_thunk$cdecl$i8$i8i8i8i8\n\t"
         "adrp x16, __os_arm64x_dispatch_icall\n\t"
         "ldr x16, [x16, #:lo12:__os_arm64x_dispatch_icall]\n\t"
         "blr x16\n\t"
         "blr x11\n\t"
         "ldp x29, x30, [sp], #16\n\t"
         "ret\n\t"
         ".seh_endproc" );
}


/**********************************************************************
 *           ios_seh_xlate_note   (iOS-Madeira ml603)
 *
 * Report SEH language-handler translation ONCE PER DISTINCT HANDLER.
 *
 * The ml477 revert note asked for every translation to be logged, because a
 * 4-per-process cap is what hid the x86-64-guest-handler case that broke ml476.
 * Logging all of them literally would mean ~790k lines — the exact volume that
 * drowned the log pipeline in ml602 — and would add no information, since the
 * same handful of handlers repeat. Distinct-once gives the full set (which is
 * what makes an unexpected guest handler visible) at negligible cost, and the
 * census proves the probe stayed alive.
 */
static void ios_seh_xlate_note( PEXCEPTION_ROUTINE orig, PEXCEPTION_ROUTINE final, BOOLEAN is_ec )
{
    static void *seen[64];
    static unsigned int seen_n;
    static unsigned int overflow_logged;
    static unsigned int n_ec, n_guest;
    unsigned int i;

    if (is_ec) n_ec++; else n_guest++;

    /* Census on a power-of-two boundary: cheap, and proves the gate is live. */
    if (((n_ec + n_guest) & 0xffff) == 0)
        ERR( "[seh-xlate] ml603 census: ec_translated=%u guest_untouched=%u distinct=%u\n",
             n_ec, n_guest, seen_n );

    for (i = 0; i < seen_n; i++) if (seen[i] == (void *)orig) return;

    if (seen_n >= ARRAY_SIZE(seen))
    {
        if (!overflow_logged++)
            ERR( "[seh-xlate] ml603 distinct table FULL (%u) — further new handlers unlogged\n",
                 (unsigned int)ARRAY_SIZE(seen) );
        return;
    }
    seen[seen_n++] = (void *)orig;

    {
        void *mod = NULL;
        const WCHAR *name = NULL;
        LDR_DATA_TABLE_ENTRY *ldr;

        if (!LdrFindEntryForAddress( (void *)orig, &ldr ))
        {
            mod = ldr->DllBase;
            name = ldr->BaseDllName.Buffer;
        }
        ERR( "[seh-xlate] ml603 handler=%p %s -> %p  module=%s+0x%x\n",
             orig, is_ec ? "EC/native TRANSLATED" : "GUEST left in PE space (icall -> FEX)",
             final, name ? debugstr_w(name) : "?",
             mod ? (unsigned int)((ULONG_PTR)orig - (ULONG_PTR)mod) : 0 );
    }
}


/**********************************************************************
 *           call_seh_handlers
 *
 * Call the SEH handlers.
 */
NTSTATUS call_seh_handlers( EXCEPTION_RECORD *rec, CONTEXT *orig_context )
{
    EXCEPTION_REGISTRATION_RECORD *teb_frame = NtCurrentTeb()->Tib.ExceptionList;
    DISPATCHER_CONTEXT_NONVOLREG_ARM64 nonvol_regs;
    UNWIND_HISTORY_TABLE table;
    DISPATCHER_CONTEXT_ARM64EC dispatch;
    ARM64EC_NT_CONTEXT context;
    NTSTATUS status;
    ULONG_PTR frame;
    DWORD res;

    /* iOS-Madeira ml409 (#66): third bracket point — see [ki-path]. If Rsp is
     * already corrupt here but was clean at [veh], the vectored handlers (or
     * the emulator trip that ran them) are the corruptor. AV-only, capped. */
    if (rec->ExceptionCode == STATUS_ACCESS_VIOLATION)
    {
        static LONG sehent_n;
        if (sehent_n < 60 && InterlockedIncrement( &sehent_n ) <= 60)
            ERR( "[seh-entry] ctx=%p Rsp=%p Rip=%p\n", orig_context,
                 (void *)(ULONG_PTR)orig_context->Rsp, (void *)(ULONG_PTR)orig_context->Rip );

    }

    /* iOS-Madeira ml633: ESTABLISH THE GUEST-STACK WINDOW IN PHASE ONE TOO.
     * ec_stack_window_begin() was only called on the phase-two unwind path, yet phase
     * one consults ec_win — so a thread could validate frames against another
     * exception's bounds, or none at all. Re-establish from the ORIGINAL Rsp here.
     *
     * ml742: this call used to sit INSIDE the access-violation-only diagnostic
     * block above -- a brace-placement slip, since the comment describes a
     * requirement for phase one generally. Any exception that is not an access
     * violation therefore ran phase one against whatever window the previous
     * exception left behind, and ec_win is AUTHORITATIVE in
     * is_valid_arm64ec_frame(): when ec_win.hi is set the TEB bounds are never
     * consulted. A stale window rejects a perfectly good frame, and the caller
     * treats that as a bogus context and kills the thread.
     *
     * That is what stopped a UE4 title from starting: it raised 0x406D1388 --
     * the benign code a thread raises purely to NAME itself -- while running its
     * DLL_THREAD_ATTACH callbacks. Not an access violation, so no window; the
     * frame was rejected despite sitting inside the printed stack bounds, and
     * one of the game's own threads was terminated during initialisation. */
    ec_stack_window_begin( (ULONG_PTR)orig_context->Rsp );

    /* iOS-Madeira 2026-07-04: [SEH_RATE] — the render worker burns ~75% of
     * its frame in virtual_unwind/RtlVirtualUnwind2/memset below this
     * function (PROF), yet nothing logs: these are HANDLED exceptions
     * (likely software RaiseException/C++ throws — no Mach fault, TRACE
     * muted). Sampled ERR every 1024 dispatches: total count + code +
     * faulting address names the thrower and quantifies the rate. */
    {
        static LONG seh_dispatch_count;
        LONG n = InterlockedIncrement( &seh_dispatch_count );
        if (n == 1 || (n & 0x3FF) == 0)
            ERR( "[SEH_RATE] n=%d code=%08x addr=%p flags=%x\n",
                 (int)n, (int)rec->ExceptionCode, rec->ExceptionAddress,
                 (int)rec->ExceptionFlags );
    }

    context.AMD64_Context = *orig_context;
    context.ContextFlags &= ~0x40; /* Clear xstate flag. */

    dispatch.TargetPc      = 0;
    dispatch.ContextRecord = &context.AMD64_Context;
    dispatch.HistoryTable  = &table;
    dispatch.NonVolatileRegisters = nonvol_regs.Buffer;

    /* iOS-Madeira 2026-07-04: no-progress guard. A dispatch whose context
     * holds JIT-pool VAs finds no unwind tables (function tables are
     * registered for the PE VAs), so RtlVirtualUnwind2's leaf-frame
     * fallback can cycle without advancing — measured: ONE stuck dispatch
     * spun 1.2e9 unwind steps against the same RtlRaiseException frame,
     * pegging a P-core since boot. If neither ControlPc nor the frame
     * advances between iterations, or the walk exceeds a sane depth,
     * bail with EXCEPTION_STACK_INVALID instead of spinning forever. */
    {
        ULONG64 prev_pc = 0, prev_frame = 0;
        unsigned int walk_steps = 0;
        /* ml222: ring of the last few unwind steps, dumped ONLY if the walk ends badly.
         * The failing dispatch reported ControlPc=0, which has two readings needing
         * opposite fixes: the walk covered several sane frames and reached the genuine
         * end of stack (so the exception really is unhandled, and the question is why no
         * handler matched), or ControlPc was 0 from step 1 (the incoming context is
         * broken). Recording the trajectory instead of the endpoint distinguishes them,
         * and costs nothing on the paths that succeed. */
        ULONG64 trace_pc[8] = { 0 }, trace_frame[8] = { 0 };
        unsigned int trace_n = 0;

    for (;;)
    {
        status = virtual_unwind( UNW_FLAG_EHANDLER, &dispatch, &context );
        if (status != STATUS_SUCCESS) return status;

    unwind_done:
        trace_pc[trace_n & 7] = dispatch.ControlPc;
        trace_frame[trace_n & 7] = dispatch.EstablisherFrame;
        trace_n++;

        if (!dispatch.EstablisherFrame) break;

        /* iOS-Madeira ml246: ControlPc == 0 is the END OF THE STACK -- there is nothing to
         * unwind to, and continuing just walks memory until it faults.
         *
         * The existing no-progress guard needs BOTH pc and frame to repeat, so it cannot
         * catch the observed degeneration: pc stays 0 while the frame creeps upward 8 bytes
         * per step. Measured 2074 steps ending at a fresh SEGV in ntdll's own walk
         * (ntdll+0x69c48) reading unmapped memory, which became SEGV LOOP FATAL and killed
         * the process -- while unwinding an exception raised inside Steam's CEF surface
         * (chromehtml.dll+0xdc70 via tier0_s64). Stopping here turns a process-killing walk
         * into an ordinary unhandled exception. */
        /* ml266 FIX: ControlPc == 0 is the NORMAL END OF THE STACK, not a broken one.
         *
         * The ml246 guard above lumped it in with the degenerate cases and set
         * EXCEPTION_STACK_INVALID, which NtRaiseException turns into
         *   "Exception frame is not in stack limits => unable to dispatch exception"
         * followed by an IMMEDIATE NtTerminateProcess. That short-circuits second
         * chance entirely -- so the process dies before the guest's unhandled-exception
         * filter (SetUnhandledExceptionFilter, which Chromium installs for crash
         * reporting) ever runs, and before the debugger event.
         *
         * Measured in ml266: FEX did everything right -- reconstructed the guest
         * context, mapped host pc 0x157424650 -> guest rip 0x7E200E0080, and rethrew
         * onto the guest stack -- then
         *   call_seh_handlers unwind stuck: pc=0 frame=703f3ff350 steps=1
         * with frame == ecRsp + 8, i.e. the leaf pop RAN and read a return address of
         * ZERO. A guest that jumped to a bogus RIP simply has no caller. That is an
         * unhandled exception, which is a normal outcome, NOT an invalid stack.
         *
         * So: end the search quietly and let the exception take the ordinary unhandled
         * path. Keep EXCEPTION_STACK_INVALID for what it actually means -- a walk that
         * degenerates (no forward progress) or runs away. */
        if (!dispatch.ControlPc)
        {
            WARN( "unwind reached end of stack after %u steps (frame=%I64x) —"
                  " exception is unhandled, dispatching normally\n",
                  walk_steps, dispatch.EstablisherFrame );
            break;
        }

        if ((dispatch.ControlPc == prev_pc && dispatch.EstablisherFrame == prev_frame) ||
            ++walk_steps > 0x10000)
        {
            /* iOS-Madeira ml327 LIVELOCK BREAKER.
             *
             * Abandoning the walk ends THIS dispatch, but nothing stops the same fault
             * from recurring: a live run was caught repeating
             *   unwind stuck: pc=149dc0110 frame=71e01fdfb0 steps=2 — abandoning walk
             * 58,045 times with byte-identical pc and frame, spinning until the user
             * killed the app (20MB of log, battery burn, no progress). Faults became
             * survivable in #38, which is right for ordinary guest faults, but a fault
             * whose handler cannot make progress just retries the same instruction
             * forever.
             *
             * Count CONSECUTIVE abandons at the same (pc, frame). A different site
             * resets the counter, so genuinely distinct unwindable faults are unaffected.
             * Past the threshold, stop pretending this is recoverable and terminate with
             * the real exception code -- a diagnosable crash beats an infinite loop. */
            {
                static ULONG64 stuck_pc, stuck_frame;
                static unsigned stuck_n;

                if ((ULONG64)dispatch.ControlPc == stuck_pc && dispatch.EstablisherFrame == stuck_frame)
                {
                    if (++stuck_n >= 16)
                    {
                        ERR( "unwind stuck: SAME site pc=%I64x frame=%I64x abandoned %u times in a row"
                             " — livelock, terminating with code %08lx\n",
                             (ULONG64)dispatch.ControlPc, dispatch.EstablisherFrame, stuck_n,
                             rec->ExceptionCode );
                        NtTerminateProcess( GetCurrentProcess(), rec->ExceptionCode );
                    }
                }
                else
                {
                    stuck_pc = (ULONG64)dispatch.ControlPc;
                    stuck_frame = dispatch.EstablisherFrame;
                    stuck_n = 1;
                }
            }
            ERR( "unwind stuck: pc=%I64x frame=%I64x steps=%u — abandoning walk\n",
                 (ULONG64)dispatch.ControlPc, dispatch.EstablisherFrame, walk_steps );
            rec->ExceptionFlags |= EXCEPTION_STACK_INVALID;
            break;
        }
        prev_pc = dispatch.ControlPc;
        prev_frame = dispatch.EstablisherFrame;

        /* iOS-Madeira ml633: THE TERMINAL ROOT FRAME IS LEGAL — DO NOT REJECT IT.
         *
         * Usable frames are [lo, hi), but the OUTERMOST frame of a thread sits exactly
         * AT hi. In the ml632 ULTRAKILL run the walk reached
         *   ControlPc = ntdll!RtlUserThreadStart+0x2c, EstablisherFrame = 0x703ec60000
         * which is precisely StackBase, and its unwind record has ExceptionDataPresent
         * with handler RVA 0x25388 = call_unhandled_exception_handler — i.e. THE frame
         * whose whole job is to run Unity's unhandled-exception filter. Rejecting it
         * produced "Exception frame is not in stack limits => unable to dispatch" and
         * terminated before the game's own filter ever ran. Stock Wine accepts
         * frame <= StackBase.
         *
         * ⛔ Do NOT relax every `< hi` to `<= hi` — that would bless any one-past-the-end
         * address and re-open what ml617 closed. This predicate is deliberately narrow:
         * the frame must be EXACTLY hi, the unwound Rsp must ALSO be exactly hi, and it
         * is honoured at most once per walk, so a loop cannot exploit it. */
        {
            static __thread int ml633_root_used;
            if (walk_steps <= 1) ml633_root_used = 0;   /* new walk */
            if (ec_win.hi && !ml633_root_used &&
                dispatch.EstablisherFrame == (ULONG64)ec_win.hi &&
                context.AMD64_Context.Rsp == (ULONG64)ec_win.hi &&
                !is_valid_arm64ec_frame( dispatch.EstablisherFrame ))
            {
                ml633_root_used = 1;
                ERR( "[unwind-root] ml633 ACCEPTING terminal root frame %I64x (== stack hi) "
                     "ControlPc=%I64x handler=%p — this is the unhandled-exception filter frame\n",
                     dispatch.EstablisherFrame, (ULONG64)dispatch.ControlPc,
                     dispatch.LanguageHandler );
                goto ml633_frame_ok;
            }
        }

        if (!is_valid_arm64ec_frame( dispatch.EstablisherFrame ))
        {
            /* ml742: print the bounds the decision was ACTUALLY made against.
             * The existing report below prints only the TEB stack, but ec_win
             * overrides it when set -- so a frame plainly inside the printed
             * range can still be rejected, which reads as a contradiction and
             * sent one investigation down the wrong path. Show both, plus
             * whether the plain TEB test would have passed. Bounded. */
            {
                static LONG ml742_n;
                if (InterlockedIncrement( &ml742_n ) <= 24)
                    ERR( "[ec-frame] ml742 REJECT frame=%p code=%08x | ec_win lo=%p hi=%p "
                         "emu lo=%p hi=%p | origRsp=%p tebStack=%p-%p | teb_test=%d\n",
                         (void *)dispatch.EstablisherFrame, (int)rec->ExceptionCode,
                         (void *)ec_win.lo, (void *)ec_win.hi,
                         (void *)ec_win.emu_lo, (void *)ec_win.emu_hi,
                         (void *)(ULONG_PTR)orig_context->Rsp,
                         NtCurrentTeb()->Tib.StackLimit, NtCurrentTeb()->Tib.StackBase,
                         is_valid_frame( dispatch.EstablisherFrame ) );
            }
            /* ml221: report WHY the walk produced this frame, not just that it did.
             *
             * The frame that killed the webhelper was 0x73c9f70008 -- 8 bytes into
             * DWrite.dll's read-only headers, i.e. the walk had run off the end of the
             * guest stack. That happens when ControlPc stays a JIT-pool VA: function
             * tables are registered at PE VAs, so no unwind info is found and the frames
             * are garbage. virtual_unwind reverse-translates via
             * p_ios_jit_reverse_translate_addr, but that pointer lives in ntdll's .data
             * and every pseudo-process gets a CLONED copy -- if a child's copy is NULL the
             * translation silently degrades to identity. Print it, plus ControlPc, so the
             * two cases are distinguishable instead of guessed at. */
            ERR( "invalid frame %I64x (%p-%p) ControlPc=%I64x xlate_rev=%p%s\n",
                 dispatch.EstablisherFrame,
                 NtCurrentTeb()->Tib.StackLimit, NtCurrentTeb()->Tib.StackBase,
                 (ULONG64)dispatch.ControlPc, p_ios_jit_reverse_translate_addr,
                 p_ios_jit_reverse_translate_addr ? "" : "  <-- NULL: unwind ran in POOL space" );
            /* ml260 (#38): name WHERE the garbage frame came from.
             *
             * Symbolised, the failing walk is our OWN dispatch stack:
             *   #0 set_int_reg (unwind.c:1815)  <- the AV, *val on a garbage frame
             *   #1 virtual_unwind  #2 call_seh_handlers  #3 dispatch_exception
             *   #4 KiUserExceptionDispatcher   frame=0x40001131  <- garbage
             * and the AV address 0x40001171 is exactly frame+0x40, i.e. a saved-register
             * slot. 0x40001131 is not a corrupted pointer -- it has the shape of a FRAME
             * REGISTER value, which matters because virtual_unwind above zeroes several
             * ARM64EC nonvolatile slots (GpNvRegs[4], [5], [9] = 0): if the unwind info
             * for this pc selects a frame register we do not populate, Rsp is set from
             * junk and every subsequent slot read is wild.
             *
             * So print the x64 nonvolatiles plus the UNWIND_INFO's frame-register fields.
             * If one of these registers equals the bad frame, the culprit is named
             * outright; if none do, the frame came from an opcode instead and the fix is
             * elsewhere. Fires only on this already-fatal path, so it costs nothing. */
            {
                CONTEXT *c = &context.AMD64_Context;
                ERR( "[unwind-why] frame=%I64x | Rsp=%I64x Rbp=%I64x Rbx=%I64x Rsi=%I64x Rdi=%I64x\n",
                     dispatch.EstablisherFrame, c->Rsp, c->Rbp, c->Rbx, c->Rsi, c->Rdi );
                ERR( "[unwind-why]   R12=%I64x R13=%I64x R14=%I64x R15=%I64x ImageBase=%I64x FnEntry=%p\n",
                     c->R12, c->R13, c->R14, c->R15, dispatch.ImageBase,
                     (void *)dispatch.FunctionEntry );
                /* ml274 CORRECTION: decode per ABI, not blindly as x64.
                 *
                 * The first version of this probe read the entry as an x64
                 * RUNTIME_FUNCTION (12 bytes: Begin/End/UnwindData) and its UnwindData as
                 * x64 UNWIND_INFO. For EC code that is the WRONG STRUCT, and it produced
                 * confident nonsense: entry[8840] of ntdll's ExtraRFETable is
                 * Begin=0x59730 UnwindData=0xb71ec and entry[8841] Begin=0x59770, which the
                 * probe reported as "begin=59730 end=b71ec unwind=59770" -- inventing a
                 * 383KB function whose xdata sat inside .text, then decoding a valid ARM64
                 * unwind RVA as x64 UNWIND_INFO (hence "version 3, 188 codes, framereg R9").
                 * There was never a fabricated RUNTIME_FUNCTION.
                 *
                 * RtlLookupFunctionTable picks the table with RtlIsEcCode: true ->
                 * ExtraRFETable (ARM64EC, 8-byte entries), false ->
                 * IMAGE_DIRECTORY_ENTRY_EXCEPTION (x64, 12-byte entries). Report which one
                 * applies and decode accordingly. */
                if (dispatch.FunctionEntry && dispatch.ImageBase)
                {
                    BOOLEAN is_ec = RtlIsEcCode( dispatch.ControlPc );

                    if (is_ec)
                    {
                        /* ARM64 RUNTIME_FUNCTION: BeginAddress + UnwindData. UnwindData with
                         * either of the low 2 bits set is PACKED unwind data; otherwise it is
                         * an RVA to .xdata. */
                        const DWORD *fn = (const DWORD *)dispatch.FunctionEntry;
                        DWORD begin = fn[0], ud = fn[1];

                        if (ud & 3)
                            ERR( "[unwind-why]   EC entry (ARM64, 8B): Begin=%x UnwindData=%x"
                                 " PACKED (flag=%u)\n", begin, ud, ud & 3 );
                        else
                        {
                            const DWORD *xd = (const DWORD *)(dispatch.ImageBase + ud);
                            ERR( "[unwind-why]   EC entry (ARM64, 8B): Begin=%x UnwindData=%x"
                                 " .xdata hdr[0]=%08x hdr[1]=%08x\n", begin, ud, xd[0], xd[1] );
                        }
                    }
                    else
                    {
                        const RUNTIME_FUNCTION *fn = (const RUNTIME_FUNCTION *)dispatch.FunctionEntry;
                        const BYTE *info = (const BYTE *)dispatch.ImageBase + fn->UnwindData;

                        ERR( "[unwind-why]   x64 entry (12B): begin=%x end=%x unwind=%x |"
                             " ver/flags=%02x prolog=%02x ncodes=%02x framereg=%u frameoff=%u\n",
                             (unsigned)fn->BeginAddress, (unsigned)fn->EndAddress,
                             (unsigned)fn->UnwindData, info[0], info[1], info[2],
                             info[3] & 0xf, (info[3] >> 4) & 0xf );
                    }
                    ERR( "[unwind-why]   table=%s ImageBase=%I64x ControlPc=%I64x\n",
                         is_ec ? "ExtraRFETable(ARM64EC)" : "DIRECTORY_ENTRY_EXCEPTION(x64)",
                         dispatch.ImageBase, (ULONG64)dispatch.ControlPc );
                }
            }
            {
                unsigned int k, shown = trace_n < 8 ? trace_n : 8;
                ERR( "[unwind-trace] %u steps total, last %u:\n", trace_n, shown );
                for (k = 0; k < shown; k++)
                {
                    unsigned int idx = (trace_n - shown + k) & 7;
                    ERR( "[unwind-trace]   #%u pc=%I64x frame=%I64x\n",
                         trace_n - shown + k, trace_pc[idx], trace_frame[idx] );
                }
            }
            /* ml377: a FIRST-STEP bad frame is an UNHANDLED exception, not a corrupt
             * stack — do not set EXCEPTION_STACK_INVALID for it.
             *
             * Same reasoning as the ml266 ControlPc==0 fix directly above, and the same
             * measured consequence: EXCEPTION_STACK_INVALID makes NtRaiseException print
             * "Exception frame is not in stack limits" and IMMEDIATELY NtTerminateProcess,
             * which short-circuits second chance — so Chromium's own
             * SetUnhandledExceptionFilter never runs and the WHOLE APP dies, not just the
             * offending pseudo-process.
             *
             * ml377 measured exactly that: the guest context handed to us was already
             * bogus (Rip=0x7c861802f1, inside FEX's HOST band, and a truncated
             * Rsp=0x1db59fba0 whose true value 0x71db59fba0 is in the TEB stack), so step
             * #0 produced an unusable frame. A guest that jumped to a garbage RIP has no
             * caller — that is an ordinary unhandled exception. Deep CEF work (profile /
             * extensions / GAIA sign-in) was lost to a process kill here.
             *
             * Keep EXCEPTION_STACK_INVALID for what it is meant to describe: a walk that
             * PROGRESSED and then degenerated (trace_n > 1). */
            if (trace_n > 1) rec->ExceptionFlags |= EXCEPTION_STACK_INVALID;
            else
            {
                ERR( "[unwind-why] first-step bad frame — guest context was already bogus\n" );
                /* ml395 (task #60/#66): a bogus-context thread has no recoverable
                 * caller and no useful SEH — but letting it run the unhandled path
                 * kills the whole PSEUDO-PROCESS (ml395: webhelper died c0000005 in
                 * exactly this state moments after parking its chrome-ipc server;
                 * steam's IPC poller died the same way).  Terminate ONLY this
                 * thread: its work is lost either way, and the process — with the
                 * handshake threads we need alive — survives.  Known cost: any
                 * locks the thread held stay taken (ml389-class convoy risk) —
                 * still strictly better than process death. */
                ERR( "[bogus-ctx] terminating THREAD only (code=%lx) — process survives\n",
                     rec->ExceptionCode );
                NtTerminateThread( NtCurrentThread(), rec->ExceptionCode );
                /* not reached */
            }
            break;
        }

    ml633_frame_ok:
        if (dispatch.LanguageHandler)
        {
            TRACE( "calling handler %p (rec=%p, frame=%I64x context=%p, dispatch=%p)\n",
                   dispatch.LanguageHandler, rec, dispatch.EstablisherFrame, orig_context, &dispatch );
            /* iOS-Madeira #81 — RE-LANDED ml603, GATED, exactly as the ml477
             * revert note below instructed.
             *
             * The problem: LanguageHandler is ImageBase + unwind handler RVA,
             * i.e. a PE VA, and PE .text is non-executable here, so
             * call_seh_handler's `blr x11` faults on instruction fetch.  The
             * Mach handler redirects it correctly every time, but the pointer
             * is recomputed from unwind data on EVERY dispatch, so the
             * stale-VA healer can never make it stick — one kernel round-trip
             * per SEH handler call, forever.  ml475 proved wrapping it in
             * xlate_ios_jit() eliminates that: 786k faults -> 0.
             *
             * ml477 reverted it for two reasons, ONE OF WHICH IS NOW FALSE:
             *
             *  (a) "the storm ONLY occurs with --js-flags=--jitless OFF, and
             *      jitless-off is convicted anyway, so the fix buys nothing."
             *      >>> FALSIFIED by ml602 (db 7252): jitless was ON
             *      ([proc-gate] V8 JITLESS (interpreted) MADEIRA_JITLESS=1,
             *      cmdline-tail shows --js-flags=--jitless) and the storm still
             *      reached 791,552 exec faults, 749/1029 sampled at this exact
             *      handler.  The dominant site is ntdll's own
             *      nested_exception_handler (RVA 0x5b3c0) — installed by
             *      call_seh_handler's own .seh_handler directive, so every SEH
             *      dispatch pays it.  It spiralled: chrome_elf fast-fail ->
             *      exception -> nested handler exec-fault -> exception, until
             *      thread 00cc took c00000fd STATUS_STACK_OVERFLOW
             *      ([stack-ovf] showed libcef.dll+0x690ca2c x15) and the whole
             *      Steam UI froze with ~12 threads parked ~95s on events.
             *
             *  (b) "translating a handler that is x86-64 GUEST code defeats the
             *      __os_arm64x_dispatch_icall classification (see #52), so the
             *      emulator never gets it" — STILL TRUE, and is why the gate
             *      below is mandatory.  RtlIsEcCode() is the classifier's own
             *      predicate: translate only what is genuinely EC/native and
             *      leave guest handlers at their PE address so the icall thunk
             *      can route them into FEX.
             *
             * The revert note also said to log EVERY translation rather than
             * the first 4 per process, because that cap is what hid the guest
             * handler case.  Logging all ~790k would drown the log (and our own
             * Swift log pipeline), so instead every DISTINCT handler is logged
             * exactly once with its EC verdict — which is what actually makes an
             * unexpected guest handler visible — plus a periodic census.  If the
             * distinct table fills, that is logged too, so we are never
             * silently blind. */
            {
                PEXCEPTION_ROUTINE handler = dispatch.LanguageHandler;
                BOOLEAN is_ec = RtlIsEcCode( (ULONG_PTR)handler );

                if (is_ec)
                {
                    void *xl = xlate_ios_jit( handler );
                    if (xl) handler = (PEXCEPTION_ROUTINE)xl;
                }
                ios_seh_xlate_note( dispatch.LanguageHandler, handler, is_ec );

                res = call_seh_handler( rec, dispatch.EstablisherFrame, orig_context,
                                        &dispatch, handler );
            }
            rec->ExceptionFlags &= EXCEPTION_NONCONTINUABLE;
            TRACE( "handler at %p returned %lu\n", dispatch.LanguageHandler, res );

            switch (res)
            {
            case ExceptionContinueExecution:
                if (rec->ExceptionFlags & EXCEPTION_NONCONTINUABLE) return STATUS_NONCONTINUABLE_EXCEPTION;
                return STATUS_SUCCESS;
            case ExceptionContinueSearch:
                break;
            case ExceptionNestedException:
                rec->ExceptionFlags |= EXCEPTION_NESTED_CALL;
                TRACE( "nested exception\n" );
                break;
            case ExceptionCollidedUnwind:
                RtlVirtualUnwind( UNW_FLAG_NHANDLER, dispatch.ImageBase,
                                  dispatch.ControlPc, dispatch.FunctionEntry,
                                  &context.AMD64_Context, &dispatch.HandlerData, &frame, NULL );
                goto unwind_done;
            default:
                return STATUS_INVALID_DISPOSITION;
            }
        }
        /* hack: call wine handlers registered in the tib list */
        else while (is_valid_frame( (ULONG_PTR)teb_frame ) && (ULONG64)teb_frame < context.Sp)
        {
            TRACE( "calling TEB handler %p (rec=%p frame=%p context=%p dispatch=%p) sp=%I64x\n",
                   teb_frame->Handler, rec, teb_frame, orig_context, &dispatch, context.Sp );
            res = call_seh_handler( rec, (ULONG_PTR)teb_frame, orig_context,
                                    &dispatch, (PEXCEPTION_ROUTINE)teb_frame->Handler );
            TRACE( "TEB handler at %p returned %lu\n", teb_frame->Handler, res );

            switch (res)
            {
            case ExceptionContinueExecution:
                if (rec->ExceptionFlags & EXCEPTION_NONCONTINUABLE) return STATUS_NONCONTINUABLE_EXCEPTION;
                return STATUS_SUCCESS;
            case ExceptionContinueSearch:
                break;
            case ExceptionNestedException:
                rec->ExceptionFlags |= EXCEPTION_NESTED_CALL;
                TRACE( "nested exception\n" );
                break;
            case ExceptionCollidedUnwind:
                RtlVirtualUnwind( UNW_FLAG_NHANDLER, dispatch.ImageBase,
                                  dispatch.ControlPc, dispatch.FunctionEntry,
                                  &context.AMD64_Context, &dispatch.HandlerData, &frame, NULL );
                teb_frame = teb_frame->Prev;
                goto unwind_done;
            default:
                return STATUS_INVALID_DISPOSITION;
            }
            teb_frame = teb_frame->Prev;
        }

        if (context.Sp == (ULONG64)NtCurrentTeb()->Tib.StackBase) break;
    }
    } /* no-progress guard scope */
    return STATUS_UNHANDLED_EXCEPTION;
}


/*******************************************************************
 *		KiUserEmulationDispatcher (NTDLL.@)
 */
void dispatch_emulation( ARM64_NT_CONTEXT *arm_ctx )
{
    context_arm_to_x64( get_arm64ec_cpu_area()->ContextAmd64, arm_ctx );
    get_arm64ec_cpu_area()->InSimulation = 1;
    pBeginSimulation();
}
__ASM_GLOBAL_FUNC( "#KiUserEmulationDispatcher",
                   ".seh_context\n\t"
                   ".seh_endprologue\n\t"
                   "mov x0, sp\n\t"   /* context */
                   "bl dispatch_emulation\n\t"
                   "brk #1" )


/*******************************************************************
 *		dispatch_syscall
 */
static void dispatch_syscall( ARM64_NT_CONTEXT *context )
{
    if (context->X8 < __nb_syscalls)  /* syscall number in rax */
    {
        context->X0 = context->X4;  /* get first param from r10 */
        context->X4 = context->Pc;  /* and save return address to syscall thunk */
        context->Pc = (ULONG_PTR)invoke_arm64ec_syscall;
    }
    else context->X8 = STATUS_INVALID_SYSTEM_SERVICE;  /* set return value in rax */

    /* return to x64 code so that the syscall entry thunk is invoked properly */
    dispatch_emulation( context );
}


static void * __attribute__((used)) prepare_exception_arm64ec( EXCEPTION_RECORD *rec, ARM64EC_NT_CONTEXT *context, ARM64_NT_CONTEXT *arm_ctx )
{
    if (rec->ExceptionCode == STATUS_EMULATION_SYSCALL) dispatch_syscall( arm_ctx );
    context_arm_to_x64( context, arm_ctx );
    /* iOS-Madeira task#34 probe: FEX's LogMan output is invisible on iOS (its
     * write(2) resolves to the PE CRT's WriteFile → unplumbed std handle),
     * so trace the guest-exception conversion from the wine side. Rate-
     * capped; STATUS_EMULATION_SYSCALL is the hot syscall path and is
     * excluded. Log BEFORE and AFTER ResetToConsistentState so we can see
     * whether FEX reconstructed the guest Rip or the pool/JIT host pc leaks
     * through to the dispatchers. RtCS may not return (NtContinueNative). */
    {
        static LONG rtcs_n;
        if (rtcs_n < 40 && InterlockedIncrement( &rtcs_n ) <= 40)
            /* ml266 (#47): WHY did the guest fault? Name the guest RIP's memory.
             *
             * FEX's side is correct -- it reconstructs the context and rethrows onto the
             * guest stack -- so the fault is a genuine guest fault, and the interesting
             * question is what the guest RIP points at. Across two runs the value is
             * suspiciously structured, not random:
             *   ml265 rip=0x7e600e0080
             *   ml266 rip=0x7e200e0080
             * identical low 32 bits (0x000e0080) with a high half differing by exactly
             * 0x400000000 (16GB). A stable low half plus a 16GB-aligned high half is the
             * shape of a CORRUPTED POINTER, not a wild jump -- and 16GB is exactly the
             * PartitionAlloc pool granularity.
             *
             * Three outcomes need different fixes: the page is unmapped (the guest jumped
             * into nothing), mapped but NOT executable (a permissions/exec-interval bug
             * of the kind #36 fixed), or mapped+executable (then FEX's translation is at
             * fault, not the memory). Query it instead of theorising. Capped, and only
             * for access violations whose address IS the reported guest RIP. */
            if (rec->ExceptionCode == STATUS_ACCESS_VIOLATION)
            {
                static int ripq;
                ULONG64 grip = (ULONG64)(ULONG_PTR)rec->ExceptionAddress;

                /* ml273 CORRECTION #2. The ml270 attempt used xlate_ios_jit_rev to spot
                 * pool addresses, but that only translates addresses with a PE equivalent
                 * -- FEX-EMITTED dispatcher code in the pool tail has none, so it returned
                 * identity and the bogus "NOT COMMITTED (jumped into nothing)" verdict
                 * still printed for 0x15cbf8650.
                 *
                 * Use the real discriminator instead, straight out of the measured data:
                 * memory Wine does not own comes back with AllocationBase == 0 AND
                 * Type == 0 (ml270 0x1577f8700 and ml273 0x15cbf8650 both did), whereas a
                 * genuine Wine region always has both set (ml273 0x7c600e0080 gave
                 * alloc=0x7C60000000, type=MEM_PRIVATE). No pool bounds needed on the PE
                 * side, and it generalises to any foreign mapping. */
                if (ripq < 8 && grip > 0x1000)
                {
                    MEMORY_BASIC_INFORMATION mbi;
                    SIZE_T len = 0;
                    ripq++;
                    NTSTATUS qst = NtQueryVirtualMemory( NtCurrentProcess(),
                                                        (void *)(ULONG_PTR)grip,
                                                        MemoryBasicInformation, &mbi,
                                                        sizeof(mbi), &len );
                    /* ml274: query ONCE. The else-if used to re-invoke it, which printed a
                     * spurious second "FAILED" line for every verdict (5 vs 6 in ml274). */
                    if (!qst && !mbi.AllocationBase && !mbi.Type)
                        ERR( "[guest-rip] 0x%I64x -> Wine has NO VIEW of this address"
                             " (AllocationBase=0, Type=0) -- it is a foreign/JIT-pool"
                             " mapping, so no protection verdict is meaningful\n", grip );
                    else if (!qst)
                        ERR( "[guest-rip] 0x%I64x -> base=%p alloc=%p size=%I64x state=%lx "
                             "protect=%lx allocprot=%lx type=%lx %s\n",
                             grip, mbi.BaseAddress, mbi.AllocationBase,
                             (ULONG64)mbi.RegionSize, mbi.State, mbi.Protect,
                             mbi.AllocationProtect, mbi.Type,
                             mbi.State != MEM_COMMIT      ? "<-- NOT COMMITTED (jumped into nothing)" :
                             !(mbi.Protect & (PAGE_EXECUTE | PAGE_EXECUTE_READ |
                                              PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY))
                                                          ? "<-- COMMITTED but NOT EXECUTABLE"
                                                          : "<-- code address is VALID (fault is in the DATA the "
                                                            "instruction touches, not the RIP)" );
                    /* ml273: when the guest jumps somewhere non-executable, the useful
                     * question is WHO called it. The recurring target is alloc + 0xe0080
                     * with the same 0xe0080 offset every run (0x7e600e0080, 0x7e200e0080,
                     * 0x7c600e0080) into a private READ-WRITE PartitionAlloc region that
                     * is never protected executable -- so this is a call through a function
                     * pointer aimed at heap DATA, not a lost W^X flip. Dump the top of the
                     * guest stack and reverse-translate each slot, so the calling module is
                     * named instead of guessed. */
                    if (mbi.State == MEM_COMMIT &&
                        !(mbi.Protect & (PAGE_EXECUTE | PAGE_EXECUTE_READ |
                                         PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY)))
                    {
                        ULONG64 grsp = context->AMD64_Context.Rsp;
                        SIZE_T qlen = 0;
                        MEMORY_BASIC_INFORMATION smbi;

                        if (grsp && !NtQueryVirtualMemory( NtCurrentProcess(), (void *)(ULONG_PTR)grsp,
                                                           MemoryBasicInformation, &smbi,
                                                           sizeof(smbi), &qlen )
                            && smbi.State == MEM_COMMIT)
                        {
                            const ULONG64 *sp = (const ULONG64 *)(ULONG_PTR)grsp;
                            int k;
                            ERR( "[guest-caller] guest rsp=%I64x, top of stack:\n", grsp );
                            for (k = 0; k < 6; k++)
                            {
                                void *pe = xlate_ios_jit_rev( (void *)(ULONG_PTR)sp[k] );
                                ERR( "[guest-caller]   [%d] %I64x%s%p\n", k, sp[k],
                                     (pe && (ULONG64)(ULONG_PTR)pe != sp[k]) ? "  (pool -> PE " : "  (",
                                     pe );
                            }
                        }
                        else
                            ERR( "[guest-caller] guest rsp=%I64x is not readable —"
                                 " cannot name the caller\n", grsp );
                    }

                    /* iOS-Madeira ml631: THIS `else` WAS DANGLING.
                     *
                     * It hangs off the INNER committed-but-non-executable test, not off
                     * the `else if (!qst)` chain, so ANY executable page printed
                     * "NtQueryVirtualMemory FAILED" immediately after the successful
                     * query had already printed valid attributes. That read as the VM
                     * layer contradicting itself and cost a whole wrong hypothesis about
                     * why Mono declined the ULTRAKILL null fault. (The comment further up
                     * records ml274 fixing a DIFFERENT spurious "FAILED" on the same line
                     * — this is the second bug in one diagnostic.) Report the failure only
                     * when the query genuinely failed. */
                    else if (qst)
                        ERR( "[guest-rip] 0x%I64x -> NtQueryVirtualMemory FAILED status=%08x"
                             " (address is not in this address space at all)\n",
                             grip, (unsigned int)qst );

                    /* ml631: GUEST BYTES FROM BOTH VIEWS, at the RECONSTRUCTED guest RIP.
                     *
                     * ULTRAKILL dies on `ldaprb w6,[x8]` with x8=0, and FEX computed that
                     * zero twelve bytes earlier (`movz w7,#0` + `madd w8,w6,w7,wzr`). Only
                     * the guest x86 can say whether that is faithful. Print 32 bytes either
                     * side, and — because the page is a Mono JIT buffer with an RW alias —
                     * the SAME range through the alias, so a disagreement between the two
                     * views is visible immediately.
                     *
                     * Bounded and read-only: capped firings, no allocation, no locks; the
                     * unix probe is a pure table walk. */
                    /* iOS-Madeira ml636: DO NOT GATE ON "the page is executable".
                     *
                     * The ml635 gate required NtQueryVirtualMemory to classify the
                     * reconstructed RIP as executable — which CANNOT hold for the very case
                     * this telemetry exists for: a RIP exactly one-past a Mono alias. The
                     * probe now also matches an alias ENDING at the RIP, so let it decide. */
                    if (rec->ExceptionCode == 0xc0000005)
                    {
                        static int gb_n;
                        if (gb_n < 4)
                        {
                            struct ios_jit_alias_probe_params pp;
                            const unsigned char *rx = (const unsigned char *)(ULONG_PTR)(grip - 32);
                            char line[3 * 64 + 8];
                            unsigned i, off = 0;
                            gb_n++;

                            /* ml635: ask FIRST, so the byte dump can be clipped to the
                             * mapping. The ml634 fatal RIP was EXACTLY one-past the alias
                             * end, so reading RIP+31 would fault inside the handler. */
                            memset( &pp, 0, sizeof(pp) );
                            pp.size = sizeof(pp); pp.version = 1; pp.addr = grip;
                            WINE_UNIX_CALL( unix_ios_jit_alias_probe, &pp );
                            if (!pp.base)   /* not an end match — ask about the byte window */
                            {
                                memset( &pp, 0, sizeof(pp) );
                                pp.size = sizeof(pp); pp.version = 1; pp.addr = grip - 32;
                                WINE_UNIX_CALL( unix_ios_jit_alias_probe, &pp );
                            }
                            {
                                unsigned lim = 64;
                                if (pp.end && grip - 32 < pp.end && pp.end - (grip - 32) < 64)
                                    lim = (unsigned)(pp.end - (grip - 32));
                                for (i = 0; i < lim; i++)
                                    off += sprintf( line + off, "%02x ", rx[i] );
                                /* ml637: `lim - 32 - 1` wrapped when lim==32 and printed
                                 * "+4294967295". Print the byte count, not a signed range. */
                                ERR( "[guest-bytes] ml631 #%d RIP=0x%I64x RX from -32, %u bytes: %s%s\n",
                                     gb_n, grip, lim, line,
                                     lim < 64 ? "   (clipped at mapping end)" : "" );
                            }
                            if (pp.base)
                            {
                                ERR( "[smc-gen] ml636 #%d alias=[0x%I64x,0x%I64x) size=0x%I64x write_gen=%u "
                                     "written16k=%08x highest=0x%I64x RIP_off=0x%I64x %s\n",
                                     gb_n, pp.base, pp.end, pp.end - pp.base, pp.write_gen, pp.written,
                                     pp.highest, grip - pp.base,
                                     pp.at_end ? "<== RIP IS EXACTLY THE ALIAS END (one past)" : "" );
                                /* ml637: `highest` is the highest store START seen (+1), not the
                                 * highest byte written — note_write() only receives the address,
                                 * so a 2/4/8/16/32-byte store understates the extent by up to 31.
                                 * The tail verdict's 256-byte tolerance absorbs that, but do not
                                 * read it as byte-exact. */
                                ERR( "[smc-gen] ml637 #%d NOTE: highest = highest store START +1 "
                                     "(understates by up to 31 bytes; width not plumbed through)\n", gb_n );
                                ERR( "[smc-gen] ml636 #%d TAIL VERDICT: highest written 0x%I64x of 0x%I64x — %s\n",
                                     gb_n, pp.highest, pp.end - pp.base,
                                     !pp.highest ? "**NEVER WRITTEN AT ALL**" :
                                     pp.highest + 256 >= pp.end - pp.base
                                         ? "tail WAS written (reaches the very end)"
                                         : "**TAIL NEVER WRITTEN** — control ran past the real code" );
                                /* iOS-Madeira ml639: WHICH OF THE THREE VIEWS DETACHED?
                                 *
                                 * guest = user_va+off, poolRX = jit_rx_alias+off,
                                 * poolRW = jit_rw_alias+off. All three are the SAME physical
                                 * pages when the dual-map and the vm_remap are both intact.
                                 * Hashing the first 16KB -- the only chunk ever written, and
                                 * where the divergence lives -- localises the break:
                                 *   guest==RX != RW  -> the pool's RX/RW pair detached
                                 *   guest != RX==RW  -> the guest vm_remap detached
                                 *   guest==RW != RX  -> the pool RX mapping alone detached
                                 *   all three differ -> stale slot / multiple remaps
                                 * dup_end also settles the "matched a duplicate entry" theory. */
                                if (pp.rw_base && pp.rx_base)
                                {
                                    const unsigned char *g  = (const unsigned char *)(ULONG_PTR)pp.base;
                                    const unsigned char *px = (const unsigned char *)(ULONG_PTR)pp.rx_base;
                                    const unsigned char *pw = (const unsigned char *)(ULONG_PTR)pp.rw_base;
                                    ULONG64 hg = 1469598103934665603ull, hx = hg, hw = hg;
                                    unsigned k;
                                    for (k = 0; k < 0x4000; k++)
                                    {
                                        hg = (hg ^ g[k])  * 1099511628211ull;
                                        hx = (hx ^ px[k]) * 1099511628211ull;
                                        hw = (hw ^ pw[k]) * 1099511628211ull;
                                    }
                                    ERR( "[3view] ml639 #%d slot=%u dup_end=%u guest=%p poolRX=%p poolRW=%p\n",
                                         gb_n, pp.slot, pp.dup_end, (void *)(ULONG_PTR)pp.base,
                                         (void *)(ULONG_PTR)pp.rx_base, (void *)(ULONG_PTR)pp.rw_base );
                                    ERR( "[3view] ml639 #%d HASH16K guest=%016I64x poolRX=%016I64x poolRW=%016I64x => %s\n",
                                         gb_n, hg, hx, hw,
                                         (hg == hx && hx == hw) ? "ALL THREE AGREE" :
                                         (hg == hx)             ? "guest==poolRX, poolRW DETACHED" :
                                         (hx == hw)             ? "poolRX==poolRW, GUEST vm_remap DETACHED" :
                                         (hg == hw)             ? "guest==poolRW, poolRX DETACHED" :
                                                                  "ALL THREE DIFFER (stale slot / multiple remaps)" );
                                    {
                                        ULONG64 offs[2];
                                        unsigned oi;
                                        offs[0] = 0x1368;                                   /* verified coherent earlier */
                                        offs[1] = pp.highest >= 32 ? pp.highest - 32 : 0;   /* the divergence */
                                        for (oi = 0; oi < 2; oi++)
                                        {
                                            char a[3*32+4], b[3*32+4], c[3*32+4];
                                            unsigned q = 0, r = 0, t = 0;
                                            ULONG64 o = offs[oi];
                                            for (k = 0; k < 32; k++)
                                            {
                                                q += sprintf( a + q, "%02x ", g[o+k] );
                                                r += sprintf( b + r, "%02x ", px[o+k] );
                                                t += sprintf( c + t, "%02x ", pw[o+k] );
                                            }
                                            ERR( "[3view] ml639 #%d @+0x%I64x  guest: %s\n", gb_n, o, a );
                                            ERR( "[3view] ml639 #%d @+0x%I64x poolRX: %s\n", gb_n, o, b );
                                            ERR( "[3view] ml639 #%d @+0x%I64x poolRW: %s\n", gb_n, o, c );
                                        }
                                    }
                                }

                                /* ml637: dump the LAST WRITTEN bytes, not the last bytes of the
                                 * buffer. ml636 printed [end-128,end) — all zeros by definition when
                                 * the tail was never written, which told us nothing. The bytes that
                                 * matter are just below `highest`: in the ml636 run that is
                                 * 0x33e0..0x33fd, i.e. the block FEX started at and the last code
                                 * Mono ever emitted. This is what shows whether that block is a
                                 * complete, correctly terminated sequence. */
                                if (pp.highest >= 128 && pp.rw)
                                {
                                    const unsigned char *wrx = (const unsigned char *)(ULONG_PTR)
                                                               (pp.base + pp.highest - 128);
                                    const unsigned char *wrw = (const unsigned char *)(ULONG_PTR)
                                                               (pp.rw + pp.highest - 128);
                                    char w1[3*128+8], w2[3*128+8];
                                    unsigned k, q1 = 0, q2 = 0, wdiff = 0;
                                    for (k = 0; k < 128; k++)
                                    {
                                        q1 += sprintf( w1 + q1, "%02x ", wrx[k] );
                                        q2 += sprintf( w2 + q2, "%02x ", wrw[k] );
                                        if (wrx[k] != wrw[k]) wdiff = 1;
                                    }
                                    ERR( "[smc-gen] ml637 #%d LASTWRITTEN[0x%I64x-128,0x%I64x) RX: %s\n",
                                         gb_n, pp.highest, pp.highest, w1 );
                                    ERR( "[smc-gen] ml637 #%d LASTWRITTEN RW: %s (%s)\n", gb_n, w2,
                                         wdiff ? "**RX/RW DIFFER**" : "RX/RW match" );
                                }
                                if (pp.end - pp.base >= 128 && pp.rw)
                                {
                                    const unsigned char *trx = (const unsigned char *)(ULONG_PTR)(pp.end - 128);
                                    const unsigned char *trw = (const unsigned char *)(ULONG_PTR)
                                                               (pp.rw + (pp.end - 128 - pp.base));
                                    char t1[3*128+8], t2[3*128+8];
                                    unsigned k, o1 = 0, o2 = 0, diff = 0;
                                    for (k = 0; k < 128; k++)
                                    {
                                        o1 += sprintf( t1 + o1, "%02x ", trx[k] );
                                        o2 += sprintf( t2 + o2, "%02x ", trw[k] );
                                        if (trx[k] != trw[k]) diff = 1;
                                    }
                                    ERR( "[smc-gen] ml636 #%d TAIL RX -128: %s\n", gb_n, t1 );
                                    ERR( "[smc-gen] ml636 #%d TAIL RW -128: %s (%s)\n", gb_n, t2,
                                         diff ? "**RX/RW DIFFER**" : "RX/RW match" );
                                }
                            }
                            /* ml637: SKIP the generic dump at an end match. It compares
                             * pp.rw[0..63] — the START of the RW buffer — against rx[0..63]
                             * where rx = RIP-32, so rx[32..63] lies OUTSIDE the mapping. That
                             * is both a mismatched comparison and a potential fault INSIDE the
                             * exception handler. The tail/last-written dumps above supersede it. */
                            if (pp.at_end)
                                ERR( "[guest-bytes] ml637 #%d generic RX/RW compare SKIPPED (end match — "
                                     "would read past the mapping)\n", gb_n );
                            else if (pp.rw)
                            {
                                const unsigned char *rw = (const unsigned char *)(ULONG_PTR)pp.rw;
                                int differ = 0;
                                off = 0;
                                for (i = 0; i < 64; i++)
                                {
                                    off += sprintf( line + off, "%02x ", rw[i] );
                                    if (rw[i] != rx[i]) differ = 1;
                                }
                                ERR( "[guest-bytes] ml631 #%d rw=0x%I64x alias=[0x%I64x,0x%I64x) RW  -32..+31: %s\n",
                                     gb_n, pp.rw, pp.base, pp.end, line );
                                ERR( "[guest-bytes] ml631 #%d VERDICT: RX and RW %s\n",
                                     gb_n, differ ? "**DIFFER** — alias coherency/finalisation"
                                                  : "MATCH — the guest bytes are what FEX compiled" );
                            }
                            else
                                ERR( "[guest-bytes] ml631 #%d no RW alias for 0x%I64x"
                                     " (not an anon-JIT page)\n", gb_n, grip );
                        }
                    }
                }
            }
            ERR( "[rtcs] pre: code=%08x addr=%p armPc=%p ecRip=%p rtcs=%p insim=%u\n",
                 (unsigned int)rec->ExceptionCode, rec->ExceptionAddress,
                 (void *)(ULONG_PTR)arm_ctx->Pc, (void *)(ULONG_PTR)context->AMD64_Context.Rip,
                 pResetToConsistentState, get_arm64ec_cpu_area()->InSimulation );
    }
    if (pResetToConsistentState) pResetToConsistentState( rec, &context->AMD64_Context, arm_ctx );
    {
        static LONG rtcs_m;
        if (rtcs_m < 40 && InterlockedIncrement( &rtcs_m ) <= 40)
            ERR( "[rtcs] post: code=%08x addr=%p ecRip=%p ecRsp=%p armPc=%p\n",
                 (unsigned int)rec->ExceptionCode, rec->ExceptionAddress,
                 (void *)(ULONG_PTR)context->AMD64_Context.Rip, (void *)(ULONG_PTR)context->AMD64_Context.Rsp,
                 (void *)(ULONG_PTR)arm_ctx->Pc );
    }
    /* call x64 dispatcher if the thunk or the function pointer was modified */
    /* iOS-Madeira ml409 (#66): the fatal [bogus-ctx] walks a context whose Rsp
     * high dword became exactly 1 and whose Rip/Rbp/R12 turned into FEX-band
     * host pointers with recurring low bits, while [rtcs] post had printed the
     * SAME context fields correct moments earlier. The corruption window is
     * prepare-return → call_seh_handlers, which contains exactly two guest
     * re-entry points: the patched-thunk redirect below, and the vectored
     * handlers in dispatch_exception. Bracket it: name the path taken here,
     * and log the context around each guest handler (exception.c [veh],
     * call_seh_handlers [seh-entry]). Capped, AV-only. */
    {
        int patched = memcmp( KiUserExceptionDispatcher_thunk, KiUserExceptionDispatcher_orig,
                              sizeof(KiUserExceptionDispatcher_orig) ) != 0;
        if (rec->ExceptionCode == STATUS_ACCESS_VIOLATION)
        {
            static LONG kipath_n;
            if (kipath_n < 60 && InterlockedIncrement( &kipath_n ) <= 60)
                ERR( "[ki-path] code=%08x ctx=%p Rsp=%p Rip=%p -> %s (patched=%d wow64=%p)\n",
                     (unsigned int)rec->ExceptionCode, context,
                     (void *)(ULONG_PTR)context->AMD64_Context.Rsp,
                     (void *)(ULONG_PTR)context->AMD64_Context.Rip,
                     (pWow64PrepareForException || patched) ? "x64-THUNK (guest hook runs)" : "direct dispatch",
                     patched, pWow64PrepareForException );
        }
        if (pWow64PrepareForException || patched)
            return KiUserExceptionDispatcher_thunk;
    }
    return NULL;
}

/*******************************************************************
 *		KiUserExceptionDispatcher (NTDLL.@)
 */
void __attribute__((naked)) KiUserExceptionDispatcher( EXCEPTION_RECORD *rec, CONTEXT *context )
{
    asm( ".seh_proc \"#KiUserExceptionDispatcher\"\n\t"
         ".seh_context\n\t"
         "sub sp, sp, #0x4d0\n\t"       /* sizeof(ARM64EC_NT_CONTEXT) */
         ".seh_stackalloc 0x4d0\n\t"
         ".seh_endprologue\n\t"
         "add x0, sp, #0x3b0+0x4d0\n\t" /* rec */
         "mov x1, sp\n\t"               /* context */
         "add x2, sp, #0x4d0\n\t"       /* arm_ctx (context + 1) */
         "bl \"#prepare_exception_arm64ec\"\n\t"
         "cbz x0, 1f\n\t"
         /* bypass exit thunk to avoid messing up the stack */
         "adrp x16, __os_arm64x_dispatch_call_no_redirect\n\t"
         "ldr x16, [x16, #:lo12:__os_arm64x_dispatch_call_no_redirect]\n\t"
         /* iOS-Madeira (task#29): in a child pseudo-process's private ntdll copy
          * this slot is sometimes still NULL (per-process ntdll global not
          * populated; arm64ec_process_init_dispatchers SKIPs ntdll re-patch).
          * A NULL x16 here → `blr x16` to 0 → SEGV loop → dead thread (observed
          * killing steam.exe). The `blr x16` path is only a stack-cleanliness
          * optimization; label 1 (dispatch_exception) is the full, correct
          * ARM64EC SEH dispatcher. So if the slot is NULL, fall through to it. */
         "cbz x16, 1f\n\t"
         "mov x9, x0\n\t"
         "blr x16\n"
         "1:\tadd x0, sp, #0x3b0+0x4d0\n\t" /* rec */
         "mov x1, sp\n\t"                   /* context */
         "bl #dispatch_exception\n\t"
         "brk #1\n\t"
         ".seh_endproc" );
}


/*******************************************************************
 *		KiUserApcDispatcher (NTDLL.@)
 */
static void __attribute__((used)) dispatch_apc( void (CALLBACK *func)(ULONG_PTR,ULONG_PTR,ULONG_PTR,CONTEXT*),
                                                ULONG_PTR arg1, ULONG_PTR arg2, ULONG_PTR arg3,
                                                BOOLEAN alertable, ARM64_NT_CONTEXT *arm_ctx )
{
    ARM64EC_NT_CONTEXT context;

    context_arm_to_x64( &context, arm_ctx );
    func( arg1, arg2, arg3, &context.AMD64_Context );
    NtContinue( &context.AMD64_Context, alertable );
}
__ASM_GLOBAL_FUNC( "#KiUserApcDispatcher",
                   ".seh_context\n\t"
                   "nop\n\t"
                   ".seh_stackalloc 0x30\n\t"
                   ".seh_endprologue\n\t"
                   "ldp x0, x1, [sp]\n\t"         /* func, arg1 */
                   "ldp x2, x3, [sp, #0x10]\n\t"  /* arg2, arg3 */
                   "ldr w4, [sp, #0x20]\n\t"      /* alertable */
                   "add x5, sp, #0x30\n\t"        /* context */
                   "bl \"#dispatch_apc\"\n\t"
                   "brk #1" )


/*******************************************************************
 *		KiUserCallbackDispatcher (NTDLL.@)
 */
__ASM_GLOBAL_FUNC( "#KiUserCallbackDispatcher",
                   ".seh_pushframe\n\t"
                   "nop\n\t"
                   ".seh_stackalloc 0x20\n\t"
                   "nop\n\t"
                   ".seh_save_reg lr, 0x18\n\t"
                   ".seh_endprologue\n\t"
                   ".seh_handler user_callback_handler, @except\n\t"
                   "ldr x0, [sp]\n\t"             /* args */
                   "ldp w1, w2, [sp, #0x08]\n\t"  /* len, id */
                   "ldr x3, [x18, 0x60]\n\t"      /* peb */
                   "ldr x3, [x3, 0x58]\n\t"       /* peb->KernelCallbackTable */
                   "ldr x15, [x3, x2, lsl #3]\n\t"
                   "blr x15\n\t"
                   ".globl \"#KiUserCallbackDispatcherReturn\"\n"
                   "\"#KiUserCallbackDispatcherReturn\":\n\t"
                   "mov x2, x0\n\t"               /* status */
                   "mov x1, #0\n\t"               /* ret_len */
                   "mov x0, x1\n\t"               /* ret_ptr */
                   "bl \"#NtCallbackReturn\"\n\t"
                   "bl \"#RtlRaiseStatus\"\n\t"
                   "brk #1" )


/**************************************************************************
 *              RtlIsEcCode (NTDLL.@)
 */
/* iOS-Madeira: highest address the EcCodeBitMap can actually represent.
 *
 * The 0x800000000000 (48-bit) bound below was WRONG for this port. alloc_arm64ec_map()
 * sizes the bitmap from min(address_space_limit, host_addr_space_limit) rather than
 * Windows' theoretical 128TB, because at one bit per 4KB page the full range costs a
 * 4.06GB reservation — the single largest tenant of a VA window we cannot spare. On
 * iOS that yields 0x8000000000 (512GB) of coverage, i.e. a 16MB view.
 *
 * That sizing was justified with "every other bitmap user derives its index from the
 * ADDRESS being marked, so none can index past the smaller view". RtlIsEcCode breaks
 * the assumption: it is a READER, and it is handed addresses that never came from our
 * allocator — guest/unwind contexts carry legal *Windows* pointers far above our VA.
 * Steam hit exactly that: RtlIsEcCode(0x7300ffffffff) passed the 128TB check, indexed
 * 0x74d6ddfff8 (past the 16MB view) and segfaulted, killing the thread 5 times per
 * spawn and looping ~9 times (ml161).
 *
 * Derive the bound from the view's ACTUAL size so it can never disagree with the
 * allocation, whatever the ceiling does later. Wine answers this query from its own
 * view list, so RegionSize is the exact view size (no host adjacent-region merging).
 * Coverage = bytes * 8 bits * page_size. */
static ULONG_PTR ec_code_map_limit( void )
{
    static ULONG_PTR cached;   /* benign race: all racers compute the same value */

    if (!cached)
    {
        MEMORY_BASIC_INFORMATION mbi;
        const char *map = NtCurrentTeb()->Peb->EcCodeBitMap;
        ULONG_PTR limit = 0x800000000000ULL;
        SIZE_T total = 0, len = 0;
        const char *p = map;
        unsigned int guard;

        /* Walk the WHOLE allocation. A single MemoryBasicInformation query returns only
           the first run of uniform protection, and this view is a patchwork: pages that
           get marked are committed RW by set_vprot while the rest stay RO. ml163 measured
           RegionSize = 0x24000 (144KB) for a view that [ec-map] reports as 0x1000000
           (16MB) — a 116x under-estimate that failed the self-check below. Accumulate
           every sub-region sharing our AllocationBase to recover the true size. */
        for (guard = 0; map && guard < 4096; guard++)
        {
            if (NtQueryVirtualMemory( NtCurrentProcess(), p, MemoryBasicInformation,
                                      &mbi, sizeof(mbi), &len )) break;
            if (len < sizeof(mbi) || !mbi.RegionSize) break;
            if (mbi.AllocationBase != (void *)map) break;
            total += mbi.RegionSize;
            p += mbi.RegionSize;
        }

        if (total)
        {
            ULONG_PTR cover = (ULONG_PTR)total * 8 * page_size;

            /* SELF-CHECK before trusting the query. Reporting a genuinely-EC address as
               non-EC is far worse than the OOB read this bound exists to prevent: the
               caller would dispatch EC code through the x64 path and jump wild (the
               "BUS EXEC in JIT .data" signature). This very function is EC code, so a
               correct limit must cover it. If the query says otherwise, distrust it and
               keep the old 48-bit bound rather than break dispatch.

               Two floors, because &RtlIsEcCode resolves to the JIT-POOL copy (~0x1xxxxxxxx)
               and would be satisfied by a coverage still far too small for the PE module
               range (~0x73xxxxxxxx). The bitmap is itself allocated in that high region,
               so a correct coverage must also exceed its own address. */
            if (cover > (ULONG_PTR)&RtlIsEcCode && cover > (ULONG_PTR)map && cover < limit)
                limit = cover;
            else if (cover)
                ERR( "EcCodeBitMap coverage %p too small (own code %p, map %p) — keeping %p\n",
                     (void *)cover, (void *)&RtlIsEcCode, map, (void *)limit );
        }
        TRACE( "EcCodeBitMap map=%p limit=%p\n", map, (void *)limit );
        cached = limit;
    }
    return cached;
}

BOOLEAN WINAPI RtlIsEcCode( ULONG_PTR ptr )
{
    const UINT64 *map = (const UINT64 *)NtCurrentTeb()->Peb->EcCodeBitMap;
    ULONG_PTR page = ptr / page_size;
    /* The EcCodeBitMap covers only what alloc_arm64ec_map actually reserved. Querying
       any pointer beyond that — a legal Windows address above our VA, or a corrupted
       one from a damaged unwind context — must not segfault. */
    if (!map || ptr >= ec_code_map_limit()) return FALSE;
    return (map[page / 64] >> (page & 63)) & 1;
}


/* unwind context by one call frame */
/* iOS-Madeira ml703: returns whether a real function entry was found and used.
 *
 * Unwind info is registered for PE VAs, but code physically executes from the
 * JIT-pool alias, so context->Rip is a POOL VA here.  RtlLookupFunctionEntry
 * then finds nothing, RtlVirtualUnwind treats the frame as a leaf, pops a zero
 * return address off the stack and yields Rip=0 -- which do_setjmpex used to
 * copy over a perfectly good jump buffer (LibreMines/Qt5: libjpeg's longjmp
 * error path unwound to RIP 0 and the guest branched to address zero).
 * virtual_unwind() already reverse-translates for exactly this reason; mirror
 * it.  xlate_ios_jit_rev() resolves by REGISTERED ALIAS IDENTITY and returns
 * its input unchanged when there is no PE counterpart, so addresses that were
 * never pool-mapped are unaffected -- it is not guessing from address ranges. */
static BOOL unwind_one_frame( CONTEXT *context )
{
    extern void *xlate_ios_jit_rev( void *ptr );
    void *data;
    ULONG_PTR base, frame, pc = context->Rip - 4;
    ULONG_PTR lookup_pc = (ULONG_PTR)xlate_ios_jit_rev( (void *)pc );
    RUNTIME_FUNCTION *func = RtlLookupFunctionEntry( lookup_pc, &base, NULL );

    if (!func) return FALSE;
    RtlVirtualUnwind( UNW_FLAG_NHANDLER, base, lookup_pc, func, context, &data, &frame, NULL );
    return TRUE;
}

/* capture context information; helper for RtlCaptureContext */
static void __attribute__((used)) capture_context( CONTEXT *context, UINT cpsr, UINT fpcr, UINT fpsr )
{
    CONTEXT unwind_context;

    context->ContextFlags = CONTEXT_AMD64_FULL;
    context->EFlags = cpsr_to_eflags( cpsr );
    context->MxCsr = fpcsr_to_mxcsr( fpcr, fpsr );
    context->FltSave.ControlWord = 0x27f;
    context->FltSave.StatusWord = 0;
    context->FltSave.MxCsr = context->MxCsr;

    /* unwind one level to get register values from caller function */
    unwind_context = *context;
    unwind_one_frame( &unwind_context );
    memcpy( &context->Rax, &unwind_context.Rax, offsetof(CONTEXT,FltSave) - offsetof(CONTEXT,Rax) );
}

/***********************************************************************
 *		RtlCaptureContext (NTDLL.@)
 */
void __attribute__((naked)) RtlCaptureContext( CONTEXT *context )
{
    asm( ".seh_proc \"#RtlCaptureContext\"\n\t"
         ".seh_endprologue\n\t"
         "stp x8, x0,   [x0, #0x78]\n\t"    /* context->Rax,Rcx */
         "stp x1, x27,  [x0, #0x88]\n\t"    /* context->Rdx,Rbx */
         "mov x1, sp\n\t"
         "stp x1, x29,  [x0, #0x98]\n\t"    /* context->Rsp,Rbp */
         "stp x25, x26, [x0, #0xa8]\n\t"    /* context->Rsi,Rdi */
         "stp x2, x3,   [x0, #0xb8]\n\t"    /* context->R8,R9 */
         "stp x4, x5,   [x0, #0xc8]\n\t"    /* context->R10,R11 */
         "stp x19, x20, [x0, #0xd8]\n\t"    /* context->R12,R13 */
         "stp x21, x22, [x0, #0xe8]\n\t"    /* context->R14,R15 */
         "str x30,      [x0, #0xf8]\n\t"    /* context->Rip */
         "ubfx x1, x16, #0, #16\n\t"
         "stp x30, x1,  [x0, #0x120]\n\t"   /* context->FloatRegisters[0] */
         "ubfx x1, x16, #16, #16\n\t"
         "stp x6, x1,   [x0, #0x130]\n\t"   /* context->FloatRegisters[1] */
         "ubfx x1, x16, #32, #16\n\t"
         "stp x7, x1,   [x0, #0x140]\n\t"   /* context->FloatRegisters[2] */
         "ubfx x1, x16, #48, #16\n\t"
         "stp x9, x1,   [x0, #0x150]\n\t"   /* context->FloatRegisters[3] */
         "ubfx x1, x17, #0, #16\n\t"
         "stp x10, x1,  [x0, #0x160]\n\t"   /* context->FloatRegisters[4] */
         "ubfx x1, x17, #16, #16\n\t"
         "stp x11, x1,  [x0, #0x170]\n\t"   /* context->FloatRegisters[5] */
         "ubfx x1, x17, #32, #16\n\t"
         "stp x12, x1,  [x0, #0x180]\n\t"   /* context->FloatRegisters[6] */
         "ubfx x1, x17, #48, #16\n\t"
         "stp x15, x1,  [x0, #0x190]\n\t"   /* context->FloatRegisters[7] */
         "stp q0, q1,   [x0, #0x1a0]\n\t"   /* context->Xmm0,Xmm1 */
         "stp q2, q3,   [x0, #0x1c0]\n\t"   /* context->Xmm2,Xmm3 */
         "stp q4, q5,   [x0, #0x1e0]\n\t"   /* context->Xmm4,Xmm5 */
         "stp q6, q7,   [x0, #0x200]\n\t"   /* context->Xmm6,Xmm7 */
         "stp q8, q9,   [x0, #0x220]\n\t"   /* context->Xmm8,Xmm9 */
         "stp q10, q11, [x0, #0x240]\n\t"   /* context->Xmm10,Xmm11 */
         "stp q12, q13, [x0, #0x260]\n\t"   /* context->Xmm12,Xmm13 */
         "stp q14, q15, [x0, #0x280]\n\t"   /* context->Xmm14,Xmm15 */
         "mrs x1, nzcv\n\t"
         "mrs x2, fpcr\n\t"
         "mrs x3, fpsr\n\t"
         "b \"#capture_context\"\n\t"
         ".seh_endproc" );
}

/* fixup jump buffer information; helper for _setjmpex */
static int __attribute__((used)) do_setjmpex( _JUMP_BUFFER *buf, UINT fpcr, UINT fpsr )
{
    CONTEXT context = { .ContextFlags = CONTEXT_FULL };

    buf->MxCsr = fpcsr_to_mxcsr( fpcr, fpsr );
    buf->FpCsr = 0x27f;

    context.Rbx = buf->Rbx;
    context.Rsp = buf->Rsp;
    context.Rbp = buf->Rbp;
    context.Rsi = buf->Rsi;
    context.Rdi = buf->Rdi;
    context.R12 = buf->R12;
    context.R13 = buf->R13;
    context.R14 = buf->R14;
    context.R15 = buf->R15;
    context.Rip = buf->Rip;
    memcpy( &context.Xmm6, &buf->Xmm6, 10 * sizeof(context.Xmm6) );

    /* ml703: the copy-back below replaces the registers NTDLL__setjmpex just
     * stored with the unwound caller's.  That is only correct when the unwind
     * ACTUALLY SUCCEEDED and landed on x64 code.  A failed unwind yields
     * Rip=0, which RtlIsEcCode() reports as "not EC" -- i.e. it used to be
     * misread as "the caller is x64", zeroing a valid buffer.  Require all
     * three: the lookup found a function entry, the result is plausible, and
     * it really is x64 code. */
    {
        BOOL unwound = unwind_one_frame( &context );
        static int n_sj;

        if (n_sj < 24)   /* [setjmp-life] ml702 probe, retained */
        {
            n_sj++;
            ERR( "[setjmp-life] ml702 setjmp#%d buf=%p | STORED Frame=%p Rip=%p Rsp=%p Rbx=%p"
                 " | UNWOUND ok=%d Rip=%p Rsp=%p | isEc(post)=%d -> %s\n",
                 n_sj, buf, (void *)buf->Frame, (void *)buf->Rip, (void *)buf->Rsp, (void *)buf->Rbx,
                 unwound, (void *)context.Rip, (void *)context.Rsp,
                 (int)RtlIsEcCode( context.Rip ),
                 (unwound && context.Rip && !RtlIsEcCode( context.Rip ))
                     ? "COPY-BACK (real x64 caller)" : "KEEP stores" );
        }

        if (unwound && context.Rip && !RtlIsEcCode( context.Rip ))
    {
        buf->Rbx = context.Rbx;
        buf->Rsp = context.Rsp;
        buf->Rbp = context.Rbp;
        buf->Rsi = context.Rsi;
        buf->Rdi = context.Rdi;
        buf->R12 = context.R12;
        buf->R13 = context.R13;
        buf->R14 = context.R14;
        buf->R15 = context.R15;
        buf->Rip = context.Rip;
        memcpy( &buf->Xmm6, &context.Xmm6, 10 * sizeof(context.Xmm6) );
        }
    }
    {
        static int n_out;
        if (n_out < 24)
        {
            n_out++;
            ERR( "[setjmp-life] ml702 setjmp-exit#%d buf=%p FINAL Frame=%p Rip=%p Rsp=%p Rbx=%p\n",
                 n_out, buf, (void *)buf->Frame, (void *)buf->Rip, (void *)buf->Rsp, (void *)buf->Rbx );
        }
    }
    return 0;
}

/***********************************************************************
 *		_setjmpex (NTDLL.@)
 */
int __attribute__((naked)) NTDLL__setjmpex( _JUMP_BUFFER *buf, void *frame )
{
    asm( ".seh_proc \"#NTDLL__setjmpex\"\n\t"
         ".seh_endprologue\n\t"
         "stp x1, x27,  [x0]\n\t"          /* jmp_buf->Frame,Rbx */
         "mov x1, sp\n\t"
         "stp x1, x29,  [x0, #0x10]\n\t"   /* jmp_buf->Rsp,Rbp */
         "stp x25, x26, [x0, #0x20]\n\t"   /* jmp_buf->Rsi,Rdi */
         "stp x19, x20, [x0, #0x30]\n\t"   /* jmp_buf->R12,R13 */
         "stp x21, x22, [x0, #0x40]\n\t"   /* jmp_buf->R14,R15 */
         "str x30,      [x0, #0x50]\n\t"   /* jmp_buf->Rip */
         "stp d8, d9,   [x0, #0x80]\n\t"   /* jmp_buf->Xmm8,Xmm9 */
         "stp d10, d11, [x0, #0xa0]\n\t"   /* jmp_buf->Xmm10,Xmm11 */
         "stp d12, d13, [x0, #0xc0]\n\t"   /* jmp_buf->Xmm12,Xmm13 */
         "stp d14, d15, [x0, #0xe0]\n\t"   /* jmp_buf->Xmm14,Xmm15 */
         "mrs x1, fpcr\n\t"
         "mrs x2, fpsr\n\t"
         "b \"#do_setjmpex\"\n\t"
         ".seh_endproc" );
}


/**********************************************************************
 *           call_consolidate_callback
 *
 * Wrapper function to call a consolidate callback from a fake frame.
 * If the callback executes RtlUnwindEx (like for example done in C++ handlers),
 * we have to skip all frames which were already processed. To do that we
 * trick the unwinding functions into thinking the call came from somewhere
 * else.
 */
static void __attribute__((naked,noreturn)) consolidate_callback( CONTEXT *context,
                                                                  void *(CALLBACK *callback)(EXCEPTION_RECORD *),
                                                                  EXCEPTION_RECORD *rec )
{
    asm( ".seh_proc consolidate_callback\n\t"
         "stp x29, x30, [sp, #-16]!\n\t"
         ".seh_save_fplr_x 16\n\t"
         "sub sp, sp, #0x4d0\n\t"
         ".seh_stackalloc 0x4d0\n\t"
         ".seh_endprologue\n\t"
         "mov x4, sp\n\t"
         /* copy the context onto the stack */
         "mov x5, #0x4d0/16\n"      /* sizeof(CONTEXT) */
         "1:\tldp x6, x7, [x0], #16\n\t"
         "stp x6, x7, [x4], #16\n\t"
         "subs x5, x5, #1\n\t"
         "b.ne 1b\n\t"
         "mov x0, x2\n\t"           /* rec */
         "b invoke_callback\n\t"
         ".seh_endproc\n\t"
         ".seh_proc invoke_callback\n"
         "invoke_callback:\n\t"
         ".seh_ec_context\n\t"
         ".seh_endprologue\n\t"
         "mov x11, x1\n\t"          /* callback */
         "adr x10, $iexit_thunk$cdecl$i8$i8\n\t"
         "adrp x16, __os_arm64x_dispatch_icall\n\t"
         "ldr x16, [x16, #:lo12:__os_arm64x_dispatch_icall]\n\t"
         "blr x16\n\t"
         "blr x11\n\t"
         "str x0, [sp, #0xf8]\n\t"  /* context->Rip */
         "mov x0, sp\n\t"           /* context */
         "mov w1, #0\n\t"
         "bl \"#NtContinue\"\n\t"
         ".seh_endproc" );
}


/*******************************************************************
 *              RtlRestoreContext (NTDLL.@)
 */
void CDECL RtlRestoreContext( CONTEXT *context, EXCEPTION_RECORD *rec )
{
    EXCEPTION_REGISTRATION_RECORD *teb_frame = NtCurrentTeb()->Tib.ExceptionList;

    if (rec && rec->ExceptionCode == STATUS_LONGJUMP && rec->NumberParameters >= 1)
    {
        struct _JUMP_BUFFER *jmp = (struct _JUMP_BUFFER *)rec->ExceptionInformation[0];

        context->Rbx   = jmp->Rbx;
        context->Rsp   = jmp->Rsp;
        context->Rbp   = jmp->Rbp;
        context->Rsi   = jmp->Rsi;
        context->Rdi   = jmp->Rdi;
        context->R12   = jmp->R12;
        context->R13   = jmp->R13;
        context->R14   = jmp->R14;
        context->R15   = jmp->R15;
        context->Rip   = jmp->Rip;
        context->MxCsr = jmp->MxCsr;
        context->FltSave.MxCsr = jmp->MxCsr;
        context->FltSave.ControlWord = jmp->FpCsr;
        memcpy( &context->Xmm6, &jmp->Xmm6, 10 * sizeof(M128A) );
    }
    else if (rec && rec->ExceptionCode == STATUS_UNWIND_CONSOLIDATE && rec->NumberParameters >= 1)
    {
        void * (CALLBACK *consolidate)(EXCEPTION_RECORD *) = (void *)rec->ExceptionInformation[0];
        TRACE( "calling consolidate callback %p (rec=%p)\n", consolidate, rec );
        consolidate_callback( context, consolidate, rec );
    }

    /* hack: remove no longer accessible TEB frames */
    while (is_valid_frame( (ULONG_PTR)teb_frame ) && (ULONG64)teb_frame < context->Rsp)
    {
        TRACE( "removing TEB frame: %p\n", teb_frame );
        teb_frame = __wine_pop_frame( teb_frame );
    }

    TRACE( "returning to %p stack %p\n", (void *)context->Rip, (void *)context->Rsp );
    NtContinue( context, FALSE );
}


/*******************************************************************
 *		RtlUnwindEx (NTDLL.@)
 */
void WINAPI RtlUnwindEx( PVOID end_frame, PVOID target_ip, EXCEPTION_RECORD *rec,
                         PVOID retval, CONTEXT *context, UNWIND_HISTORY_TABLE *table )
{
    EXCEPTION_REGISTRATION_RECORD *teb_frame = NtCurrentTeb()->Tib.ExceptionList;
    DISPATCHER_CONTEXT_NONVOLREG_ARM64 nonvol_regs;
    EXCEPTION_RECORD record;
    DISPATCHER_CONTEXT_ARM64EC dispatch;
    ARM64EC_NT_CONTEXT new_context;
    NTSTATUS status;
    ULONG_PTR frame;
    DWORD i, res;
    BOOL is_target_ec = RtlIsEcCode( (ULONG_PTR)target_ip );

    RtlCaptureContext( context );
    new_context.AMD64_Context = *context;

    /* build an exception record, if we do not have one */
    if (!rec)
    {
        record.ExceptionCode    = STATUS_UNWIND;
        record.ExceptionFlags   = 0;
        record.ExceptionRecord  = NULL;
        record.ExceptionAddress = (void *)context->Rip;
        record.NumberParameters = 0;
        rec = &record;
    }

    rec->ExceptionFlags |= EXCEPTION_UNWINDING | (end_frame ? 0 : EXCEPTION_EXIT_UNWIND);

    /* iOS-Madeira 2026-07-04: [UNW_RATE] — [SEH_RATE] in call_seh_handlers
     * stayed at zero while PROF shows the render worker living in
     * virtual_unwind/RtlVirtualUnwind2, so THIS entry point (phase-2
     * unwind without dispatch = longjmp / handled unwinds) must be the
     * hot caller. code=STATUS_UNWIND (0xC0000027) with a synthesized
     * record means a NULL-rec caller — longjmp's signature. Log first +
     * every 1024th: rate, code, source Rip, target. */
    {
        static LONG unw_count;
        LONG n = InterlockedIncrement( &unw_count );
        if (n == 1 || (n & 0x3FF) == 0)
            ERR( "[UNW_RATE] n=%d code=%08x from=%p target=%p\n",
                 (int)n, (int)rec->ExceptionCode, rec->ExceptionAddress, target_ip );
    }

    TRACE( "code=%lx flags=%lx end_frame=%p target_ip=%p\n",
           rec->ExceptionCode, rec->ExceptionFlags, end_frame, target_ip );
    for (i = 0; i < min( EXCEPTION_MAXIMUM_PARAMETERS, rec->NumberParameters ); i++)
        TRACE( " info[%ld]=%016I64x\n", i, rec->ExceptionInformation[i] );
    TRACE_CONTEXT( context );

    dispatch.TargetIp         = (ULONG64)target_ip;
    dispatch.ContextRecord    = context;
    dispatch.HistoryTable     = table;
    dispatch.NonVolatileRegisters = nonvol_regs.Buffer;

    /* ml617: establish the guest-stack window from the ORIGINAL RSP before the
     * first step, so every frame below is bounded by the allocation the thread
     * was actually running on. */
    ec_stack_window_begin( (ULONG_PTR)context->Rsp );

    for (;;)
    {
        status = virtual_unwind( UNW_FLAG_UHANDLER, &dispatch, &new_context );
        if (status != STATUS_SUCCESS) raise_status( status, rec );

    unwind_done:
        if (!dispatch.EstablisherFrame) break;

        {
            const char *why = ec_stack_window_step( dispatch.EstablisherFrame,
                                                    (ULONG_PTR)dispatch.ControlPc );
            if (why)
            {
                /* ⛔ Do NOT synthesize a replacement exception. ml616 lost the real
                 * fault (execute AV at private RW heap) and reported a stack
                 * fragment as the status. Report everything needed to trust this
                 * rejection, then stop unwinding and let the ORIGINAL record go. */
                ERR( "[unwind-guard] ml617 STOPPING unwind: %s | orig_code=%08x orig_addr=%p "
                     "orig_rsp=%I64x stack=[%I64x..%I64x) emu=[%I64x..%I64x] "
                     "rejected_frame=%I64x prev_frame=%I64x ControlPc=%I64x steps=%u budget=%u\n",
                     why, (int)rec->ExceptionCode, rec->ExceptionAddress,
                     (ULONG64)context->Rsp, (ULONG64)ec_win.lo, (ULONG64)ec_win.hi,
                     (ULONG64)ec_win.emu_lo, (ULONG64)ec_win.emu_hi,
                     (ULONG64)dispatch.EstablisherFrame, (ULONG64)ec_win.last_frame,
                     (ULONG64)dispatch.ControlPc, ec_win.steps, ec_win.budget );
                rec->ExceptionFlags |= EXCEPTION_STACK_INVALID;
                break;
            }
        }

        if (!is_valid_arm64ec_frame( dispatch.EstablisherFrame ))
        {
            /* ml221: report WHY the walk produced this frame, not just that it did.
             *
             * The frame that killed the webhelper was 0x73c9f70008 -- 8 bytes into
             * DWrite.dll's read-only headers, i.e. the walk had run off the end of the
             * guest stack. That happens when ControlPc stays a JIT-pool VA: function
             * tables are registered at PE VAs, so no unwind info is found and the frames
             * are garbage. virtual_unwind reverse-translates via
             * p_ios_jit_reverse_translate_addr, but that pointer lives in ntdll's .data
             * and every pseudo-process gets a CLONED copy -- if a child's copy is NULL the
             * translation silently degrades to identity. Print it, plus ControlPc, so the
             * two cases are distinguishable instead of guessed at. */
            ERR( "invalid frame %I64x (%p-%p) ControlPc=%I64x xlate_rev=%p%s\n",
                 dispatch.EstablisherFrame,
                 NtCurrentTeb()->Tib.StackLimit, NtCurrentTeb()->Tib.StackBase,
                 (ULONG64)dispatch.ControlPc, p_ios_jit_reverse_translate_addr,
                 p_ios_jit_reverse_translate_addr ? "" : "  <-- NULL: unwind ran in POOL space" );
            rec->ExceptionFlags |= EXCEPTION_STACK_INVALID;
            break;
        }

        if (dispatch.LanguageHandler)
        {
            if (end_frame && (dispatch.EstablisherFrame > (ULONG64)end_frame))
            {
                ERR( "invalid end frame %I64x/%p\n", dispatch.EstablisherFrame, end_frame );
                raise_status( STATUS_INVALID_UNWIND_TARGET, rec );
            }
            if (dispatch.EstablisherFrame == (ULONG64)end_frame) rec->ExceptionFlags |= EXCEPTION_TARGET_UNWIND;

            TRACE( "calling handler %p (rec=%p, frame=%I64x context=%p, dispatch=%p)\n",
                   dispatch.LanguageHandler, rec, dispatch.EstablisherFrame,
                   dispatch.ContextRecord, &dispatch );
            res = call_unwind_handler( rec, dispatch.EstablisherFrame, dispatch.ContextRecord,
                                       &dispatch, dispatch.LanguageHandler );
            TRACE( "handler %p returned %lx\n", dispatch.LanguageHandler, res );

            switch (res)
            {
            case ExceptionContinueSearch:
                rec->ExceptionFlags &= ~EXCEPTION_COLLIDED_UNWIND;
                break;
            case ExceptionCollidedUnwind:
                new_context.AMD64_Context = *context;
                RtlVirtualUnwind( UNW_FLAG_NHANDLER, dispatch.ImageBase, dispatch.ControlPc,
                                  dispatch.FunctionEntry, &new_context.AMD64_Context,
                                  &dispatch.HandlerData, &frame, NULL );
                rec->ExceptionFlags |= EXCEPTION_COLLIDED_UNWIND;
                goto unwind_done;
            default:
                raise_status( STATUS_INVALID_DISPOSITION, rec );
                break;
            }
        }
        else  /* hack: call builtin handlers registered in the tib list */
        {
            while (is_valid_arm64ec_frame( (ULONG_PTR)teb_frame ) &&
                   (ULONG64)teb_frame < new_context.Sp &&
                   (ULONG64)teb_frame < (ULONG64)end_frame)
            {
                TRACE( "calling TEB handler %p (rec=%p, frame=%p context=%p, dispatch=%p)\n",
                       teb_frame->Handler, rec, teb_frame, dispatch.ContextRecord, &dispatch );
                res = call_unwind_handler( rec, (ULONG_PTR)teb_frame, dispatch.ContextRecord, &dispatch,
                                           (PEXCEPTION_ROUTINE)teb_frame->Handler );
                TRACE( "handler at %p returned %lu\n", teb_frame->Handler, res );
                teb_frame = __wine_pop_frame( teb_frame );

                switch (res)
                {
                case ExceptionContinueSearch:
                    rec->ExceptionFlags &= ~EXCEPTION_COLLIDED_UNWIND;
                    break;
                case ExceptionCollidedUnwind:
                    new_context.AMD64_Context = *context;
                    RtlVirtualUnwind( UNW_FLAG_NHANDLER, dispatch.ImageBase, dispatch.ControlPc,
                                      dispatch.FunctionEntry, &new_context.AMD64_Context,
                                      &dispatch.HandlerData, &frame, NULL );
                    rec->ExceptionFlags |= EXCEPTION_COLLIDED_UNWIND;
                    goto unwind_done;
                default:
                    raise_status( STATUS_INVALID_DISPOSITION, rec );
                    break;
                }
            }
            if ((ULONG64)teb_frame == (ULONG64)end_frame && (ULONG64)end_frame < new_context.Sp) break;
        }

        if (dispatch.EstablisherFrame == (ULONG64)end_frame)
        {
            if (is_target_ec) break;
            if (!RtlIsEcCode( dispatch.ControlPc )) break;
            /* we just crossed into x64 code, unwind one more frame */
        }
        *context = new_context.AMD64_Context;
    }

    if (rec->ExceptionCode != STATUS_UNWIND_CONSOLIDATE)
        context->Rip = (ULONG64)target_ip;
    else if (rec->ExceptionInformation[10] == -1)
        rec->ExceptionInformation[10] = (ULONG_PTR)&nonvol_regs;

    if (is_target_ec) context->Rcx = (ULONG64)retval;
    else context->Rax = (ULONG64)retval;
    RtlRestoreContext( context, rec );
}


/*************************************************************************
 *		RtlGetNativeSystemInformation (NTDLL.@)
 */
NTSTATUS WINAPI RtlGetNativeSystemInformation( SYSTEM_INFORMATION_CLASS class,
                                               void *info, ULONG size, ULONG *ret_size )
{
    return syscall_NtQuerySystemInformation( class, info, size, ret_size );
}


/***********************************************************************
 *           RtlIsProcessorFeaturePresent [NTDLL.@]
 */
BOOLEAN WINAPI RtlIsProcessorFeaturePresent( UINT feature )
{
    static const ULONGLONG arm64_features =
        (1ull << PF_COMPARE_EXCHANGE_DOUBLE) |
        (1ull << PF_NX_ENABLED) |
        (1ull << PF_ARM_VFP_32_REGISTERS_AVAILABLE) |
        (1ull << PF_ARM_NEON_INSTRUCTIONS_AVAILABLE) |
        (1ull << PF_SECOND_LEVEL_ADDRESS_TRANSLATION) |
        (1ull << PF_FASTFAIL_AVAILABLE) |
        (1ull << PF_ARM_DIVIDE_INSTRUCTION_AVAILABLE) |
        (1ull << PF_ARM_64BIT_LOADSTORE_ATOMIC) |
        (1ull << PF_ARM_EXTERNAL_CACHE_AVAILABLE) |
        (1ull << PF_ARM_FMAC_INSTRUCTIONS_AVAILABLE) |
        (1ull << PF_ARM_V8_INSTRUCTIONS_AVAILABLE) |
        (1ull << PF_ARM_V8_CRYPTO_INSTRUCTIONS_AVAILABLE) |
        (1ull << PF_ARM_V8_CRC32_INSTRUCTIONS_AVAILABLE) |
        (1ull << PF_ARM_V81_ATOMIC_INSTRUCTIONS_AVAILABLE) |
        (1ull << PF_ARM_V82_DP_INSTRUCTIONS_AVAILABLE) |
        (1ull << PF_ARM_V83_JSCVT_INSTRUCTIONS_AVAILABLE) |
        (1ull << PF_ARM_V83_LRCPC_INSTRUCTIONS_AVAILABLE) |
        (1ull << PF_ARM_SVE_INSTRUCTIONS_AVAILABLE) |
        (1ull << PF_ARM_SVE2_INSTRUCTIONS_AVAILABLE) |
        (1ull << PF_ARM_SVE2_1_INSTRUCTIONS_AVAILABLE) |
        (1ull << PF_ARM_SVE_AES_INSTRUCTIONS_AVAILABLE) |
        (1ull << PF_ARM_SVE_PMULL128_INSTRUCTIONS_AVAILABLE) |
        (1ull << PF_ARM_SVE_BITPERM_INSTRUCTIONS_AVAILABLE) |
        (1ull << PF_ARM_SVE_BF16_INSTRUCTIONS_AVAILABLE) |
        (1ull << PF_ARM_SVE_EBF16_INSTRUCTIONS_AVAILABLE) |
        (1ull << PF_ARM_SVE_B16B16_INSTRUCTIONS_AVAILABLE) |
        (1ull << PF_ARM_SVE_SHA3_INSTRUCTIONS_AVAILABLE) |
        (1ull << PF_ARM_SVE_SM4_INSTRUCTIONS_AVAILABLE) |
        (1ull << PF_ARM_SVE_I8MM_INSTRUCTIONS_AVAILABLE) |
        (1ull << PF_ARM_SVE_F32MM_INSTRUCTIONS_AVAILABLE) |
        (1ull << PF_ARM_SVE_F64MM_INSTRUCTIONS_AVAILABLE) |
        (1ull << PF_ARM_LSE2_AVAILABLE);

    if (feature >= PROCESSOR_FEATURE_MAX) return FALSE;
    if (arm64_features & (1ull << feature)) return user_shared_data->ProcessorFeatures[feature];
    return emulated_processor_features[feature];
}


/*************************************************************************
 *		RtlWalkFrameChain (NTDLL.@)
 */
ULONG WINAPI RtlWalkFrameChain( void **buffer, ULONG count, ULONG flags )
{
    UNWIND_HISTORY_TABLE table;
    RUNTIME_FUNCTION *func;
    PEXCEPTION_ROUTINE handler;
    ULONG_PTR pc, frame, base;
    CONTEXT context;
    void *data;
    ULONG i, skip = flags >> 8, num_entries = 0;

    RtlCaptureContext( &context );

    for (i = 0; i < count; i++)
    {
        pc = context.Rip;
        if ((context.ContextFlags & CONTEXT_UNWOUND_TO_CALL) && RtlIsEcCode( pc )) pc -= 4;
        func = RtlLookupFunctionEntry( pc, &base, &table );
        if (RtlVirtualUnwind2( UNW_FLAG_NHANDLER, base, pc, func, &context, NULL,
                               &data, &frame, NULL, NULL, NULL, &handler, 0 ))
            break;
        if (!context.Rip) break;
        if (!frame || !is_valid_frame( frame )) break;
        if (context.Rsp == (ULONG_PTR)NtCurrentTeb()->Tib.StackBase) break;
        if (i >= skip) buffer[num_entries++] = (void *)context.Rip;
    }
    return num_entries;
}


/*************************************************************************
 *		__wine_unix_call_arm64ec
 */
NTSTATUS __attribute__((naked)) __wine_unix_call_arm64ec( unixlib_handle_t handle, unsigned int code, void *args )
{
    asm( ".seh_proc \"#__wine_unix_call_arm64ec\"\n\t"
         ".seh_endprologue\n\t"
         "adrp x16, __wine_unix_call_dispatcher_arm64ec\n\t"
         "ldr x16, [x16, #:lo12:__wine_unix_call_dispatcher_arm64ec]\n\t"
         "br x16\n\t"
         ".seh_endproc" );
}

NTSTATUS (WINAPI *__wine_unix_call_dispatcher_arm64ec)( unixlib_handle_t, unsigned int, void * ) = __wine_unix_call_arm64ec;

static void __attribute__((naked)) arm64x_check_call_early(void)
{
    asm( "mov x11, x9\n\t"
         "ret" );
}

static void __attribute__((naked)) arm64x_check_icall_early(void)
{
    asm( "ret" );
}

/**************************************************************************
 *		arm64x_check_call
 *
 * Implementation of __os_arm64x_check_call.
 */
static void __attribute__((naked)) arm64x_check_call(void)
{
    asm( ".seh_proc \"#arm64x_check_call\"\n\t"
         ".seh_endprologue\n\t"
         /* check for EC code */
         /* iOS-Madeira ml238 ROOT-CAUSE FIX: read the TEB from TPIDRRO_EL0 + TSD slot 275,
          * NOT from x18. iOS clobbers x18 (every SEGV dump in this port shows x18=0), so
          * `ldr x16,[x18,#0x60]` fetched a garbage PEB, the EcCodeBitMap pointer was
          * garbage, the bit test read 0, and this function reported EVERY target as
          * non-EC. __os_arm64x_check_icall then selected the EC->x64 exit thunk even for
          * genuinely native targets -- while RtlIsEcCode (C, via NtCurrentTeb()'s TSD
          * path) correctly said EC, which is exactly the contradiction we measured:
          * IsEcCode(fp)=1 yet the exit thunk still ran.
          *
          * For variadic callees that thunk does `stp x4,x5,[sp,#0x20]`, flattening the
          * ARM64EC variadic descriptor (x4 = stack-arg pointer, x5 = size) into the x64
          * arg5/arg6 slots -- producing ROpenSCManagerW's dwDesiredAccess = a pointer and
          * lpScHandle = 0x10 (the SIZE), i.e. the ccontext == 0x10 livelock.
          *
          * FEX's own check_target_ec already does this (IOS_LOAD_TEB); Wine's copy never
          * did. x16 is scratch here, so the load is free of side effects. */
         /* iOS-Madeira ml246: this x18 read IS WRONG, and is deliberately kept anyway.
          *
          * iOS clobbers x18 (every SEGV dump in this port shows x18=0), so this fetches a
          * garbage PEB, the EcCodeBitMap pointer is garbage, the bit test reads 0, and this
          * function reports EVERY target as non-EC. FEX's check_target_ec reads the TEB via
          * TPIDRRO_EL0 + TSD slot 275 (IOS_LOAD_TEB) for exactly this reason.
          *
          * Correcting it (mrs TPIDRRO_EL0 / and #~7 / ldr [#0x898] / ldr [#0x60]) was tried
          * and A/B-PROVEN to break CEF: cef_log.txt went unwritten for 8 consecutive runs
          * and returned the moment this line was restored (ml246, run depth also 20-24k ->
          * 28929 calls). Reporting everything non-EC forces all indirect calls through the
          * x64 exit thunk, which is slow and breaks VARIADIC callees (the ccontext == 0x10
          * RPC crash) -- but that detour also absorbs whatever EcCodeBitMap false positive
          * the correct version turns into a direct branch into x64 bytes executed as ARM64.
          *
          * So: correct-but-unlandable until that false positive is found. The fixed version
          * is preserved in the task notes. Do not "fix" this without re-running the CEF
          * check -- verifying IsEcCode flips 0->1 does NOT prove the outcome still works. */
         "ldr x16, [x18, #0x60]\n\t"        /* peb -- see above, intentionally x18 */
         "lsr x17, x11, #18\n\t"            /* dest / page_size / 64 */
         "ldr x16, [x16, #0x368]\n\t"       /* peb->EcCodeBitMap */
         "lsr x9, x11, #12\n\t"             /* dest / page_size */
         "ldr x16, [x16, x17, lsl #3]\n\t"
         "lsr x16, x16, x9\n\t"
         "tbnz x16, #0, .Ldone\n\t"
         /* check if dest is aligned */
         "tst x11, #15\n\t"                 /* dest & 15 */
         "b.ne .Ljmp\n\t"
         "ldr x16, [x11]\n\t"               /* dest code */
         /* check for fast-forward sequence */
         "ldr x17, .Lffwd_seq\n\t"
         "cmp x16, x17\n\t"
         "b.ne .Lsyscall\n\t"
         "ldr x16, [x11, #8]\n\t"
         "ldr x17, .Lffwd_seq + 8\n\t"
         "eor x17, x16, x17\n\t"            /* compare only first two bytes */
         "tst x17, #0xffff\n\t"
         "b.ne .Lexit\n\t"
         "add x11, x11, #14\n\t"            /* address after jump */
         "lsr x9, x16, #16\n\t"
         "add x11, x11, w9, sxtw\n\t"       /* add offset */
         "ret\n"
         /* check for syscall sequence */
         ".Lsyscall:\n\t"
         "ldr w17, .Lsyscall_seq\n\t"
         "cmp w16, w17\n\t"
         "b.ne .Ljmp\n\t"
         "ubfx x9, x16, #32, #12\n\t"       /* syscall number */
         "ldr x16, [x11, #8]\n\t"
         "ldr x17, .Lsyscall_seq + 8\n\t"
         "cmp x16, x17\n\t"
         "b.ne .Lexit\n\t"
         "ldr x16, [x11, #16]\n\t"
         "ldr x17, .Lsyscall_seq + 16\n\t"
         "cmp x16, x17\n\t"
         "b.ne .Lexit\n\t"
         "cmp x9, #%0\n\t"
         "b.hs .Lexit\n\t"
         "adr x11, arm64ec_syscalls\n\t"
         "ldr x11, [x11, x9, lsl #3]\n\t"
         "ret\n"
         /* check for jmp sequence */
         ".Ljmp:\n\t"
         "ldrb w16, [x11]\n\t"
         "cmp w16, #0xff\n\t"
         "b.ne .Lexit\n\t"
         "ldrb w16, [x11, #1]\n\t"
         "cmp w16, #0x25\n\t"               /* ff 25 jmp *xxx(%rip) */
         "b.ne .Lexit\n\t"
         "ldr w9, [x11, #2]\n\t"
         "add x16, x11, #6\n\t"             /* address after jump */
         "ldr x11, [x16, w9, sxtw]\n\t"
         "b \"#arm64x_check_call\"\n"       /* restart checks with jump destination */
         /* not a special sequence, call the exit thunk */
         ".Lexit:\n\t"
         "mov x9, x11\n\t"
         "mov x11, x10\n\t"
         ".Ldone:\n\t"
         "ret\n"
         ".seh_endproc\n\t"

         ".Lffwd_seq:\n\t"
         ".byte 0x48, 0x8b, 0xc4\n\t"       /* mov  %rsp,%rax */
         ".byte 0x48, 0x89, 0x58, 0x20\n\t" /* mov  %rbx,0x20(%rax) */
         ".byte 0x55\n"                     /* push %rbp */
         ".byte 0x5d\n\t"                   /* pop  %rbp */
         ".byte 0xe9\n\t"                   /* jmp  arm_code */
         ".byte 0, 0, 0, 0, 0, 0\n"

         ".Lsyscall_seq:\n\t"
         ".byte 0x4c, 0x8b, 0xd1\n\t"       /* mov  %rcx,%r10 */
         ".byte 0xb8, 0, 0, 0, 0\n\t"       /* mov  $xxx,%eax */
         ".byte 0xf6, 0x04, 0x25, 0x08\n\t" /* testb $0x1,0x7ffe0308 */
         ".byte 0x03, 0xfe, 0x7f, 0x01\n\t"
         ".byte 0x75, 0x03\n\t"             /* jne 1f */
         ".byte 0x0f, 0x05\n\t"             /* syscall */
         ".byte 0xc3\n\t"                   /* ret */
         ".byte 0xcd, 0x2e\n\t"             /* 1: int $0x2e */
         ".byte 0xc3"                       /* ret */
         :: "i" (__nb_syscalls) );
}


/**************************************************************************
 *		__chkstk_arm64ec (NTDLL.@)
 *
 * Supposed to touch all the stack pages, but we shouldn't need that.
 */
void __attribute__((naked)) __chkstk_arm64ec(void)
{
    asm( "ret" );
}


/*******************************************************************
 *		__C_ExecuteExceptionFilter
 */
LONG __attribute__((naked)) __C_ExecuteExceptionFilter( EXCEPTION_POINTERS *ptrs, void *frame,
                                                        PEXCEPTION_FILTER filter, BYTE *nonvolatile )
{
    asm( ".seh_proc _C_ExecuteExceptionFilter\n\t"
         "stp x29, x30, [sp, #-80]!\n\t"
         ".seh_save_fplr_x 80\n\t"
         "stp x19, x20, [sp, #16]\n\t"
         ".seh_save_regp x19, 16\n\t"
         "stp x21, x22, [sp, #32]\n\t"
         ".seh_save_regp x21, 32\n\t"
         "stp x25, x26, [sp, #48]\n\t"
         ".seh_save_regp x25, 48\n\t"
         "str x27, [sp, #64]\n\t"
         ".seh_save_reg x27, 64\n\t"
         ".seh_endprologue\n\t"
         "ldp x19, x20, [x3, #0]\n\t" /* nonvolatile regs */
         "ldp x21, x22, [x3, #16]\n\t"
         "ldp x25, x26, [x3, #48]\n\t"
         "ldr x27, [x3, #64]\n\t"
         "ldr x1,  [x3, #80]\n\t"     /* x29 = frame */
         "blr x2\n\t"                 /* filter */
         "ldp x19, x20, [sp, #16]\n\t"
         "ldp x21, x22, [sp, #32]\n\t"
         "ldp x25, x26, [sp, #48]\n\t"
         "ldr x27,      [sp, #64]\n\t"
         "ldp x29, x30, [sp], #80\n\t"
         "ret\n\t"
         ".seh_endproc" );
}


/***********************************************************************
 *		RtlRaiseException (NTDLL.@)
 */
void __attribute((naked)) RtlRaiseException( EXCEPTION_RECORD *rec )
{
    asm( ".seh_proc \"#RtlRaiseException\"\n\t"
         "sub sp, sp, #0x4d0\n\t"     /* sizeof(context) */
         ".seh_stackalloc 0x4d0\n\t"
         "stp x29, x30, [sp, #-0x20]!\n\t"
         ".seh_save_fplr_x 0x20\n\t"
         "str x0, [sp, #0x10]\n\t"
         ".seh_save_any_reg x0, 0x10\n\t"
         ".seh_endprologue\n\t"
         "add x0, sp, #0x20\n\t"
         "bl \"#RtlCaptureContext\"\n\t"
         "add x1, sp, #0x20\n\t"       /* context pointer */
         "ldr x0, [sp, #0x10]\n\t"     /* rec */
         "ldr x2, [x1, #0xf8]\n\t"     /* context->Rip */
         "str x2, [x0, #0x10]\n\t"     /* rec->ExceptionAddress */
         "ldr w2, [x1, #0x30]\n\t"     /* context->ContextFlags */
         "orr w2, w2, #0x20000000\n\t" /* CONTEXT_UNWOUND_TO_CALL */
         "str w2, [x1, #0x30]\n\t"
         "ldr x3, [x18, #0x60]\n\t"    /* peb */
         "ldrb w2, [x3, #2]\n\t"       /* peb->BeingDebugged */
         "cbnz w2, 1f\n\t"
         "bl \"#dispatch_exception\"\n"
         "1:\tmov w2, #1\n\t"
         "bl \"#NtRaiseException\"\n\t"
         "b \"#RtlRaiseStatus\"\n\t" /* does not return */
         ".seh_endproc" );
}


/*******************************************************************
 *		longjmp (NTDLL.@)
 */
void __cdecl NTDLL_longjmp( _JUMP_BUFFER *buf, int retval )
{
    EXCEPTION_RECORD rec;

    if (!retval) retval = 1;

    {   /* ml702 [setjmp-life]: what the buffer holds at the moment of use.  If
         * this is zero the unwind target is zero and the guest branches to 0. */
        static int n_lj;
        if (n_lj < 24)
        {
            n_lj++;
            ERR( "[setjmp-life] ml702 longjmp#%d buf=%p retval=%d Frame=%p Rip=%p Rsp=%p Rbx=%p Rsi=%p Rdi=%p\n",
                 n_lj, buf, retval, (void *)buf->Frame, (void *)buf->Rip, (void *)buf->Rsp,
                 (void *)buf->Rbx, (void *)buf->Rsi, (void *)buf->Rdi );
        }
    }

    rec.ExceptionCode = STATUS_LONGJUMP;
    rec.ExceptionFlags = 0;
    rec.ExceptionRecord = NULL;
    rec.ExceptionAddress = NULL;
    rec.NumberParameters = 1;
    rec.ExceptionInformation[0] = (DWORD_PTR)buf;
    RtlUnwind( (void *)buf->Frame, (void *)buf->Rip, &rec, IntToPtr(retval) );
}


/***********************************************************************
 *           RtlUserThreadStart (NTDLL.@)
 */
void __attribute__((naked)) RtlUserThreadStart( PRTL_THREAD_START_ROUTINE entry, void *arg )
{
    asm( ".seh_proc \"#RtlUserThreadStart\"\n\t"
         "stp x29, x30, [sp, #-16]!\n\t"
         ".seh_save_fplr_x 16\n\t"
         ".seh_endprologue\n\t"
         "adrp x11, pBaseThreadInitThunk\n\t"
         "ldr x11, [x11, #:lo12:pBaseThreadInitThunk]\n\t"
         "adr x10, $iexit_thunk$cdecl$v$i8i8i8\n\t"
         "mov x2, x1\n\t"
         "mov x1, x0\n\t"
         "mov x0, #0\n\t"
         "adrp x16, __os_arm64x_dispatch_icall\n\t"
         "ldr x16, [x16, #:lo12:__os_arm64x_dispatch_icall]\n\t"
         "blr x16\n\t"
         "blr x11\n\t"
         "brk #1\n\t"
         ".seh_handler call_unhandled_exception_handler, @except\n\t"
         ".seh_endproc" );
}


/******************************************************************
 *		LdrInitializeThunk (NTDLL.@)
 */
void WINAPI LdrInitializeThunk( CONTEXT *arm_context, ULONG_PTR unk2, ULONG_PTR unk3, ULONG_PTR unk4 )
{
    ARM64EC_NT_CONTEXT context;

    if (!__os_arm64x_check_call)
    {
        __os_arm64x_check_call = arm64x_check_call_early;
        __os_arm64x_check_icall = arm64x_check_icall_early;
        __os_arm64x_check_icall_cfg = arm64x_check_icall_early;
        __os_arm64x_get_x64_information = LdrpGetX64Information;
        __os_arm64x_set_x64_information = LdrpSetX64Information;
    }

    context_arm_to_x64( &context, (ARM64_NT_CONTEXT *)arm_context );
    loader_init( &context.AMD64_Context, (void **)&context.X0 );
    TRACE_(relay)( "\1Starting thread proc %p (arg=%p)\n", (void *)context.X0, (void *)context.X1 );
    NtContinue( &context.AMD64_Context, TRUE );
}


/***********************************************************************
 *           process_breakpoint
 */
__ASM_GLOBAL_FUNC( "#process_breakpoint",
                   ".seh_endprologue\n\t"
                   ".seh_handler process_breakpoint_handler, @except\n\t"
                   "brk #0xf000\n\t"
                   "ret\n"
                   "process_breakpoint_handler:\n\t"
                   "ldr x4, [x2, #0x108]\n\t" /* context->Pc */
                   "add x4, x4, #4\n\t"
                   "str x4, [x2, #0x108]\n\t"
                   "mov w0, #0\n\t"           /* ExceptionContinueExecution */
                   "ret" )


/***********************************************************************
 *		DbgUiRemoteBreakin   (NTDLL.@)
 */
void __attribute__((naked)) DbgUiRemoteBreakin( void *arg )
{
    asm( ".seh_proc \"#DbgUiRemoteBreakin\"\n\t"
         "stp x29, x30, [sp, #-16]!\n\t"
         ".seh_save_fplr_x 16\n\t"
         ".seh_endprologue\n\t"
         ".seh_handler DbgUiRemoteBreakin_handler, @except\n\t"
         "ldr x0, [x18, #0x60]\n\t"  /* NtCurrentTeb()->Peb */
         "ldrb w0, [x0, 0x02]\n\t"   /* peb->BeingDebugged */
         "cbz w0, 1f\n\t"
         "bl \"#DbgBreakPoint\"\n"
         "1:\tmov w0, #0\n\t"
         "bl \"#RtlExitUserThread\"\n"
         "DbgUiRemoteBreakin_handler:\n\t"
         "mov sp, x1\n\t"            /* frame */
         "b 1b\n\t"
         ".seh_endproc" );
}


/**********************************************************************
 *              DbgBreakPoint   (NTDLL.@)
 */
void __attribute__((naked)) DbgBreakPoint(void)
{
    asm( ".seh_proc \"#DbgBreakPoint\"\n\t"
         ".seh_endprologue\n\t"
         "brk #0xf000\n\t"
         "ret\n\t"
         ".seh_endproc" );
}


/**********************************************************************
 *              DbgUserBreakPoint   (NTDLL.@)
 */
void __attribute__((naked)) DbgUserBreakPoint(void)
{
    asm( ".seh_proc \"#DbgUserBreakPoint\"\n\t"
         ".seh_endprologue\n\t"
         "brk #0xf000\n\t"
         "ret\n\t"
         ".seh_endproc" );
}

#endif  /* __arm64ec__ */
