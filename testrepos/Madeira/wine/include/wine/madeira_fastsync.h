/*
 * Madeira fastsync: the shared cell table of the opt-in in-process event and
 * semaphore fast path (iOS only).
 *
 * Copyright 2026 125hz
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

/*
 * WHAT THIS IS
 * ------------
 * On iOS the wineserver is a thread in the same Mach task as every guest
 * thread, so a server round trip is a socket write, two scheduler hops and a
 * socket write back.  Fastsync is an alternative to madsync for the event and
 * semaphore operations that dominate that traffic: each handle-reachable event
 * (and, with MADEIRA_FASTSYNC_SEM, each semaphore) gets a cell in one array
 * that the server and every guest thread share, and the cell's state word IS
 * the object's state.  The server's signaled()/satisfied()/signal() hooks read
 * and write the cell where they used to read and write their own field, and a
 * client can set, reset, take or poll the object with a compare-and-swap plus
 * at most one os_sync_wake_by_address.
 *
 * It is OFF unless MADEIRA_FASTSYNC asks for it, and it never runs together
 * with madsync: when the server hands out madsync objects, no cell is
 * allocated and the client takes no fast path.  With it off, every hook falls
 * through to the unchanged upstream code.
 *
 * MADEIRA_FASTSYNC (read once per app run by both halves)
 *   unset, "0", "off"  off: no cells, the upstream server and client.
 *   "cells"            the server keeps state in cells; the client only
 *                      answers zero-timeout polls that the cell proves are
 *                      NOT signaled (it never consumes or mints a token).
 *   "auto"             cells, plus the client wake path, armed once the task
 *                      has issued more than MADEIRA_FS_AUTO_REQS (20000)
 *                      event/semaphore/single-wait operations in 10 s.  A
 *                      quiet process (a launcher, an installer) never arms.
 *   "1", "on"          cells and the wake path from the first call.
 * MADEIRA_FASTSYNC_SEM=1 extends the cells to semaphores (off by default).
 *
 * WHO OWNS WHAT
 * -------------
 * The table is defined by server/event.c and referenced by
 * dlls/ntdll/unix/sync.c; both are linked into the one iOS image.  Cell
 * allocation and freeing happen only on the server thread.  Everything a
 * client touches is an atomic on one of the words below.
 *
 * THE STATE WORD
 * --------------
 *   MADEIRA_CELL_RESET     (0)  not signaled; also the futex sleep value.
 *   MADEIRA_CELL_SET       (1)  signaled, token up for grabs.
 *   MADEIRA_CELL_CLAIMED   (2)  signaled, but the server has decided (inside
 *                               signaled()) to hand this auto-reset token to
 *                               one of its own queued waiters.  Exists only
 *                               between check_wait() and end_wait() on the
 *                               server thread.  Clients must not consume it.
 *   MADEIRA_CELL_DISABLED (-1)  this object has left the fast path for good
 *                               (first PulseEvent, the client watchdog, or the
 *                               cell being freed).  The server falls back to
 *                               its own field and clients go to the server.
 *
 * For a semaphore cell the state half is the current COUNT (0..max);
 * RESET (0) means empty, DISABLED (-1) is the same one-way exit, and 1 and 2
 * are counts.  Every reader branches on `kind' first.
 *
 * THE TWO DEKKER PAIRINGS
 * -----------------------
 * (1) client setter vs. server waiter:
 *       client:  store state = SET (seq_cst); load srv_waiters (seq_cst)
 *                -> if != 0 also send the request so the server wakes its
 *                   own queue (MADEIRA_EVENT_OP_WAKE, or release_semaphore
 *                   with count 0; never a second set)
 *       server:  srv_waiters++ (seq_cst, add_queue); load state (seq_cst,
 *                signaled(), which check_wait() runs after wait_on())
 * (2) client setter vs. client waiter: the same shape with `waiters'.  The
 *     park re-checks the word inside the syscall, so a set that lands
 *     between the waiter's load and the syscall does not sleep.
 * On a total order at least one side of each pair sees the other; the worst
 * case is a redundant wake, never a lost one.
 *
 * THE GENERATION IS PACKED INTO THE STATE WORD
 * --------------------------------------------
 * `gen' is bumped on every allocation and every free, and lives in the high
 * half of the same 64-bit word as the state, so the CAS that takes a token
 * also proves the cell has not changed hands since the caller resolved it.
 * The futex still waits on the low (state) half: a pure generation bump does
 * not wake a parked waiter, and every recycle also changes the low half.
 * Every access to `sg' is a 64-bit atomic on both sides.
 */

