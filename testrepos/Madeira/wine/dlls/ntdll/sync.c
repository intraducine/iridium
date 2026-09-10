/*
 *	Process synchronisation
 *
 * Copyright 1996, 1997, 1998 Marcus Meissner
 * Copyright 1997, 1998, 1999 Alexandre Julliard
 * Copyright 1999, 2000 Juergen Schmied
 * Copyright 2003 Eric Pouech
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

#include <limits.h>
#include <string.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

#include "ntstatus.h"
#include "windef.h"
#include "winternl.h"
#include "wine/debug.h"
#include "wine/list.h"
#include "wine/exception.h"
#include "unixlib.h"   /* ml672: ios_jit_alias_probe_params */
#include "ntdll_misc.h"

WINE_DEFAULT_DEBUG_CHANNEL(sync);
WINE_DECLARE_DEBUG_CHANNEL(relay);

static const char *debugstr_timeout( const LARGE_INTEGER *timeout )
{
    if (!timeout) return "(infinite)";
    return wine_dbgstr_longlong( timeout->QuadPart );
}

/******************************************************************
 *              RtlRunOnceInitialize (NTDLL.@)
 */
void WINAPI RtlRunOnceInitialize( RTL_RUN_ONCE *once )
{
    once->Ptr = NULL;
}

/******************************************************************
 *              RtlRunOnceBeginInitialize (NTDLL.@)
 */
DWORD WINAPI RtlRunOnceBeginInitialize( RTL_RUN_ONCE *once, ULONG flags, void **context )
{
    if (flags & RTL_RUN_ONCE_CHECK_ONLY)
    {
        ULONG_PTR val = (ULONG_PTR)ReadPointerAcquire( &once->Ptr );

        if (flags & RTL_RUN_ONCE_ASYNC) return STATUS_INVALID_PARAMETER;
        if ((val & 3) != 2) return STATUS_UNSUCCESSFUL;
        if (context) *context = (void *)(val & ~3);
        return STATUS_SUCCESS;
    }

    for (;;)
    {
        ULONG_PTR next, val = (ULONG_PTR)ReadPointerAcquire( &once->Ptr );

        switch (val & 3)
        {
        case 0:  /* first time */
            if (!InterlockedCompareExchangePointer( &once->Ptr,
                                                    (flags & RTL_RUN_ONCE_ASYNC) ? (void *)3 : (void *)1, 0 ))
                return STATUS_PENDING;
            break;

        case 1:  /* in progress, wait */
            if (flags & RTL_RUN_ONCE_ASYNC) return STATUS_INVALID_PARAMETER;
            next = val & ~3;
            if (InterlockedCompareExchangePointer( &once->Ptr, (void *)((ULONG_PTR)&next | 1),
                                                   (void *)val ) == (void *)val)
                NtWaitForKeyedEvent( 0, &next, FALSE, NULL );
            break;

        case 2:  /* done */
            if (context) *context = (void *)(val & ~3);
            return STATUS_SUCCESS;

        case 3:  /* in progress, async */
            if (!(flags & RTL_RUN_ONCE_ASYNC)) return STATUS_INVALID_PARAMETER;
            return STATUS_PENDING;
        }
    }
}

/******************************************************************
 *              RtlRunOnceComplete (NTDLL.@)
 */
DWORD WINAPI RtlRunOnceComplete( RTL_RUN_ONCE *once, ULONG flags, void *context )
{
    if ((ULONG_PTR)context & 3) return STATUS_INVALID_PARAMETER;

    if (flags & RTL_RUN_ONCE_INIT_FAILED)
    {
        if (context) return STATUS_INVALID_PARAMETER;
        if (flags & RTL_RUN_ONCE_ASYNC) return STATUS_INVALID_PARAMETER;
    }
    else context = (void *)((ULONG_PTR)context | 2);

    for (;;)
    {
        ULONG_PTR val = (ULONG_PTR)ReadPointerAcquire( &once->Ptr );

        switch (val & 3)
        {
        case 1:  /* in progress */
            if (InterlockedCompareExchangePointer( &once->Ptr, context, (void *)val ) != (void *)val) break;
            val &= ~3;
            while (val)
            {
                ULONG_PTR next = *(ULONG_PTR *)val;
                NtReleaseKeyedEvent( 0, (void *)val, FALSE, NULL );
                val = next;
            }
            return STATUS_SUCCESS;

        case 3:  /* in progress, async */
            if (!(flags & RTL_RUN_ONCE_ASYNC)) return STATUS_INVALID_PARAMETER;
            if (InterlockedCompareExchangePointer( &once->Ptr, context, (void *)val ) != (void *)val) break;
            return STATUS_SUCCESS;

        default:
            return STATUS_UNSUCCESSFUL;
        }
    }
}


/***********************************************************************
 * Critical sections
 ***********************************************************************/


static void *no_debug_info_marker = (void *)(ULONG_PTR)-1;

static BOOL crit_section_has_debuginfo( const RTL_CRITICAL_SECTION *crit )
{
    return crit->DebugInfo != NULL && crit->DebugInfo != no_debug_info_marker;
}

static const char *crit_section_get_name( const RTL_CRITICAL_SECTION *crit )
{
    if (crit_section_has_debuginfo( crit ))
        return (char *)crit->DebugInfo->Spare[0];
    return "?";
}

static inline HANDLE get_semaphore( RTL_CRITICAL_SECTION *crit )
{
    if ((ULONG_PTR)crit->LockSemaphore > 1) return crit->LockSemaphore;
    return NULL;
}

static inline NTSTATUS wait_semaphore( RTL_CRITICAL_SECTION *crit, int timeout )
{
    LARGE_INTEGER time = {.QuadPart = timeout * (LONGLONG)-10000000};
    HANDLE sem = get_semaphore( crit );

    if (sem) return NtWaitForSingleObject( sem, FALSE, &time );
    else
    {
        LONG *lock = (LONG *)&crit->LockSemaphore;
        while (!InterlockedCompareExchange( lock, 0, 1 ))
        {
            static const LONG zero;
            /* this may wait longer than specified in case of multiple wake-ups */
            if (RtlWaitOnAddress( lock, &zero, sizeof(LONG), &time ) == STATUS_TIMEOUT)
                return STATUS_TIMEOUT;
        }
        return STATUS_WAIT_0;
    }
}

static ULONG crit_sect_default_flags(void)
{
    if (NtCurrentTeb()->Peb->OSMajorVersion > 6 ||
        (NtCurrentTeb()->Peb->OSMajorVersion == 6 && NtCurrentTeb()->Peb->OSMinorVersion >= 2)) return 0;
    return RTL_CRITICAL_SECTION_FLAG_FORCE_DEBUG_INFO;
}

/******************************************************************************
 *      RtlInitializeCriticalSection   (NTDLL.@)
 */
/* ---- ml673: GENERATION-AWARE CRITICAL SECTION LIFECYCLE -----------------
 *
 * ml672 answered two questions and botched a third:
 *   - RX and RW agree, so this is not alias divergence.
 *   - The fatal section's neighbours are coherent.
 *   - "never deleted" was NOT established: the delete log capped at 64 events
 *     with no generation tracking, so absence there proved nothing.
 *
 * And an emulated-store watch would miss the write entirely -- [wr-strip]
 * restores write permission to the page after the first fault, so later stores
 * execute natively and never reach the Mach emulator.
 *
 * So: watch the FIELD's state machine instead of the writes. LockSemaphore is
 * 0 until a waiter needs it, then becomes a real handle via one CAS. Capture
 * every section born inside an anon-JIT alias, then report the FIRST time the
 * field leaves {0,1} for something that is not a handle we created. Generation
 * counting makes delete/reuse genuinely testable rather than assumed.
 *
 * Note also: the observed low dword 0x70 is an EVENT handle, not a semaphore --
 * so even that half is the wrong object type, which argues against a simple
 * torn write of a correct value. */
#define IOS_CS_TRACK 512
static struct ios_cs_slot
{
    ULONG64 crit;
    ULONG64 sem_at_init;
    ULONG64 alias_base;
    ULONG   generation;     /* bumped on delete -- reuse shows as gen > 0 */
    ULONG   deleted;
    ULONG   reported;
} ios_cs_tab[IOS_CS_TRACK];
static LONG ios_cs_init_logged, ios_cs_trans_logged;

static struct ios_cs_slot *ios_cs_slot_for( const void *crit, int create )
{
    ULONG64 k = (ULONG64)(ULONG_PTR)crit;
    unsigned h = (unsigned)((k >> 4) % IOS_CS_TRACK), i;
    for (i = 0; i < IOS_CS_TRACK; i++)
    {
        struct ios_cs_slot *sl = &ios_cs_tab[(h + i) % IOS_CS_TRACK];
        if (sl->crit == k) return sl;
        if (!sl->crit)
        {
            if (!create) return NULL;
            sl->crit = k;
            return sl;
        }
    }
    return NULL;
}

/* Called right after a section is initialised. Only tracks sections that live
 * inside an anonymous JIT alias -- those are the ones sharing pages with Mono's
 * mixed code+data, which is where the contamination appears. */
static void ios_cs_track_init( RTL_CRITICAL_SECTION *crit, void *caller )
{
    struct ios_jit_alias_probe_params pp;
    struct ios_cs_slot *sl;
    const ULONG64 *rx = (const ULONG64 *)crit;

    memset( &pp, 0, sizeof(pp) );
    pp.size = sizeof(pp); pp.version = 1; pp.addr = (ULONG64)(ULONG_PTR)crit;
    WINE_UNIX_CALL( unix_ios_jit_alias_probe, &pp );
    if (!pp.base) return;                      /* ordinary memory -- not our case */

    if (!(sl = ios_cs_slot_for( crit, 1 ))) return;
    if (sl->deleted) { sl->generation++; sl->deleted = 0; }
    sl->sem_at_init = (ULONG64)(ULONG_PTR)crit->LockSemaphore;
    sl->alias_base  = pp.base;
    sl->reported    = 0;

    if (InterlockedIncrement( &ios_cs_init_logged ) <= 24)
        ERR( "[cs-init] ml673 crit=%p gen=%u caller=%p alias=%s write_gen=%u | "
             "fields: %s %s %s %s %s\n",
             crit, sl->generation, caller, wine_dbgstr_longlong(pp.base), pp.write_gen,
             wine_dbgstr_longlong(rx[0]), wine_dbgstr_longlong(rx[1]),
             wine_dbgstr_longlong(rx[2]), wine_dbgstr_longlong(rx[3]),
             wine_dbgstr_longlong(rx[4]) );
}

/* Report the FIRST transition of LockSemaphore out of its internal {0,1} state
 * into something we did not put there. Bounded, once per section. */
static void ios_cs_check_transition( RTL_CRITICAL_SECTION *crit, const char *where )
{
    struct ios_cs_slot *sl = ios_cs_slot_for( crit, 0 );
    ULONG64 sem;
    if (!sl || sl->reported) return;
    sem = (ULONG64)(ULONG_PTR)crit->LockSemaphore;
    if (sem <= 1 || sem < 0x10000000ull) return;      /* 0/1 internal, small = real handle */
    sl->reported = 1;
    if (InterlockedIncrement( &ios_cs_trans_logged ) <= 16)
        ERR( "[cs-trans] ml673 %s crit=%p gen=%u deleted=%u sem_at_init=%s -> now=%s "
             "lock=%ld recursion=%ld owner=%04lx\n",
             where, crit, sl->generation, sl->deleted,
             wine_dbgstr_longlong(sl->sem_at_init), wine_dbgstr_longlong(sem),
             (long)crit->LockCount, (long)crit->RecursionCount,
             HandleToULong(crit->OwningThread) );
}


NTSTATUS WINAPI RtlInitializeCriticalSection( RTL_CRITICAL_SECTION *crit )
{
    return RtlInitializeCriticalSectionEx( crit, 0, crit_sect_default_flags() );
}


/******************************************************************************
 *      RtlInitializeCriticalSectionAndSpinCount   (NTDLL.@)
 */
NTSTATUS WINAPI RtlInitializeCriticalSectionAndSpinCount( RTL_CRITICAL_SECTION *crit, ULONG spincount )
{
    return RtlInitializeCriticalSectionEx( crit, spincount, crit_sect_default_flags() );
}


/******************************************************************************
 *      RtlInitializeCriticalSectionEx   (NTDLL.@)
 */
NTSTATUS WINAPI RtlInitializeCriticalSectionEx( RTL_CRITICAL_SECTION *crit, ULONG spincount, ULONG flags )
{
    void *ios_init_caller = __builtin_return_address(0);
    if (flags & (RTL_CRITICAL_SECTION_FLAG_DYNAMIC_SPIN|RTL_CRITICAL_SECTION_FLAG_STATIC_INIT))
        FIXME("(%p,%lu,0x%08lx) semi-stub\n", crit, spincount, flags);

    /* FIXME: if RTL_CRITICAL_SECTION_FLAG_STATIC_INIT is given, we should use
     * memory from a static pool to hold the debug info. Then heap.c could pass
     * this flag rather than initialising the process heap CS by hand. If this
     * is done, then debug info should be managed through Rtlp[Allocate|Free]DebugInfo
     * so (e.g.) MakeCriticalSectionGlobal() doesn't free it using HeapFree().
     */
    if (!(flags & RTL_CRITICAL_SECTION_FLAG_FORCE_DEBUG_INFO))
        crit->DebugInfo = no_debug_info_marker;
    else
    {
        crit->DebugInfo = RtlAllocateHeap( GetProcessHeap(), 0, sizeof(RTL_CRITICAL_SECTION_DEBUG ));
        if (crit->DebugInfo)
        {
            crit->DebugInfo->Type = 0;
            crit->DebugInfo->CreatorBackTraceIndex = 0;
            crit->DebugInfo->CriticalSection = crit;
            crit->DebugInfo->ProcessLocksList.Blink = &crit->DebugInfo->ProcessLocksList;
            crit->DebugInfo->ProcessLocksList.Flink = &crit->DebugInfo->ProcessLocksList;
            crit->DebugInfo->EntryCount = 0;
            crit->DebugInfo->ContentionCount = 0;
            memset( crit->DebugInfo->Spare, 0, sizeof(crit->DebugInfo->Spare) );
        }
    }
    crit->LockCount      = -1;
    crit->RecursionCount = 0;
    crit->OwningThread   = 0;
    crit->LockSemaphore  = 0;
    if (NtCurrentTeb()->Peb->NumberOfProcessors <= 1) spincount = 0;
    crit->SpinCount = spincount & ~0x80000000;
    ios_cs_track_init( crit, ios_init_caller );
    return STATUS_SUCCESS;
}


/******************************************************************************
 *      RtlSetCriticalSectionSpinCount   (NTDLL.@)
 */
ULONG WINAPI RtlSetCriticalSectionSpinCount( RTL_CRITICAL_SECTION *crit, ULONG spincount )
{
    ULONG oldspincount = crit->SpinCount;
    if (NtCurrentTeb()->Peb->NumberOfProcessors <= 1) spincount = 0;
    crit->SpinCount = spincount;
    return oldspincount;
}


/******************************************************************************
 *      RtlDeleteCriticalSection   (NTDLL.@)
 */
NTSTATUS WINAPI RtlDeleteCriticalSection( RTL_CRITICAL_SECTION *crit )
{
    /* ml672: record deletes so a later use of this address is identifiable as
     * use-after-delete rather than a blind overwrite. Bounded and address-only
     * -- enough to correlate against [cs-bad], cheap enough to leave on. */
    {
        static LONG del_n;
        if (InterlockedIncrement( &del_n ) <= 64)
            ERR( "[cs-life] ml672 delete crit=%p sem=%p lock=%ld\n",
                 crit, crit->LockSemaphore, (long)crit->LockCount );
    }
    {   /* ml673: generation-aware -- makes reuse detectable rather than assumed */
        struct ios_cs_slot *sl = ios_cs_slot_for( crit, 0 );
        if (sl) { sl->deleted = 1; sl->reported = 0; }
    }
    HANDLE sem;

    crit->LockCount      = -1;
    crit->RecursionCount = 0;
    crit->OwningThread   = 0;
    if (crit_section_has_debuginfo( crit ))
    {
        /* only free the ones we made in here */
        if (!crit->DebugInfo->Spare[0])
        {
            RtlFreeHeap( GetProcessHeap(), 0, crit->DebugInfo );
            crit->DebugInfo = NULL;
        }
    }
    else crit->DebugInfo = NULL;

    if ((sem = get_semaphore( crit ))) NtClose( sem );
    crit->LockSemaphore = 0;
    return STATUS_SUCCESS;
}




/* ---- ml672: CRITICAL SECTION LIFECYCLE + LockSemaphore CORRUPTION ------
 *
 * botd20 died with crit=0x7026864d48 holding LockSemaphore=0x23bbf72000000070
 * -- low dword a plausible wine handle (0x70), high dword the low half of a
 * stack address. Both threads agreed on the value, so it is the FIELD that is
 * wrong, not one thread's read.
 *
 * Four candidates, and they need different fixes:
 *   1. use-after-delete / slot reuse
 *   2. an overwrite from Mono's mixed code+data allocation (this section lives
 *      inside a registered anon-RWX region)
 *   3. RX/RW alias divergence -- the two views of the same physical page
 *      disagreeing, which would be OUR aliasing broken
 *   4. a genuine critical-section lifecycle bug
 *
 * The alias comparison is what splits (3) from the rest in one shot, and it is
 * cheap: unix_ios_jit_alias_probe already resolves a guest VA to its RW alias.
 * If RX and RW disagree on the same bytes, the aliasing is broken; if they
 * agree, the memory really was overwritten and (3) is out.
 *
 * Fires ONCE per bad section and is bounded -- this runs on the lock path, so
 * it must not become the thing that slows the game down. */