#ifndef __WINE_MADEIRA_FASTSYNC_H
#define __WINE_MADEIRA_FASTSYNC_H

#include <stdint.h>

/* 8192 cells x 32 bytes = 256 KB of zero-fill BSS; untouched pages are never
 * committed.  Past the end the allocator answers "no cell" and that object
 * keeps the plain server behaviour, so this is a tuning constant. */
#define MADEIRA_SYNC_CELLS      8192

#define MADEIRA_CELL_DISABLED   (-1)
#define MADEIRA_CELL_RESET      0
#define MADEIRA_CELL_SET        1
#define MADEIRA_CELL_CLAIMED    2

/* Which object owns a cell; immutable for the life of a generation. */
#define MADEIRA_CELL_KIND_EVENT 0
#define MADEIRA_CELL_KIND_SEM   1

/* The packed {gen, state} word.  `state' is the low 32 bits read back SIGNED,
 * so MADEIRA_CELL_DISABLED survives the round trip. */
#define MADEIRA_SG(gen, state)  (((uint64_t)(unsigned int)(gen) << 32) | \
                                 (uint64_t)(uint32_t)(int32_t)(state))
#define MADEIRA_SG_GEN(sg)      ((unsigned int)((uint64_t)(sg) >> 32))
#define MADEIRA_SG_STATE(sg)    ((int)(int32_t)(uint32_t)(uint64_t)(sg))

struct madeira_sync_cell
{
    uint64_t     sg;           /* packed {gen:63..32, state:31..0}               */
    int          srv_waiters;  /* server wait_queue entries on this object       */
    int          waiters;      /* client threads parked on the state half        */
    unsigned int manual;       /* 1 = manual-reset event                         */
    unsigned int kind;         /* MADEIRA_CELL_KIND_*                            */
    unsigned int smax;         /* semaphore maximum count, immutable             */
    unsigned int reserved;     /* keeps the cell at 32 bytes, two per cache line */
};

/* The kind, read without synchronisation on purpose: it is written before the
 * store of `sg' that publishes the cell, and every operation that acts on it
 * re-validates the generation in the same atomic that performs the operation. */
static inline unsigned int madeira_cell_kind( const struct madeira_sync_cell *cell )
{
    return __atomic_load_n( &cell->kind, __ATOMIC_RELAXED );
}

/* "Could a waiter be released right now?" for a state read from a load whose
 * generation the caller has already matched.  CLAIMED is not signaled for a
 * client: the server is handing that token to one of its own waiters. */
static inline int madeira_cell_signalled( unsigned int kind, unsigned int manual, int state )
{
    if (kind == MADEIRA_CELL_KIND_SEM) return state > 0;
    if (manual) return state > 0;
    return state == MADEIRA_CELL_SET;
}

/* The futex address: the state half of `sg'.  Both sides must use this and
 * only this, or a client parked by one could never be woken by the other. */
#if defined(__BYTE_ORDER__) && defined(__ORDER_LITTLE_ENDIAN__) && \
    __BYTE_ORDER__ != __ORDER_LITTLE_ENDIAN__
#error "madeira_cell_futex() assumes the low half of sg lives at offset 0"
#endif
static inline int *madeira_cell_futex( struct madeira_sync_cell *cell )
{
    return (int *)&cell->sg;
}

extern struct madeira_sync_cell madeira_sync_cells[MADEIRA_SYNC_CELLS];

/* The get_inproc_sync_fd reply doubles as the handle -> cell learn request
 * (there is no /dev/ntsync on iOS, so no fd is ever in flight there).  Bit 30
 * of `type' says "a cell index follows"; 24 bits of index cover the table. */
#define MADEIRA_FAST_REPLY_FLAG    0x40000000
#define MADEIRA_FAST_REPLY_MANUAL  0x20000000
#define MADEIRA_FAST_REPLY_IDX(t)  ((t) & 0x00ffffff)