static LONG ios_cs_bad_reported;

static void ios_cs_report_bad( RTL_CRITICAL_SECTION *crit, const char *where )
{
    struct ios_jit_alias_probe_params pp;
    const ULONG64 *rx = (const ULONG64 *)crit;
    ULONG64 sem = (ULONG64)(ULONG_PTR)crit->LockSemaphore;

    /* 0 and 1 are the documented in-band values; a real handle is small. */
    if (sem <= 1 || sem < 0x10000000ull) return;
    if (InterlockedIncrement( &ios_cs_bad_reported ) > 8) return;

    memset( &pp, 0, sizeof(pp) );
    pp.size = sizeof(pp); pp.version = 1; pp.addr = (ULONG64)(ULONG_PTR)crit;
    WINE_UNIX_CALL( unix_ios_jit_alias_probe, &pp );

    ERR( "[cs-bad] ml672 %s crit=%p sem=%s lock=%ld recursion=%ld owner=%04lx debug=%p\n",
         where, crit, wine_dbgstr_longlong(sem), (long)crit->LockCount,
         (long)crit->RecursionCount, HandleToULong(crit->OwningThread), crit->DebugInfo );
    ERR( "[cs-bad] ml672   alias slot=%u base=%s end=%s rw=%s write_gen=%u written=%08x\n",
         pp.slot, wine_dbgstr_longlong(pp.base), wine_dbgstr_longlong(pp.end),
         wine_dbgstr_longlong(pp.rw), pp.write_gen, pp.written );
    ERR( "[cs-bad] ml672   RX view: %s %s %s %s %s\n",
         wine_dbgstr_longlong(rx[0]), wine_dbgstr_longlong(rx[1]), wine_dbgstr_longlong(rx[2]),
         wine_dbgstr_longlong(rx[3]), wine_dbgstr_longlong(rx[4]) );
    if (pp.rw)
    {
        const ULONG64 *rw = (const ULONG64 *)(ULONG_PTR)pp.rw;
        /* ml673: ACTUALLY COMPARE. ml672 printed "ALIAS DIVERGENCE" as fixed
         * text regardless of the values, so it would have claimed divergence
         * every time -- useless as a discriminator and actively misleading. */
        int same = (rw[0]==rx[0] && rw[1]==rx[1] && rw[2]==rx[2] && rw[3]==rx[3] && rw[4]==rx[4]);
        ERR( "[cs-bad] ml672   RW view: %s %s %s %s %s  <== %s\n",
             wine_dbgstr_longlong(rw[0]), wine_dbgstr_longlong(rw[1]), wine_dbgstr_longlong(rw[2]),
             wine_dbgstr_longlong(rw[3]), wine_dbgstr_longlong(rw[4]),
             same ? "IDENTICAL to RX (no alias divergence)" : "DIFFERS from RX => ALIAS DIVERGENCE" );
    }
    else
        ERR( "[cs-bad] ml672   RW view: (not in any anon-RWX alias -- plain guest memory)\n" );
}

/******************************************************************************
 *      RtlpWaitForCriticalSection   (NTDLL.@)
 */
NTSTATUS WINAPI RtlpWaitForCriticalSection( RTL_CRITICAL_SECTION *crit )
{
    unsigned int timeout = 5;

    /* Don't allow blocking on a critical section during process termination */
    if (RtlDllShutdownInProgress())
    {
        WARN( "process %s is shutting down, returning STATUS_SUCCESS\n",
              debugstr_w(NtCurrentTeb()->Peb->ProcessParameters->ImagePathName.Buffer) );
        return STATUS_SUCCESS;
    }

    for (;;)
    {
        NTSTATUS status = wait_semaphore( crit, timeout );

        if (status == STATUS_WAIT_0) break;
        if (status != WAIT_TIMEOUT) return status;

        timeout = (TRACE_ON(relay) ? 300 : 60);

        ERR( "section %p %s wait timed out in thread %04lx, blocked by %04lx, retrying (%u sec)\n",
             crit, debugstr_a(crit_section_get_name(crit)), GetCurrentThreadId(), HandleToULong(crit->OwningThread), timeout );
    }
    if (crit_section_has_debuginfo( crit )) crit->DebugInfo->ContentionCount++;
    return STATUS_SUCCESS;
}


/******************************************************************************
 *      RtlpUnWaitCriticalSection   (NTDLL.@)
 */
NTSTATUS WINAPI RtlpUnWaitCriticalSection( RTL_CRITICAL_SECTION *crit )
{
    NTSTATUS ret;
    HANDLE sem = get_semaphore( crit );

    if (sem) ret = NtReleaseSemaphore( sem, 1, NULL );
    else
    {
        LONG *lock = (LONG *)&crit->LockSemaphore;
        InterlockedExchange( lock, 1 );
        RtlWakeAddressSingle( lock );
        ret = STATUS_SUCCESS;
    }
    /* iOS-Madeira ml671: [cs-raise] — Book of the Dead dies on an UNHANDLED
     * c0000008 with flags=1 (EXCEPTION_NONCONTINUABLE). That flag is the
     * discriminator: RtlRaiseStatus sets it, KiRaiseUserExceptionDispatcher
     * does not -- which is why the ml669 [bad-close] probe on the NtClose path
     * never fired. This is one of only two RtlRaiseStatus sites in sync.c, and
     * thread 0114 was parked on a semaphore when it died.
     *
     * If NtReleaseSemaphore returns STATUS_INVALID_HANDLE here, the section's
     * backing semaphore was closed underneath a live critical section -- a
     * handle-lifetime bug, and a general one. Log the section's full state
     * before RtlRaiseException overwrites the exception address with its own.
     * Deliberately does not suppress: converting this to a silent return would
     * leave the lock permanently broken instead of loudly dead. */
    if (ret)
    {
        static LONG cs_raise_n;
        if (InterlockedIncrement( &cs_raise_n ) <= 16)
            ios_cs_report_bad( crit, "UnWait" );
            ERR( "[cs-raise] ml671 UnWait status=%08x crit=%p sem=%p owner=%04lx "
                 "lock=%ld recursion=%ld caller=%p\n",
                 (unsigned int)ret, crit, crit->LockSemaphore,
                 HandleToULong(crit->OwningThread), (long)crit->LockCount,
                 (long)crit->RecursionCount, __builtin_return_address(0) );
    }
    if (ret) RtlRaiseStatus( ret );
    return ret;
}


/******************************************************************************
 *      RtlEnterCriticalSection   (NTDLL.@)
 */
NTSTATUS WINAPI RtlEnterCriticalSection( RTL_CRITICAL_SECTION *crit )
{
    if (crit->SpinCount)
    {
        ULONG count;

        if (RtlTryEnterCriticalSection( crit )) return STATUS_SUCCESS;
        for (count = crit->SpinCount; count > 0; count--)
        {
            if (crit->LockCount > 0) break;  /* more than one waiter, don't bother spinning */
            if (crit->LockCount == -1)       /* try again */
            {
                if (InterlockedCompareExchange( &crit->LockCount, 0, -1 ) == -1) goto done;
            }
            YieldProcessor();
        }
    }

    if (InterlockedIncrement( &crit->LockCount ))
    {
        NTSTATUS status;

        if (crit->OwningThread == ULongToHandle(GetCurrentThreadId()))
        {
            crit->RecursionCount++;
            return STATUS_SUCCESS;
        }

        /* Now wait for it */
        ios_cs_check_transition( crit, "Enter" );
        if ((status = RtlpWaitForCriticalSection( crit )))
        {
            static LONG cs_wait_n;   /* ml671: the other RtlRaiseStatus site */
            if (InterlockedIncrement( &cs_wait_n ) <= 16)
                ios_cs_report_bad( crit, "Wait" );
            ERR( "[cs-raise] ml671 Wait status=%08x crit=%p sem=%p owner=%04lx "
                     "lock=%ld recursion=%ld caller=%p\n",
                     (unsigned int)status, crit, crit->LockSemaphore,
                     HandleToULong(crit->OwningThread), (long)crit->LockCount,
                     (long)crit->RecursionCount, __builtin_return_address(0) );
            RtlRaiseStatus( status );
        }
    }
done:
    crit->OwningThread   = ULongToHandle(GetCurrentThreadId());
    crit->RecursionCount = 1;
    return STATUS_SUCCESS;
}


/******************************************************************************
 *      RtlTryEnterCriticalSection   (NTDLL.@)
 */
BOOL WINAPI RtlTryEnterCriticalSection( RTL_CRITICAL_SECTION *crit )
{
    BOOL ret = FALSE;
    if (InterlockedCompareExchange( &crit->LockCount, 0, -1 ) == -1)
    {
        crit->OwningThread   = ULongToHandle(GetCurrentThreadId());
        crit->RecursionCount = 1;
        ret = TRUE;
    }
    else if (crit->OwningThread == ULongToHandle(GetCurrentThreadId()))
    {
        InterlockedIncrement( &crit->LockCount );
        crit->RecursionCount++;
        ret = TRUE;
    }
    return ret;
}


/******************************************************************************
 *      RtlIsCriticalSectionLocked   (NTDLL.@)
 */
BOOL WINAPI RtlIsCriticalSectionLocked( RTL_CRITICAL_SECTION *crit )
{
    return crit->RecursionCount != 0;
}


/******************************************************************************
 *      RtlIsCriticalSectionLockedByThread   (NTDLL.@)
 */
BOOL WINAPI RtlIsCriticalSectionLockedByThread( RTL_CRITICAL_SECTION *crit )
{
    return crit->OwningThread == ULongToHandle(GetCurrentThreadId()) &&
           crit->RecursionCount;
}


/******************************************************************************
 *      RtlLeaveCriticalSection   (NTDLL.@)
 */
NTSTATUS WINAPI RtlLeaveCriticalSection( RTL_CRITICAL_SECTION *crit )
{
    if (--crit->RecursionCount)
    {
        if (crit->RecursionCount > 0) InterlockedDecrement( &crit->LockCount );
        else ERR( "section %p %s is not acquired\n", crit, debugstr_a( crit_section_get_name( crit )));
    }
    else
    {
        crit->OwningThread = 0;
        if (InterlockedDecrement( &crit->LockCount ) >= 0)
        {
            /* someone is waiting */
            RtlpUnWaitCriticalSection( crit );
        }
    }
    return STATUS_SUCCESS;
}

/******************************************************************
 *              RtlRunOnceExecuteOnce (NTDLL.@)
 */
DWORD WINAPI RtlRunOnceExecuteOnce( RTL_RUN_ONCE *once, PRTL_RUN_ONCE_INIT_FN func,
                                    void *param, void **context )
{
    DWORD ret = RtlRunOnceBeginInitialize( once, 0, context );

    if (ret != STATUS_PENDING) return ret;

    if (!func( once, param, context ))
    {
        RtlRunOnceComplete( once, RTL_RUN_ONCE_INIT_FAILED, NULL );
        return STATUS_UNSUCCESSFUL;
    }

    return RtlRunOnceComplete( once, 0, context ? *context : NULL );
}

struct srw_lock
{
    /* bit 0 - if the lock is held exclusive. bit 1.. - number of exclusive waiters. */
    short exclusive_waiters;

    /* Number of owners.
     *
     * Sadly Windows has no equivalent to FUTEX_WAIT_BITSET, so in order to wake
     * up *only* exclusive or *only* shared waiters (and thus avoid spurious
     * wakeups), we need to wait on two different addresses.
     * RtlAcquireSRWLockShared() needs to know the values of "exclusive_waiters"
     * and "owners", but RtlAcquireSRWLockExclusive() only needs to know the
     * value of "owners", so the former can wait on the entire structure, and
     * the latter waits only on the "owners" member. Note then that "owners"
     * must not be the first element in the structure.
     */
    unsigned short owners;
};
C_ASSERT( sizeof(struct srw_lock) == 4 );

/***********************************************************************
 *              RtlInitializeSRWLock (NTDLL.@)
 *
 * NOTES
 *  Please note that SRWLocks do not keep track of the owner of a lock.
 *  It doesn't make any difference which thread for example unlocks an
 *  SRWLock (see corresponding tests). This implementation uses two
 *  keyed events (one for the exclusive waiters and one for the shared
 *  waiters) and is limited to 2^15-1 waiting threads.
 */
void WINAPI RtlInitializeSRWLock( RTL_SRWLOCK *lock )
{
    lock->Ptr = NULL;
}

/***********************************************************************
 *              RtlAcquireSRWLockExclusive (NTDLL.@)
 *
 * NOTES
 *  Unlike RtlAcquireResourceExclusive this function doesn't allow
 *  nested calls from the same thread. "Upgrading" a shared access lock
 *  to an exclusive access lock also doesn't seem to be supported.
 */
/* iOS-Madeira ml410 (#66→#60): SRWLOCKs are anonymous — when the chrome_ipc
 * pump parks forever on a lock's `owners` field there is no owner to read.
 * Keep a ring of the last 512 acquire/release events {lock, tid, mode} so the
 * parked waiter can name the holder: the newest unmatched acquire for that
 * lock address is the thread that never released (or died holding shared —
 * the #66 crash-orphaned-count theory). Ring writes are two plain stores +
 * one interlocked increment; no logging on the hot path. */
struct ios_srw_ring_ent { const void *lock; ULONG tid_mode; };
static struct ios_srw_ring_ent ios_srw_ring[512];
static LONG ios_srw_ring_idx;
static const char * const ios_srw_mode_name[4] = { "acqX", "relX", "acqS", "relS" };
static void ios_srw_note( const void *lock, unsigned int mode )
{
    ULONG i = (ULONG)InterlockedIncrement( &ios_srw_ring_idx );
    ios_srw_ring[i & 511].lock = lock;
    ios_srw_ring[i & 511].tid_mode =
        (HandleToULong( NtCurrentTeb()->ClientId.UniqueThread ) << 2) | mode;
}

/* Called from RtlWaitOnAddress when a beacon thread parks on a size-2 wait
 * (the SRW exclusive path waits on `owners`, size 2, at lock+2). Dump the
 * lock word (exclusive vs leaked-shared verdict) and the ring history for
 * this lock (holder's tid). */
static void ios_srw_dump_park( const void *addr )
{
    const struct srw_lock *s = (const struct srw_lock *)((const char *)addr - 2);
    ULONG i = (ULONG)ios_srw_ring_idx;
    ULONG n, printed = 0;
    static LONG dumps;

    if (dumps >= 8 || InterlockedIncrement( &dumps ) > 8) return;
    ERR( "[srw] parked on lock=%p exclusive_waiters=%04x owners=%u (owners>1 = shared-held/leaked)\n",
         s, (unsigned short)s->exclusive_waiters, s->owners );
    for (n = 0; n < 512 && printed < 16; n++)
    {
        const struct ios_srw_ring_ent *e = &ios_srw_ring[(i - n) & 511];
        if (e->lock != (const void *)s) continue;
        ERR( "[srw]   ring[-%03u] tid=%04x %s\n", n,
             e->tid_mode >> 2, ios_srw_mode_name[e->tid_mode & 3] );
        printed++;
    }
    if (!printed) ERR( "[srw]   ring has NO events for this lock (acquired before ring wrapped)\n" );
}

void WINAPI RtlAcquireSRWLockExclusive( RTL_SRWLOCK *lock )
{
    union { RTL_SRWLOCK *rtl; struct srw_lock *s; LONG *l; } u = { lock };

    InterlockedExchangeAdd16( &u.s->exclusive_waiters, 2 );

    for (;;)
    {
        union { struct srw_lock s; LONG l; } old, new;
        BOOL wait;

        do
        {
            old.s = *u.s;
            new.s = old.s;

            if (!old.s.owners)
            {
                /* Not locked exclusive or shared. We can try to grab it. */
                new.s.owners = 1;
                new.s.exclusive_waiters -= 2;
                new.s.exclusive_waiters |= 1;
                wait = FALSE;
            }
            else
            {
                wait = TRUE;
            }
        } while (InterlockedCompareExchange( u.l, new.l, old.l ) != old.l);

        if (!wait)
        {
            ios_srw_note( lock, 0 );
            return;
        }
        RtlWaitOnAddress( &u.s->owners, &new.s.owners, sizeof(short), NULL );
    }
}

/***********************************************************************
 *              RtlAcquireSRWLockShared (NTDLL.@)
 *
 * NOTES
 *   Do not call this function recursively - it will only succeed when
 *   there are no threads waiting for an exclusive lock!
 */
void WINAPI RtlAcquireSRWLockShared( RTL_SRWLOCK *lock )
{
    union { RTL_SRWLOCK *rtl; struct srw_lock *s; LONG *l; } u = { lock };

    for (;;)
    {
        union { struct srw_lock s; LONG l; } old, new;
        BOOL wait;

        do
        {
            old.s = *u.s;
            new = old;

            if (!old.s.exclusive_waiters)
            {
                /* Not locked exclusive, and no exclusive waiters.
                 * We can try to grab it. */
                ++new.s.owners;
                wait = FALSE;
            }
            else
            {
                wait = TRUE;
            }
        } while (InterlockedCompareExchange( u.l, new.l, old.l ) != old.l);

        if (!wait)
        {
            ios_srw_note( lock, 2 );
            return;
        }
        RtlWaitOnAddress( u.s, &new.s, sizeof(struct srw_lock), NULL );
    }
}

/***********************************************************************
 *              RtlReleaseSRWLockExclusive (NTDLL.@)
 */