/* event_op opcode: "wake your queue, do not signal".  Sent by a client setter
 * that has already published SET in the cell and found srv_waiters != 0.  A
 * SET_EVENT here would mint a second token out of one SetEvent.  `op' is a
 * plain int and the server's switch rejects unknown values, so only the iOS
 * client sends it and only the iOS server accepts it; no protocol change. */
#define MADEIRA_EVENT_OP_WAKE      0x4d415741   /* 'MAWA' */

/* event_op opcode: "take this event out of the fast path, permanently".  The
 * self-heal half of the client watchdog: the server runs the same code a
 * PulseEvent runs (fold the cell into its own field, store DISABLED, wake
 * every parked client).  Accepted on a SYNCHRONIZE handle, because the thread
 * that notices the incoherence is a waiter; it changes no observable state. */
#define MADEIRA_EVENT_OP_DISABLE   0x4d414449   /* 'MADI' */

/* The same self-heal for a semaphore handle, answered before event_op's own
 * object-type check.  A semaphore needs no WAKE opcode: release_semaphore with
 * count 0 already is "change nothing, then wake_up( obj, 0 )". */
#define MADEIRA_SEM_OP_DISABLE     0x4d414453   /* 'MADS' */

/* The wake primitive, shared by both sides (the same ladder sync.c uses for
 * its futexes: os_sync_wait_on_address on iOS 17.4+, __ulock_wait below). */
#ifdef __APPLE__

#include <AvailabilityMacros.h>
#ifdef MAC_OS_VERSION_14_4
#include <os/os_sync_wait_on_address.h>
#endif

#ifndef UL_COMPARE_AND_WAIT
#define UL_COMPARE_AND_WAIT 1
#endif
#ifndef ULF_WAKE_ALL
#define ULF_WAKE_ALL 0x00000100
#endif

extern int __ulock_wait( uint32_t operation, void *addr, uint64_t value, uint32_t timeout );
extern int __ulock_wake( uint32_t operation, void *addr, uint64_t wake_value );

/* Park on *addr while it still reads `val', for at most ns_timeout ns
 * (0 = forever, which the fast path never asks for). */
static inline void madeira_fast_park( const int *addr, int val, uint64_t ns_timeout )
{
#ifdef MAC_OS_VERSION_14_4
    if (__builtin_available( macOS 14.4, iOS 17.4, * ))
    {
        if (ns_timeout)
            os_sync_wait_on_address_with_timeout( (void *)addr, (uint64_t)(uint32_t)val, 4,
                                                  OS_SYNC_WAIT_ON_ADDRESS_NONE,
                                                  OS_CLOCK_MACH_ABSOLUTE_TIME, ns_timeout );
        else
            os_sync_wait_on_address( (void *)addr, (uint64_t)(uint32_t)val, 4,
                                     OS_SYNC_WAIT_ON_ADDRESS_NONE );
        return;
    }
#endif
    {
        uint32_t us = (uint32_t)(ns_timeout / 1000);
        if (ns_timeout && !us) us = 1;
        __ulock_wait( UL_COMPARE_AND_WAIT, (void *)addr, (uint64_t)(uint32_t)val, us );
    }
}

/* Wake one parked thread, or all of them (a manual-reset event, or a
 * semaphore release of more than one token). */
static inline void madeira_fast_wake( const int *addr, int all )
{
#ifdef MAC_OS_VERSION_14_4
    if (__builtin_available( macOS 14.4, iOS 17.4, * ))
    {
        if (all) os_sync_wake_by_address_all( (void *)addr, 4, OS_SYNC_WAKE_BY_ADDRESS_NONE );
        else     os_sync_wake_by_address_any( (void *)addr, 4, OS_SYNC_WAKE_BY_ADDRESS_NONE );
        return;
    }
#endif
    __ulock_wake( UL_COMPARE_AND_WAIT | (all ? ULF_WAKE_ALL : 0), (void *)addr, 0 );
}

#else  /* !__APPLE__: fastsync is iOS-only; keep the header compilable for host models */

static inline void madeira_fast_park( const int *addr, int val, uint64_t ns_timeout ) { }
static inline void madeira_fast_wake( const int *addr, int all ) { }

#endif /* __APPLE__ */

#endif /* __WINE_MADEIRA_FASTSYNC_H */