void WINAPI RtlReleaseSRWLockExclusive( RTL_SRWLOCK *lock )
{
    union { RTL_SRWLOCK *rtl; struct srw_lock *s; LONG *l; } u = { lock };
    union { struct srw_lock s; LONG l; } old, new;

    do
    {
        old.s = *u.s;
        new = old;

        if (!(old.s.exclusive_waiters & 1)) ERR("Lock %p is not owned exclusive!\n", lock);

        new.s.owners = 0;
        new.s.exclusive_waiters &= ~1;
    } while (InterlockedCompareExchange( u.l, new.l, old.l ) != old.l);

    ios_srw_note( lock, 1 );
    if (new.s.exclusive_waiters)
        RtlWakeAddressSingle( &u.s->owners );
    else
        RtlWakeAddressAll( u.s );
}

/***********************************************************************
 *              RtlReleaseSRWLockShared (NTDLL.@)
 */
void WINAPI RtlReleaseSRWLockShared( RTL_SRWLOCK *lock )
{
    union { RTL_SRWLOCK *rtl; struct srw_lock *s; LONG *l; } u = { lock };
    union { struct srw_lock s; LONG l; } old, new;

    do
    {
        old.s = *u.s;
        new = old;

        if (old.s.exclusive_waiters & 1) ERR("Lock %p is owned exclusive!\n", lock);
        else if (!old.s.owners) ERR("Lock %p is not owned shared!\n", lock);

        --new.s.owners;
    } while (InterlockedCompareExchange( u.l, new.l, old.l ) != old.l);

    ios_srw_note( lock, 3 );
    if (!new.s.owners)
        RtlWakeAddressSingle( &u.s->owners );
}

/***********************************************************************
 *              RtlTryAcquireSRWLockExclusive (NTDLL.@)
 *
 * NOTES
 *  Similarly to AcquireSRWLockExclusive, recursive calls are not allowed
 *  and will fail with a FALSE return value.
 */
BOOLEAN WINAPI RtlTryAcquireSRWLockExclusive( RTL_SRWLOCK *lock )
{
    union { RTL_SRWLOCK *rtl; struct srw_lock *s; LONG *l; } u = { lock };
    union { struct srw_lock s; LONG l; } old, new;
    BOOLEAN ret;

    do
    {
        old.s = *u.s;
        new.s = old.s;

        if (!old.s.owners)
        {
            /* Not locked exclusive or shared. We can try to grab it. */
            new.s.owners = 1;
            new.s.exclusive_waiters |= 1;
            ret = TRUE;
        }
        else
        {
            ret = FALSE;
        }
    } while (InterlockedCompareExchange( u.l, new.l, old.l ) != old.l);

    if (ret) ios_srw_note( lock, 0 );
    return ret;
}

/***********************************************************************
 *              RtlTryAcquireSRWLockShared (NTDLL.@)
 */
BOOLEAN WINAPI RtlTryAcquireSRWLockShared( RTL_SRWLOCK *lock )
{
    union { RTL_SRWLOCK *rtl; struct srw_lock *s; LONG *l; } u = { lock };
    union { struct srw_lock s; LONG l; } old, new;
    BOOLEAN ret;

    do
    {
        old.s = *u.s;
        new.s = old.s;

        if (!old.s.exclusive_waiters)
        {
            /* Not locked exclusive, and no exclusive waiters.
             * We can try to grab it. */
            ++new.s.owners;
            ret = TRUE;
        }
        else
        {
            ret = FALSE;
        }
    } while (InterlockedCompareExchange( u.l, new.l, old.l ) != old.l);

    if (ret) ios_srw_note( lock, 2 );
    return ret;
}

/***********************************************************************
 *           RtlInitializeConditionVariable   (NTDLL.@)
 *
 * Initializes the condition variable with NULL.
 *
 * PARAMS
 *  variable [O] condition variable
 *
 * RETURNS
 *  Nothing.
 */
void WINAPI RtlInitializeConditionVariable( RTL_CONDITION_VARIABLE *variable )
{
    variable->Ptr = NULL;
}

/***********************************************************************
 *           RtlWakeConditionVariable   (NTDLL.@)
 *
 * Wakes up one thread waiting on the condition variable.
 *
 * PARAMS
 *  variable [I/O] condition variable to wake up.
 *
 * RETURNS
 *  Nothing.
 *
 * NOTES
 *  The calling thread does not have to own any lock in order to call
 *  this function.
 */
void WINAPI RtlWakeConditionVariable( RTL_CONDITION_VARIABLE *variable )
{
    InterlockedIncrement( (LONG *)&variable->Ptr );
    RtlWakeAddressSingle( variable );
}

/***********************************************************************
 *           RtlWakeAllConditionVariable   (NTDLL.@)
 *
 * See WakeConditionVariable, wakes up all waiting threads.
 */
void WINAPI RtlWakeAllConditionVariable( RTL_CONDITION_VARIABLE *variable )
{
    InterlockedIncrement( (LONG *)&variable->Ptr );
    RtlWakeAddressAll( variable );
}

/***********************************************************************
 *           RtlSleepConditionVariableCS   (NTDLL.@)
 *
 * Atomically releases the critical section and suspends the thread,
 * waiting for a Wake(All)ConditionVariable event. Afterwards it enters
 * the critical section again and returns.
 *
 * PARAMS
 *  variable  [I/O] condition variable
 *  crit      [I/O] critical section to leave temporarily
 *  timeout   [I]   timeout
 *
 * RETURNS
 *  see NtWaitForKeyedEvent for all possible return values.
 */
NTSTATUS WINAPI RtlSleepConditionVariableCS( RTL_CONDITION_VARIABLE *variable, RTL_CRITICAL_SECTION *crit,
                                             const LARGE_INTEGER *timeout )
{
    int value = *(int *)&variable->Ptr;
    NTSTATUS status;

    RtlLeaveCriticalSection( crit );
    status = RtlWaitOnAddress( &variable->Ptr, &value, sizeof(value), timeout );
    RtlEnterCriticalSection( crit );
    return status;
}

/***********************************************************************
 *           RtlSleepConditionVariableSRW   (NTDLL.@)
 *
 * Atomically releases the SRWLock and suspends the thread,
 * waiting for a Wake(All)ConditionVariable event. Afterwards it enters
 * the SRWLock again with the same access rights and returns.
 *
 * PARAMS
 *  variable  [I/O] condition variable
 *  lock      [I/O] SRWLock to leave temporarily
 *  timeout   [I]   timeout
 *  flags     [I]   type of the current lock (exclusive / shared)
 *
 * RETURNS
 *  see NtWaitForKeyedEvent for all possible return values.
 *
 * NOTES
 *  the behaviour is undefined if the thread doesn't own the lock.
 */
NTSTATUS WINAPI RtlSleepConditionVariableSRW( RTL_CONDITION_VARIABLE *variable, RTL_SRWLOCK *lock,
                                              const LARGE_INTEGER *timeout, ULONG flags )
{
    int value = *(int *)&variable->Ptr;
    NTSTATUS status;

    if (flags & RTL_CONDITION_VARIABLE_LOCKMODE_SHARED)
        RtlReleaseSRWLockShared( lock );
    else
        RtlReleaseSRWLockExclusive( lock );

    status = RtlWaitOnAddress( &variable->Ptr, &value, sizeof(value), timeout );

    if (flags & RTL_CONDITION_VARIABLE_LOCKMODE_SHARED)
        RtlAcquireSRWLockShared( lock );
    else
        RtlAcquireSRWLockExclusive( lock );
    return status;
}

/* RtlWaitOnAddress() and RtlWakeAddress*(), hereafter referred to as "Win32
 * futexes", offer futex-like semantics with a variable set of address sizes,
 * but are limited to a single process. They are also fair—the documentation
 * specifies this, and tests bear it out.
 *
 * On Windows they are implemented using NtAlertThreadByThreadId and
 * NtWaitForAlertByThreadId, which manipulate a single flag (similar to an
 * auto-reset event) per thread. This can be tested by attempting to wake a
 * thread waiting in RtlWaitOnAddress() via NtAlertThreadByThreadId.
 */

struct futex_entry
{
    struct list entry;
    const void *addr;
    DWORD tid;
};

struct futex_queue
{
    struct list queue;
    LONG lock;
};

static struct futex_queue futex_queues[256];

/* iOS-Madeira ml441 (#74): futex_queues is per-ntdll-COPY .data, and our
 * pseudo-processes carry multiple ntdll copies (native + EC), so a waker
 * walking this copy's array never finds a waiter registered through another
 * copy — the wake dies here and the waiter parks forever (the post-
 * BrowserReady stall: ml440 proved every >60s parker was an addr=NULL
 * RtlWaitOnAddress park with zero alerts delivered).  Fix: every copy uses
 * the ONE table in the unix dylib's .data, fetched once via a private
 * NtQuerySystemInformation class.  Falls back to the private array only if
 * the query fails (never expected on iOS builds). */
static struct futex_queue *ios_shared_queues;
static const char ios_futex_shared_pe_marker[] __attribute__((used)) = "ios-futex-shared-pe rev=ml441";

static struct futex_queue *ios_get_futex_table(void)
{
    void *ptr = NULL;
    ULONG len;

    if (ios_shared_queues) return ios_shared_queues;
    if (!NtQuerySystemInformation( (SYSTEM_INFORMATION_CLASS)0xf00d, &ptr, sizeof(ptr), &len ) && ptr)
        ios_shared_queues = ptr;
    else
        ios_shared_queues = futex_queues;
    return ios_shared_queues;
}

/* iOS-Madeira ml407 (task #60): the chrome_ipc pump parks in RtlWaitOnAddress
 * immediately after its master-event wake and is never alerted ([alert-unix]:
 * one WAIT, no ALERTED, while its sibling server thread cycles normally).
 * futex_queues is a PER-NTDLL-COPY global and our pseudo-processes each carry
 * their own ntdll copy (native aarch64 AND EC copies coexist), so a waker
 * running against a different copy walks a different array and never sees the
 * waiter.  Record the marked thread's wait address + queue, then log any wake
 * aimed at that address plus the copy identity (&futex_queues) of both sides:
 *   wake logged with a DIFFERENT base  => copy-mismatch lost wake (fix: share the queue)
 *   no wake for the address at all     => the signaller never ran (different bug) */
static const void *ios_pump_wait_addr;
static const void *ios_pump_wait_queue;

static void ios_futex_note_wake( const char *how, const void *addr, const void *queue, int found )
{
    static LONG n;
    if (addr != ios_pump_wait_addr || !ios_pump_wait_addr) return;
    if (n >= 40) return;
    InterlockedIncrement( &n );
    ERR( "[futex] WAKE-%s addr=%p queue=%p base=%p found=%d (waiter queue=%p)\n",
         how, addr, queue, futex_queues, found, ios_pump_wait_queue );
}

static struct futex_queue *get_futex_queue( const void *addr )
{
    ULONG_PTR val = (ULONG_PTR)addr;

    /* ml441: index the SHARED table, not this copy's private array */
    return &ios_get_futex_table()[(val >> 4) % ARRAY_SIZE(futex_queues)];
}

static void spin_lock( LONG *lock )
{
    while (InterlockedCompareExchange( lock, -1, 0 ))
        YieldProcessor();
}

static void spin_unlock( LONG *lock )
{
    InterlockedExchange( lock, 0 );
}

static BOOL compare_addr( const void *addr, const void *cmp, SIZE_T size )
{
    switch (size)
    {
        case 1:
            return (*(const UCHAR *)addr == *(const UCHAR *)cmp);
        case 2:
            return (*(const USHORT *)addr == *(const USHORT *)cmp);
        case 4:
            return (*(const ULONG *)addr == *(const ULONG *)cmp);
        case 8:
            return (*(const ULONG64 *)addr == *(const ULONG64 *)cmp);
    }

    return FALSE;
}

/***********************************************************************
 *           RtlWaitOnAddress   (NTDLL.@)
 */
NTSTATUS WINAPI RtlWaitOnAddress( const void *addr, const void *cmp, SIZE_T size,
                                  const LARGE_INTEGER *timeout )
{
    struct futex_queue *queue = get_futex_queue( addr );
    struct futex_entry entry;
    NTSTATUS ret;

    TRACE("addr %p cmp %p size %#Ix timeout %s\n", addr, cmp, size, debugstr_timeout( timeout ));

    if (size != 1 && size != 2 && size != 4 && size != 8)
        return STATUS_INVALID_PARAMETER;

    entry.addr = addr;
    entry.tid = GetCurrentThreadId();

    spin_lock( &queue->lock );

    /* Do the comparison inside of the spinlock, to reduce spurious wakeups. */

    if (!compare_addr( addr, cmp, size ))
    {
        spin_unlock( &queue->lock );
        return STATUS_SUCCESS;
    }

    if (!queue->queue.next)
        list_init( &queue->queue );
    list_add_tail( &queue->queue, &entry.entry );

    spin_unlock( &queue->lock );

    if (NtCurrentTeb()->Instrumentation[10] == (void *)(ULONG_PTR)0x504d5550)
    {
        static LONG n;
        ios_pump_wait_addr = addr;
        ios_pump_wait_queue = queue;
        if (n < 40) { InterlockedIncrement( &n );
            ERR( "[futex] WAIT tid=%04x addr=%p size=%Iu queue=%p base=%p timeout=%s\n",
                 (int)(ULONG_PTR)NtCurrentTeb()->ClientId.UniqueThread, addr, size, queue,
                 futex_queues, timeout ? "fin" : "INF" ); }
        /* ml410: a size-2 wait from a beacon is the SRW exclusive path parked
         * on `owners` — dump the lock word + acquire/release ring history so
         * the holder that never releases is NAMED (see ios_srw_dump_park). */
        if (size == 2 && !timeout) ios_srw_dump_park( addr );
    }

    /* ml441: pass the real address — the unix layer ignores it functionally
     * but the [waiters] registry (ml440) records it, so long parks are now
     * attributable to a named lock word. */
    ret = NtWaitForAlertByThreadId( addr, timeout );

    if (NtCurrentTeb()->Instrumentation[10] == (void *)(ULONG_PTR)0x504d5550)
    {
        static LONG n;
        if (n < 40) { InterlockedIncrement( &n );
            ERR( "[futex] WAIT tid=%04x addr=%p -> %lx\n",
                 (int)(ULONG_PTR)NtCurrentTeb()->ClientId.UniqueThread, addr, ret ); }
    }

    /* We may have already been removed by a call to RtlWakeAddressSingle() or RtlWakeAddressAll(). */
    if (entry.addr)
    {
        spin_lock( &queue->lock );
        if (entry.addr)
            list_remove( &entry.entry );
        spin_unlock( &queue->lock );
    }

    TRACE("returning %#lx\n", ret);

    if (ret == STATUS_ALERTED) ret = STATUS_SUCCESS;
    return ret;
}

/***********************************************************************
 *           RtlWakeAddressAll    (NTDLL.@)
 */
void WINAPI RtlWakeAddressAll( const void *addr )
{
    struct futex_queue *queue = get_futex_queue( addr );
    struct futex_entry *entry, *next;
    unsigned int count = 0;
    HANDLE tids[256];

    TRACE("%p\n", addr);

    if (!addr) return;

    spin_lock( &queue->lock );

    if (!queue->queue.next)
        list_init(&queue->queue);

    LIST_FOR_EACH_ENTRY_SAFE( entry, next, &queue->queue, struct futex_entry, entry )
    {
        if (entry->addr == addr)
        {
            entry->addr = NULL;
            list_remove( &entry->entry );
            if (count == ARRAY_SIZE(tids))
            {
                NtAlertMultipleThreadByThreadId( tids, count, NULL, NULL );
                count = 0;
            }
            tids[count++] = (HANDLE)(ULONG_PTR)entry->tid;
        }
    }

    /* Try not to make a system call while holding a spinlock (even if that can be responsible for spurious wake
     * up scenario). */
    spin_unlock( &queue->lock );
    ios_futex_note_wake( "all", addr, queue, count );
    if (count)
        NtAlertMultipleThreadByThreadId( tids, count, NULL, NULL );
}

/***********************************************************************
 *           RtlWakeAddressSingle (NTDLL.@)
 */
void WINAPI RtlWakeAddressSingle( const void *addr )
{
    struct futex_queue *queue = get_futex_queue( addr );
    struct futex_entry *entry;
    DWORD tid = 0;

    TRACE("%p\n", addr);

    if (!addr) return;

    spin_lock( &queue->lock );

    if (!queue->queue.next)
        list_init(&queue->queue);

    LIST_FOR_EACH_ENTRY( entry, &queue->queue, struct futex_entry, entry )
    {
        if (entry->addr == addr)
        {
            /* Try to buffer wakes, so that we don't make a system call while
             * holding a spinlock. */
            tid = entry->tid;

            /* Remove this entry from the queue, so that a simultaneous call to
             * RtlWakeAddressSingle() will not also wake it—two simultaneous
             * calls must wake at least two waiters if they exist. */
            entry->addr = NULL;
            list_remove( &entry->entry );
            break;
        }
    }

    spin_unlock( &queue->lock );
    ios_futex_note_wake( "single", addr, queue, tid != 0 );

    if (tid) NtAlertThreadByThreadId( (HANDLE)(DWORD_PTR)tid );
}

/*************************************************************************
 *           RtlInitializeSListHead (NTDLL.@)
 */
void WINAPI RtlInitializeSListHead(PSLIST_HEADER list)
{
#ifdef _WIN64
    list->Alignment = list->Region = 0;
    list->Header16.HeaderType = 1;  /* we use the 16-byte header */
#else
    list->Alignment = 0;
#endif
}

/*************************************************************************
 *           RtlQueryDepthSList (NTDLL.@)
 */
WORD WINAPI RtlQueryDepthSList(PSLIST_HEADER list)
{
#ifdef _WIN64
    return list->Header16.Depth;
#else
    return list->Depth;
#endif
}

/*************************************************************************
 *           RtlFirstEntrySList (NTDLL.@)
 */
PSLIST_ENTRY WINAPI RtlFirstEntrySList(const SLIST_HEADER* list)
{
#ifdef _WIN64
    return (SLIST_ENTRY *)((ULONG_PTR)list->Header16.NextEntry << 4);
#else
    return list->Next.Next;
#endif
}

/*************************************************************************
 *           RtlInterlockedFlushSList (NTDLL.@)
 */
PSLIST_ENTRY WINAPI RtlInterlockedFlushSList(PSLIST_HEADER list)
{
    SLIST_HEADER old, new;

#ifdef _WIN64
    if (!list->Header16.NextEntry) return NULL;
    new.Alignment = new.Region = 0;
    new.Header16.HeaderType = 1;  /* we use the 16-byte header */
    do
    {
        old = *list;
        new.Header16.Sequence = old.Header16.Sequence + 1;
    } while (!InterlockedCompareExchange128((__int64 *)list, new.Region, new.Alignment, (__int64 *)&old));
    return (SLIST_ENTRY *)((ULONG_PTR)old.Header16.NextEntry << 4);
#else
    if (!list->Next.Next) return NULL;
    new.Alignment = 0;
    do
    {
        old = *list;
        new.Sequence = old.Sequence + 1;
    } while (InterlockedCompareExchange64((__int64 *)&list->Alignment, new.Alignment,
                                          old.Alignment) != old.Alignment);
    return old.Next.Next;
#endif
}

/*************************************************************************
 *           RtlInterlockedPushEntrySList (NTDLL.@)
 */
PSLIST_ENTRY WINAPI RtlInterlockedPushEntrySList(PSLIST_HEADER list, PSLIST_ENTRY entry)
{
    SLIST_HEADER old, new;

#ifdef _WIN64
    new.Header16.NextEntry = (ULONG_PTR)entry >> 4;
    do
    {
        old = *list;
        entry->Next = (SLIST_ENTRY *)((ULONG_PTR)old.Header16.NextEntry << 4);
        new.Header16.Depth = old.Header16.Depth + 1;
        new.Header16.Sequence = old.Header16.Sequence + 1;
    } while (!InterlockedCompareExchange128((__int64 *)list, new.Region, new.Alignment, (__int64 *)&old));
    return (SLIST_ENTRY *)((ULONG_PTR)old.Header16.NextEntry << 4);
#else
    new.Next.Next = entry;
    do
    {
        old = *list;
        entry->Next = old.Next.Next;
        new.Depth = old.Depth + 1;
        new.Sequence = old.Sequence + 1;
    } while (InterlockedCompareExchange64((__int64 *)&list->Alignment, new.Alignment,
                                          old.Alignment) != old.Alignment);
    return old.Next.Next;
#endif
}

/*************************************************************************
 *           RtlInterlockedPopEntrySList (NTDLL.@)
 */
PSLIST_ENTRY WINAPI RtlInterlockedPopEntrySList(PSLIST_HEADER list)
{
    SLIST_HEADER old, new;
    PSLIST_ENTRY entry;

#ifdef _WIN64
    do
    {
        old = *list;
        if (!(entry = (SLIST_ENTRY *)((ULONG_PTR)old.Header16.NextEntry << 4))) return NULL;
        /* entry could be deleted by another thread */
        __TRY
        {
            new.Header16.NextEntry = (ULONG_PTR)entry->Next >> 4;
            new.Header16.Depth = old.Header16.Depth - 1;
            new.Header16.Sequence = old.Header16.Sequence + 1;
        }
        __EXCEPT_PAGE_FAULT
        {
        }
        __ENDTRY
    } while (!InterlockedCompareExchange128((__int64 *)list, new.Region, new.Alignment, (__int64 *)&old));
#else
    do
    {
        old = *list;
        if (!(entry = old.Next.Next)) return NULL;
        /* entry could be deleted by another thread */
        __TRY
        {
            new.Next.Next = entry->Next;
            new.Depth = old.Depth - 1;
            new.Sequence = old.Sequence + 1;
        }
        __EXCEPT_PAGE_FAULT
        {
        }
        __ENDTRY
    } while (InterlockedCompareExchange64((__int64 *)&list->Alignment, new.Alignment,
                                          old.Alignment) != old.Alignment);
#endif
    return entry;
}

/*************************************************************************
 *           RtlInterlockedPushListSListEx (NTDLL.@)
 */
PSLIST_ENTRY WINAPI RtlInterlockedPushListSListEx(PSLIST_HEADER list, PSLIST_ENTRY first,
                                                  PSLIST_ENTRY last, ULONG count)
{
    SLIST_HEADER old, new;

#ifdef _WIN64
    new.Header16.NextEntry = (ULONG_PTR)first >> 4;
    do
    {
        old = *list;
        new.Header16.Depth = old.Header16.Depth + count;
        new.Header16.Sequence = old.Header16.Sequence + 1;
        last->Next = (SLIST_ENTRY *)((ULONG_PTR)old.Header16.NextEntry << 4);
    } while (!InterlockedCompareExchange128((__int64 *)list, new.Region, new.Alignment, (__int64 *)&old));
    return (SLIST_ENTRY *)((ULONG_PTR)old.Header16.NextEntry << 4);
#else
    new.Next.Next = first;
    do
    {
        old = *list;
        new.Depth = old.Depth + count;
        new.Sequence = old.Sequence + 1;
        last->Next = old.Next.Next;
    } while (InterlockedCompareExchange64((__int64 *)&list->Alignment, new.Alignment,
                                          old.Alignment) != old.Alignment);
    return old.Next.Next;
#endif
}

/*************************************************************************
 *           RtlInterlockedPushListSList (NTDLL.@)
 */
DEFINE_FASTCALL_WRAPPER(RtlInterlockedPushListSList, 16)
PSLIST_ENTRY FASTCALL RtlInterlockedPushListSList(PSLIST_HEADER list, PSLIST_ENTRY first,
                                                  PSLIST_ENTRY last, ULONG count)
{
    return RtlInterlockedPushListSListEx(list, first, last, count);
}

/***********************************************************************
 *           RtlInitializeResource  (NTDLL.@)
 *
 * xxxResource() functions implement multiple-reader-single-writer lock.
 * The code is based on information published in WDJ January 1999 issue.
 */
void WINAPI RtlInitializeResource(LPRTL_RWLOCK rwl)
{
    if (!rwl) return;
    rwl->iNumberActive = 0;
    rwl->uExclusiveWaiters = 0;
    rwl->uSharedWaiters = 0;
    rwl->hOwningThreadId = 0;
    rwl->dwTimeoutBoost = 0; /* no info on this one, default value is 0 */
    RtlInitializeCriticalSectionEx( &rwl->rtlCS, 0, RTL_CRITICAL_SECTION_FLAG_FORCE_DEBUG_INFO );
    rwl->rtlCS.DebugInfo->Spare[0] = (DWORD_PTR)(__FILE__ ": RTL_RWLOCK.rtlCS");
    NtCreateSemaphore( &rwl->hExclusiveReleaseSemaphore, SEMAPHORE_ALL_ACCESS, NULL, 0, 65535 );
    NtCreateSemaphore( &rwl->hSharedReleaseSemaphore, SEMAPHORE_ALL_ACCESS, NULL, 0, 65535 );
}

/***********************************************************************
 *           RtlDeleteResource   (NTDLL.@)
 */
void WINAPI RtlDeleteResource(LPRTL_RWLOCK rwl)
{
    if (!rwl) return;
    RtlEnterCriticalSection( &rwl->rtlCS );
    if( rwl->iNumberActive || rwl->uExclusiveWaiters || rwl->uSharedWaiters )
        ERR("Deleting active MRSW lock (%p), expect failure\n", rwl );
    rwl->hOwningThreadId = 0;
    rwl->uExclusiveWaiters = rwl->uSharedWaiters = 0;
    rwl->iNumberActive = 0;
    NtClose( rwl->hExclusiveReleaseSemaphore );
    NtClose( rwl->hSharedReleaseSemaphore );
    RtlLeaveCriticalSection( &rwl->rtlCS );
    rwl->rtlCS.DebugInfo->Spare[0] = 0;
    RtlDeleteCriticalSection( &rwl->rtlCS );
}

/***********************************************************************
 *          RtlAcquireResourceExclusive	(NTDLL.@)
 */
BYTE WINAPI RtlAcquireResourceExclusive(LPRTL_RWLOCK rwl, BYTE fWait)
{
    BYTE retVal = 0;

    if (!rwl) return 0;

    for (;;)
    {
        RtlEnterCriticalSection( &rwl->rtlCS );
        if( rwl->iNumberActive == 0 ) /* lock is free */
        {
            rwl->iNumberActive = -1;
            retVal = 1;
        }
        else if( rwl->iNumberActive < 0 ) /* exclusive lock in progress */
        {
            if( rwl->hOwningThreadId == ULongToHandle(GetCurrentThreadId()) )
            {
                retVal = 1;
                rwl->iNumberActive--;
                break;
            }
        wait:
            if( fWait )
            {
                NTSTATUS status;

                rwl->uExclusiveWaiters++;

                RtlLeaveCriticalSection( &rwl->rtlCS );
                status = NtWaitForSingleObject( rwl->hExclusiveReleaseSemaphore, FALSE, NULL );
                if( HIWORD(status) ) break;
                continue; /* restart the acquisition to avoid deadlocks */
            }
        }
        else  /* one or more shared locks are in progress */
            if( fWait )
                goto wait;

        if( retVal == 1 ) rwl->hOwningThreadId = ULongToHandle(GetCurrentThreadId());
        break;
    }
    RtlLeaveCriticalSection( &rwl->rtlCS );
    return retVal;
}

/***********************************************************************
 *          RtlAcquireResourceShared  (NTDLL.@)
 */
BYTE WINAPI RtlAcquireResourceShared(LPRTL_RWLOCK rwl, BYTE fWait)
{
    NTSTATUS status = STATUS_UNSUCCESSFUL;
    BYTE retVal = 0;

    if (!rwl) return 0;
    for (;;)
    {
        RtlEnterCriticalSection( &rwl->rtlCS );
        if( rwl->iNumberActive < 0 )
        {
            if( rwl->hOwningThreadId == ULongToHandle(GetCurrentThreadId()) )
            {
                rwl->iNumberActive--;
                retVal = 1;
                break;
            }

            if( fWait )
            {
                rwl->uSharedWaiters++;
                RtlLeaveCriticalSection( &rwl->rtlCS );
                status = NtWaitForSingleObject( rwl->hSharedReleaseSemaphore, FALSE, NULL );
                if( HIWORD(status) ) break;
                continue;
            }
        }
        else
        {
            if( status != STATUS_WAIT_0 ) /* otherwise RtlReleaseResource() has already done it */
                rwl->iNumberActive++;
            retVal = 1;
        }
        break;
    }
    RtlLeaveCriticalSection( &rwl->rtlCS );
    return retVal;
}


/***********************************************************************
 *           RtlReleaseResource  (NTDLL.@)
 */
void WINAPI RtlReleaseResource(LPRTL_RWLOCK rwl)
{
    RtlEnterCriticalSection( &rwl->rtlCS );

    if( rwl->iNumberActive > 0 ) /* have one or more readers */
    {
	if( --rwl->iNumberActive == 0 )
	{
	    if( rwl->uExclusiveWaiters )
	    {
		rwl->uExclusiveWaiters--;
		NtReleaseSemaphore( rwl->hExclusiveReleaseSemaphore, 1, NULL );
	    }
	}
    }
    else if( rwl->iNumberActive < 0 ) /* have a writer, possibly recursive */
    {
	if( ++rwl->iNumberActive == 0 )
	{
	    rwl->hOwningThreadId = 0;
	    if( rwl->uExclusiveWaiters )
	    {
		rwl->uExclusiveWaiters--;
		NtReleaseSemaphore( rwl->hExclusiveReleaseSemaphore, 1, NULL );
	    }
	    else if( rwl->uSharedWaiters )
            {
                UINT n = rwl->uSharedWaiters;
                rwl->iNumberActive = rwl->uSharedWaiters; /* prevent new writers from joining until
                                                           * all queued readers have done their thing */
                rwl->uSharedWaiters = 0;
                NtReleaseSemaphore( rwl->hSharedReleaseSemaphore, n, NULL );
            }
	}
    }
    RtlLeaveCriticalSection( &rwl->rtlCS );
}


/***********************************************************************
 *           RtlDumpResource		(NTDLL.@)
 */
void WINAPI RtlDumpResource(LPRTL_RWLOCK rwl)
{
    if (!rwl) return;
    ERR( "%p: active count = %i waiting readers = %i waiting writers = %i owner thread = %p",
         rwl, rwl->iNumberActive, rwl->uSharedWaiters, rwl->uExclusiveWaiters, rwl->hOwningThreadId );
    ERR( "\n" );
}


struct barrier_impl
{
    LONG spin_count;
    LONG total_thread_count;
    volatile LONG reached_thread_count;
    volatile LONG structure_lock_count;
    volatile LONG waiting_thread_count;
    volatile LONG wait_barrier_complete;
};

C_ASSERT( sizeof(struct barrier_impl) <= sizeof(RTL_BARRIER) );

/***********************************************************************
 *           RtlInitBarrier  (NTDLL.@)
 */
NTSTATUS WINAPI RtlInitBarrier( RTL_BARRIER *barrier, LONG thread_count, LONG spin_count )
{
    struct barrier_impl *b = (struct barrier_impl *)barrier;

    TRACE( "barrier %p, thread_count %ld, spin_count %ld.\n", barrier, thread_count, spin_count );

    if (!barrier) return STATUS_INVALID_PARAMETER;
    b->total_thread_count = thread_count;
    b->spin_count = spin_count;
    b->reached_thread_count = 0;
    b->structure_lock_count = 0;
    b->waiting_thread_count = 0;
    b->wait_barrier_complete = 0;
    return STATUS_SUCCESS;
}


/***********************************************************************
 *           RtlDeleteBarrier  (NTDLL.@)
 */
void WINAPI RtlDeleteBarrier( RTL_BARRIER *barrier )
{
    struct barrier_impl *b = (struct barrier_impl *)barrier;
    LONG count;

    TRACE( "barrier %p.\n", barrier );

    if (!barrier) return;
    if (ReadAcquire( &b->reached_thread_count ) < b->total_thread_count && b->structure_lock_count)
    {
        /* On Windows this case will make RtlDeleteBarrier and the threads joining after wait forever,
         * unless the threads joining after will have SYNCHRONIZATION_BARRIER_FLAGS_NO_DELETE. */
        ERR( "called before the barrier wait is satisfied.\n" );
    }
    while ((count = ReadAcquire( &b->structure_lock_count )))
        RtlWaitOnAddress( (void *)&b->structure_lock_count, &count, sizeof(b->structure_lock_count), NULL );
}


/***********************************************************************
 *           RtlBarrier  (NTDLL.@)
 */
BOOLEAN WINAPI RtlBarrier( RTL_BARRIER *barrier, ULONG flags )
{
    static unsigned int once;
    static const LONG zero;

    struct barrier_impl *b = (struct barrier_impl *)barrier;
    unsigned int spin_count, count;
    BOOL ret = FALSE;

    TRACE( "barrier %p, flags %#lx.\n", barrier, flags );

    if (flags & ~0x10000 && !once++) FIXME( "Unknown flags %#lx.\n", flags );
    if (!barrier) return FALSE;

    /* Incrementing reached_thread_count may trigger RTL_BARRIER data desrtuction from another thread,
     * so lock RtlDeleteBarrier with waiting_thread_count before that. */
    if (flags & 0x10000) InterlockedIncrement( &b->structure_lock_count );

    /* On Windows the long wait doesn't consume CPU with any spin count, so probably the spin count
     * is limited or not used at all. */
    spin_count = min( 2000, (unsigned int)b->spin_count );

    /* Wait for previous wait iteration to complete. */
    count = 0;
    while (ReadAcquire( &b->reached_thread_count ) == b->total_thread_count)
    {
        if (count < spin_count)
        {
            ++count;
            YieldProcessor();
            continue;
        }
        RtlWaitOnAddress( (void *)&b->reached_thread_count, &b->total_thread_count,
                          sizeof(b->reached_thread_count), NULL );
    }
    InterlockedIncrement( &b->waiting_thread_count );
    if (InterlockedIncrement( &b->reached_thread_count ) == b->total_thread_count)
    {
        WriteRelease( &b->wait_barrier_complete, 1 );
        RtlWakeAddressAll( (const void *)&b->wait_barrier_complete );
        ret = TRUE;
        goto done;
    }
    count = 0;
    while (ReadAcquire( &b->reached_thread_count ) < b->total_thread_count )
    {
        if (count < spin_count)
        {
            ++count;
            YieldProcessor();
            continue;
        }
        RtlWaitOnAddress( (void *)&b->wait_barrier_complete, &zero, sizeof(b->wait_barrier_complete), NULL );
    }

done:
    if (!InterlockedDecrement( &b->waiting_thread_count ))
    {
        WriteRelease( &b->wait_barrier_complete, 0 );
        WriteRelease( &b->reached_thread_count, 0 );
        RtlWakeAddressAll( (const void *)&b->reached_thread_count );
    }

    if (flags & 0x10000 && !InterlockedDecrement( &b->structure_lock_count ))
    {
        /* Now RTL_BARRIER structure contents may become invalid. Signaling on its address should be fine, the worst
         * (unlikely) case it will wake something unrelated on reused address but that should be a legitimate spurious
         * wakeup case. */
        RtlWakeAddressAll( (const void *)&b->structure_lock_count );
    }
    return ret;
}
