/*
 * Server-side semaphore management
 *
 * Copyright (C) 1998 Alexandre Julliard
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

#include "config.h"

#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <sys/types.h>

#include "ntstatus.h"
#include "windef.h"
#include "winternl.h"

#include "handle.h"
#include "thread.h"
#include "request.h"
#include "security.h"

#ifdef WINE_IOS
/* iOS-Madeira ml1010: the in-process fast path, extended from events to
 * semaphores.  See the long comment at the head of
 * include/wine/madeira_fastsync.h; the cell table itself is defined in
 * wine/server/event.c, which also owns the allocator and its free list. */
#include "wine/madeira_fastsync.h"
#endif

static const WCHAR semaphore_name[] = {'S','e','m','a','p','h','o','r','e'};

struct type_descr semaphore_type =
{
    { semaphore_name, sizeof(semaphore_name) },   /* name */
    SEMAPHORE_ALL_ACCESS,                         /* valid_access */
    {                                             /* mapping */
        STANDARD_RIGHTS_READ | SEMAPHORE_QUERY_STATE,
        STANDARD_RIGHTS_WRITE | SEMAPHORE_MODIFY_STATE,
        STANDARD_RIGHTS_EXECUTE | SYNCHRONIZE,
        SEMAPHORE_ALL_ACCESS
    },
};

struct semaphore_sync
{
    struct object       obj;                /* object header */
    unsigned int        count;              /* current count */
    unsigned int        max;                /* maximum possible count */
#ifdef WINE_IOS
    int                 cell;               /* ml1010 fastsync cell, -1 = none */
    unsigned int        claimed;            /* tokens taken by signaled() and
                                             * not yet consumed by satisfied().
                                             * Transient: only ever non-zero
                                             * inside one check_wait() pass on
                                             * the single server thread. */
#endif
};

static void semaphore_sync_dump( struct object *obj, int verbose );
static int semaphore_sync_signaled( struct object *obj, struct wait_queue_entry *entry );
static void semaphore_sync_satisfied( struct object *obj, struct wait_queue_entry *entry );
#ifdef WINE_IOS
static int semaphore_sync_add_queue( struct object *obj, struct wait_queue_entry *entry );
static void semaphore_sync_remove_queue( struct object *obj, struct wait_queue_entry *entry );
static void semaphore_sync_destroy( struct object *obj );
#endif

static const struct object_ops semaphore_sync_ops =
{
    sizeof(struct semaphore_sync), /* size */
    &no_type,                      /* type */
    semaphore_sync_dump,           /* dump */
#ifdef WINE_IOS
    /* ml1010: exactly as for an event -- these maintain cell->srv_waiters,
     * which is the flag a client-side release reads to decide whether the
     * server still has to be told to re-run its own wait queue.  The increment
     * is visible before the server evaluates the count, because wait_on() adds
     * every queue entry and only then does check_wait() call signaled(). */
    semaphore_sync_add_queue,      /* add_queue */
    semaphore_sync_remove_queue,   /* remove_queue */
#else
    add_queue,                     /* add_queue */
    remove_queue,                  /* remove_queue */
#endif
    semaphore_sync_signaled,       /* signaled */
    semaphore_sync_satisfied,      /* satisfied */
    no_signal,                     /* signal */
    no_get_fd,                     /* get_fd */
    default_get_sync,              /* get_sync */
    default_map_access,            /* map_access */
    default_get_sd,                /* get_sd */
    default_set_sd,                /* set_sd */
    default_get_full_name,         /* get_full_name */
    no_lookup_name,                /* lookup_name */
    directory_link_name,           /* link_name */
    default_unlink_name,           /* unlink_name */
    no_open_file,                  /* open_file */
    no_kernel_obj_list,            /* get_kernel_obj_list */
    no_close_handle,               /* close_handle */
#ifdef WINE_IOS
    semaphore_sync_destroy         /* destroy */
#else
    no_destroy                     /* destroy */
#endif
};

#ifdef WINE_IOS

/* ---------------------------------------------------------------------------
 * ml1010: the cell accessors.  Every one of them is a 64-bit atomic on
 * cell->sg, for the reason ml990 gives for events: a 32-bit store to the low
 * half would be a mixed-size data race against the clients' 64-bit CASes.  The
 * server is the only writer of the generation and runs on one thread, so it
 * rebuilds the whole word from the generation it read in the same load.
 * -------------------------------------------------------------------------*/

/* Current count, cell or no cell.  `sem->count' is the fallback and is only
 * authoritative once the cell has been disabled. */
static unsigned int semaphore_sync_count( struct semaphore_sync *sem )
{
    if (sem->cell >= 0)
    {
        int st = MADEIRA_SG_STATE( __atomic_load_n( &madeira_sync_cells[sem->cell].sg,
                                                    __ATOMIC_SEQ_CST ) );
        if (st != MADEIRA_CELL_DISABLED) return (unsigned int)st;
    }
    return sem->count;
}

/* Add `add' tokens, refusing the whole operation on overflow.  Returns 1 and
 * stores the PREVIOUS count on success; returns 0 and changes nothing when the
 * result would pass `max'.  This is the cell twin of the arithmetic in
 * release_semaphore() below, and it is a CAS loop because clients CAS the same
 * word (a consumer takes one, another releaser adds its own). */
static int semaphore_cell_add( struct semaphore_sync *sem, unsigned int add, unsigned int *prev )
{
    struct madeira_sync_cell *cell = &madeira_sync_cells[sem->cell];
    uint64_t sg = __atomic_load_n( &cell->sg, __ATOMIC_SEQ_CST );

    for (;;)
    {
        int cur = MADEIRA_SG_STATE( sg );

        if (cur == MADEIRA_CELL_DISABLED) return -1;        /* caller falls back */
        if (add > sem->max || (unsigned int)cur + add > sem->max)
        {
            if (prev) *prev = (unsigned int)cur;
            return 0;
        }
        if (__atomic_compare_exchange_n( &cell->sg, &sg,
                                         MADEIRA_SG( MADEIRA_SG_GEN( sg ), cur + (int)add ), 1,
                                         __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST ))
        {
            if (prev) *prev = (unsigned int)cur;
            return 1;
        }
    }
}

/* Take ONE token if there is one.  The loop matters: a client release landing
 * between the load and the CAS must not make this answer "not signaled" while
 * a token is sitting in the cell -- that would be a queued thread left asleep
 * with work available.  (The client's Dekker half would eventually re-wake it
 * through release_semaphore(count=0), but a retry here is one instruction and
 * removes the need to rely on that for liveness.) */
static int semaphore_cell_take( struct semaphore_sync *sem )
{
    struct madeira_sync_cell *cell = &madeira_sync_cells[sem->cell];
    uint64_t sg = __atomic_load_n( &cell->sg, __ATOMIC_SEQ_CST );

    for (;;)
    {
        int cur = MADEIRA_SG_STATE( sg );

        if (cur <= 0) return 0;                  /* empty, or DISABLED */
        if (__atomic_compare_exchange_n( &cell->sg, &sg,
                                         MADEIRA_SG( MADEIRA_SG_GEN( sg ), cur - 1 ), 1,
                                         __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST ))
            return 1;
    }
}

/* Wake client threads parked on the cell.  One release of n tokens wakes one
 * waiter for n == 1 and ALL of them for n > 1: os_sync_wake_by_address has no
 * "wake exactly n", and over-waking is safe because every woken waiter re-runs
 * the CAS and re-parks if it loses. */
static void semaphore_cell_wake( struct semaphore_sync *sem, unsigned int count )
{
    struct madeira_sync_cell *cell = &madeira_sync_cells[sem->cell];

    if (__atomic_load_n( &cell->waiters, __ATOMIC_SEQ_CST ))
        madeira_fast_wake( madeira_cell_futex( cell ), count > 1 );
}

/* One-way exit from the fast path, the semaphore twin of
 * event_sync_disable_cell(): fold the live count back into `sem->count', store
 * DISABLED and wake every parked client so it re-reads the word and goes to
 * the server.  Taken by the client-side watchdog when it observes a real
 * disagreement, and by nothing else. */
static void semaphore_sync_disable_cell( struct semaphore_sync *sem )
{
    struct madeira_sync_cell *cell;
    uint64_t sg;

    if (sem->cell < 0) return;
    cell = &madeira_sync_cells[sem->cell];
    sg = __atomic_load_n( &cell->sg, __ATOMIC_SEQ_CST );
    while (MADEIRA_SG_STATE( sg ) != MADEIRA_CELL_DISABLED)
    {
        if (__atomic_compare_exchange_n( &cell->sg, &sg,
                                         MADEIRA_SG( MADEIRA_SG_GEN( sg ), MADEIRA_CELL_DISABLED ), 1,
                                         __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST ))
        {
            sem->count = (unsigned int)MADEIRA_SG_STATE( sg );
            break;
        }
    }
    if (__atomic_load_n( &cell->waiters, __ATOMIC_SEQ_CST ))
        madeira_fast_wake( madeira_cell_futex( cell ), 1 );
}

static int semaphore_sync_add_queue( struct object *obj, struct wait_queue_entry *entry )
{
    struct semaphore_sync *sem = (struct semaphore_sync *)obj;

    assert( obj->ops == &semaphore_sync_ops );
    if (sem->cell >= 0)
        __atomic_add_fetch( &madeira_sync_cells[sem->cell].srv_waiters, 1, __ATOMIC_SEQ_CST );
    return add_queue( obj, entry );
}

static void semaphore_sync_remove_queue( struct object *obj, struct wait_queue_entry *entry )
{
    /* remove_queue() ends in release_object( obj ), so read the index first --
     * the same care event_sync_remove_queue() takes, for the same reason. */
    int cell = ((struct semaphore_sync *)obj)->cell;

    assert( obj->ops == &semaphore_sync_ops );
    remove_queue( obj, entry );
    if (cell >= 0)
        __atomic_sub_fetch( &madeira_sync_cells[cell].srv_waiters, 1, __ATOMIC_SEQ_CST );
}

static void semaphore_sync_destroy( struct object *obj )
{
    struct semaphore_sync *sem = (struct semaphore_sync *)obj;

    assert( obj->ops == &semaphore_sync_ops );
    if (sem->cell >= 0) madeira_sem_cell_free( sem->cell );
    sem->cell = -1;
}

/* ml1010: hand back a token that semaphore_sync_signaled() claimed for a
 * wait-all that then turned out not to be satisfiable.  Reached from
 * check_wait() through object_sync_unclaim(); the ops check makes it a no-op
 * for every other kind of sync object, so it needs no ops-table entry.
 *
 * No wake_up() here, deliberately, and for the same reason the event twin has
 * none: this runs within check_wait(), and the wake_up() that delivered the
 * token in the first place walks the queue past this entry and re-evaluates
 * the next one, which by then sees the token back in the cell.  The futex wake
 * IS needed, because a client may be parked on the word. */
void madeira_semaphore_sync_unclaim( struct object *obj )
{
    struct semaphore_sync *sem = (struct semaphore_sync *)obj;
    struct madeira_sync_cell *cell;
    uint64_t sg;

    if (obj->ops != &semaphore_sync_ops) return;
    if (sem->cell < 0 || !sem->claimed) return;
    sem->claimed--;
    cell = &madeira_sync_cells[sem->cell];
    sg = __atomic_load_n( &cell->sg, __ATOMIC_SEQ_CST );
    for (;;)
    {
        int cur = MADEIRA_SG_STATE( sg );

        if (cur == MADEIRA_CELL_DISABLED)
        {
            /* the cell was disabled between the claim and here: the count it
             * folded back did not include this token, so give it back there */
            sem->count++;
            return;
        }
        if (__atomic_compare_exchange_n( &cell->sg, &sg,
                                         MADEIRA_SG( MADEIRA_SG_GEN( sg ), cur + 1 ), 1,
                                         __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST ))
            break;
    }
    if (__atomic_load_n( &cell->waiters, __ATOMIC_SEQ_CST ))
        madeira_fast_wake( madeira_cell_futex( cell ), 0 );
}

#endif /* WINE_IOS */

static int release_semaphore( struct semaphore_sync *sem, unsigned int count,
                              unsigned int *prev )
{
#ifdef WINE_IOS
    if (sem->cell >= 0)
    {
        int ret = semaphore_cell_add( sem, count, prev );

        if (ret >= 0)
        {
            if (!ret)
            {
                set_error( STATUS_SEMAPHORE_LIMIT_EXCEEDED );
                return 0;
            }
            /* Unlike upstream this wakes even when the previous count was not
             * zero.  Upstream's "there cannot be any thread to wake up if the
             * count is != 0" stops being true the moment clients can add
             * tokens without telling the server: a queued thread can be sitting
             * on a count that another thread raised off-server.  wake_up() over
             * a satisfied or empty queue is a no-op, and the futex wake is
             * skipped entirely when cell->waiters is 0.
             *
             * count == 0 is the PROTOCOL: it is the request a client sends
             * after doing the release itself, to make the server re-run its own
             * queue against the word the client already updated.  It adds
             * nothing, so it can only ever hand out tokens that are really
             * there -- semaphore_sync_signaled() CASes them out one at a time
             * and fails when a fast waiter got there first.  It also needs no
             * futex wake: it added no token, and the client that sent it has
             * already woken the parked waiters itself.
             *
             * ml1060: THE WAKE LIMIT IS 0 ("no limit"), NOT `count'.
             * `wake_up( obj, n )' means "stop after n threads have been
             * satisfied", and upstream may use `count' for it because upstream's
             * count IS the number of tokens that just appeared.  Here it is not:
             * a client can have raised the cell without telling the server (its
             * Dekker load of srv_waiters legitimately read 0 because nobody was
             * queued AT THAT INSTANT), threads can queue afterwards, and the next
             * server-side release of 1 would then wake exactly one of them and
             * leave the rest asleep on tokens that are sitting in the cell.  The
             * count == 0 protocol arm was already unlimited for precisely this
             * reason; making both arms unlimited removes the asymmetry rather
             * than relying on a later release to come and collect the backlog.
             * It cannot over-deliver: every wake runs check_wait(), which CASes
             * a token out of the cell and refuses when there is none, so the
             * number of threads released is bounded by the tokens that exist. */
            if (count) semaphore_cell_wake( sem, count );
            wake_up( &sem->obj, 0 );
            return 1;
        }
        /* DISABLED: fall through to the plain server-side arithmetic below,
         * which is authoritative again from that point on. */
    }
#endif
    if (prev) *prev = sem->count;
    if (sem->count + count < sem->count || sem->count + count > sem->max)
    {
        set_error( STATUS_SEMAPHORE_LIMIT_EXCEEDED );
        return 0;
    }
    else if (sem->count)
    {
        /* there cannot be any thread to wake up if the count is != 0 */
        sem->count += count;
    }
    else
    {
        sem->count = count;
        wake_up( &sem->obj, count );
    }
    return 1;
}

static void semaphore_sync_dump( struct object *obj, int verbose )
{
    struct semaphore_sync *sem = (struct semaphore_sync *)obj;
    assert( obj->ops == &semaphore_sync_ops );
#ifdef WINE_IOS
    fprintf( stderr, "Semaphore count=%d max=%d cell=%d\n",
             semaphore_sync_count( sem ), sem->max, sem->cell );
#else
    fprintf( stderr, "Semaphore count=%d max=%d\n", sem->count, sem->max );
#endif
}

static int semaphore_sync_signaled( struct object *obj, struct wait_queue_entry *entry )
{
    struct semaphore_sync *sem = (struct semaphore_sync *)obj;
    assert( obj->ops == &semaphore_sync_ops );
#ifdef WINE_IOS
    if (sem->cell >= 0)
    {
        int st = MADEIRA_SG_STATE( __atomic_load_n( &madeira_sync_cells[sem->cell].sg,
                                                    __ATOMIC_SEQ_CST ) );
        if (st != MADEIRA_CELL_DISABLED)
        {
            /* CLAIM the token here rather than merely reporting that one
             * exists.  `satisfied' has no return value, so without the claim a
             * client CAS could take the token between this call and it, and the
             * server would report WAIT_0 to a thread that acquired nothing --
             * and then decrement a count that is already zero.  This load is
             * also the server half of the Dekker pair whose other half is the
             * client's `CAS count+=n; load srv_waiters' in NtReleaseSemaphore;
             * srv_waiters was incremented by semaphore_sync_add_queue(). */
            if (!semaphore_cell_take( sem )) return 0;
            sem->claimed++;
            return 1;
        }
    }
#endif
    return (sem->count > 0);
}

static void semaphore_sync_satisfied( struct object *obj, struct wait_queue_entry *entry )
{
    struct semaphore_sync *sem = (struct semaphore_sync *)obj;
    assert( obj->ops == &semaphore_sync_ops );
#ifdef WINE_IOS
    if (sem->claimed)
    {
        /* the token was taken out of the cell by signaled(), a few hundred
         * nanoseconds ago on this same thread; consuming the claim is the
         * whole of satisfying the wait */
        sem->claimed--;
        return;
    }
    if (sem->cell >= 0)
    {
        /* Defensive.  Every route to satisfied() for a semaphore runs
         * signaled() first (wake_thread_queue_entry(), which does not, is
         * reached only from keyed_event_signaled()), so `claimed' is always
         * non-zero above.  If that ever stops being true, take the token from
         * the cell -- which is where the count lives -- rather than decrement
         * a `sem->count' that is not the state any more. */
        if (MADEIRA_SG_STATE( __atomic_load_n( &madeira_sync_cells[sem->cell].sg,
                                               __ATOMIC_SEQ_CST ) ) != MADEIRA_CELL_DISABLED)
        {
            semaphore_cell_take( sem );
            return;
        }
    }
#endif
    assert( sem->count );
    sem->count--;
}

static struct object *create_semaphore_sync( unsigned int initial, unsigned int max )
{
    struct semaphore_sync *sem;

    if (get_inproc_device_fd() >= 0) return (struct object *)create_inproc_semaphore_sync( initial, max );

    if (!(sem = alloc_object( &semaphore_sync_ops ))) return NULL;
    sem->count = initial;
    sem->max   = max;
#ifdef WINE_IOS
    sem->claimed = 0;
    sem->cell    = madeira_sem_cell_alloc( initial, max );
#endif
    return &sem->obj;
}

struct semaphore
{
    struct object          obj;    /* object header */
    struct object         *sync;   /* semaphore sync object */
};

static void semaphore_dump( struct object *obj, int verbose );
static struct object *semaphore_get_sync( struct object *obj );
static int semaphore_signal( struct object *obj, unsigned int access, int signal );
static void semaphore_destroy( struct object *obj );

static const struct object_ops semaphore_ops =
{
    sizeof(struct semaphore),      /* size */
    &semaphore_type,               /* type */
    semaphore_dump,                /* dump */
    NULL,                          /* add_queue */
    NULL,                          /* remove_queue */
    NULL,                          /* signaled */
    NULL,                          /* satisfied */
    semaphore_signal,              /* signal */
    no_get_fd,                     /* get_fd */
    semaphore_get_sync,            /* get_sync */
    default_map_access,            /* map_access */
    default_get_sd,                /* get_sd */
    default_set_sd,                /* set_sd */
    default_get_full_name,         /* get_full_name */
    no_lookup_name,                /* lookup_name */
    directory_link_name,           /* link_name */
    default_unlink_name,           /* unlink_name */
    no_open_file,                  /* open_file */
    no_kernel_obj_list,            /* get_kernel_obj_list */
    no_close_handle,               /* close_handle */
    semaphore_destroy,             /* destroy */
};

static struct semaphore *create_semaphore( struct object *root, const struct unicode_str *name,
                                           unsigned int attr, unsigned int initial, unsigned int max,
                                           const struct security_descriptor *sd )
{
    struct semaphore *sem;

    if (!max || (initial > max))
    {
        set_error( STATUS_INVALID_PARAMETER );
        return NULL;
    }
    if ((sem = create_named_object( root, &semaphore_ops, name, attr, sd )))
    {
        if (get_error() != STATUS_OBJECT_NAME_EXISTS)
        {
            /* initialize it if it didn't already exist */
            sem->sync = NULL;

            if (!(sem->sync = create_semaphore_sync( initial, max )))
            {
                release_object( sem );
                return NULL;
            }
        }
    }
    return sem;
}

static void semaphore_dump( struct object *obj, int verbose )
{
    struct semaphore *sem = (struct semaphore *)obj;
    assert( obj->ops == &semaphore_ops );
    sem->sync->ops->dump( sem->sync, verbose );
}

static struct object *semaphore_get_sync( struct object *obj )
{
    struct semaphore *sem = (struct semaphore *)obj;
    assert( obj->ops == &semaphore_ops );
    return grab_object( sem->sync );
}

static int semaphore_signal( struct object *obj, unsigned int access, int signal )
{
    struct semaphore *sem = (struct semaphore *)obj;
    assert( obj->ops == &semaphore_ops );

    assert( sem->sync->ops == &semaphore_sync_ops ); /* never called with inproc syncs */
    assert( signal == -1 ); /* always called from signal_object */

    if (!(access & SEMAPHORE_MODIFY_STATE))
    {
        set_error( STATUS_ACCESS_DENIED );
        return 0;
    }
    return release_semaphore( (struct semaphore_sync *)sem->sync, 1, NULL );
}

static void semaphore_destroy( struct object *obj )
{
    struct semaphore *sem = (struct semaphore *)obj;
    assert( obj->ops == &semaphore_ops );
    if (sem->sync) release_object( sem->sync );
}

#ifdef WINE_IOS
/* ml1010: the handle -> cell lookup behind DECL_HANDLER(get_inproc_sync_fd).
 * Returns -1 for anything that is not a live cell-backed semaphore. */
int madeira_semaphore_cell_index( struct object *obj )
{
    struct semaphore *sem;
    struct semaphore_sync *sync;

    if (obj->ops != &semaphore_ops) return -1;
    sem = (struct semaphore *)obj;
    if (!sem->sync || sem->sync->ops != &semaphore_sync_ops) return -1;
    sync = (struct semaphore_sync *)sem->sync;
    if (sync->cell < 0) return -1;
    if (MADEIRA_SG_STATE( __atomic_load_n( &madeira_sync_cells[sync->cell].sg,
                                           __ATOMIC_SEQ_CST ) ) == MADEIRA_CELL_DISABLED) return -1;
    return sync->cell;
}

/* ml1010: the self-heal half of the client-side watchdog, reached through
 * MADEIRA_SEM_OP_DISABLE.  Returns 0 for an object that has no cell, which is
 * not an error -- the client may have raced a re-learn, and asking twice must
 * be harmless. */
int madeira_semaphore_disable_cell( struct object *obj )
{
    struct semaphore *sem;

    if (obj->ops != &semaphore_ops) return 0;
    sem = (struct semaphore *)obj;
    if (!sem->sync || sem->sync->ops != &semaphore_sync_ops) return 0;
    semaphore_sync_disable_cell( (struct semaphore_sync *)sem->sync );
    return 1;
}
#endif

/* create a semaphore */
DECL_HANDLER(create_semaphore)
{
    struct semaphore *sem;
    struct unicode_str name;
    struct object *root;
    const struct security_descriptor *sd;
    const struct object_attributes *objattr = get_req_object_attributes( &sd, &name, &root );

    if (!objattr) return;

    if ((sem = create_semaphore( root, &name, objattr->attributes, req->initial, req->max, sd )))
    {
        if (get_error() == STATUS_OBJECT_NAME_EXISTS)
            reply->handle = alloc_handle( current->process, sem, req->access, objattr->attributes );
        else
            reply->handle = alloc_handle_no_access_check( current->process, sem,
                                                          req->access, objattr->attributes );
        release_object( sem );
    }

    if (root) release_object( root );
}

/* open a handle to a semaphore */
DECL_HANDLER(open_semaphore)
{
    struct unicode_str name = get_req_unicode_str();

    reply->handle = open_object( current->process, req->rootdir, req->access,
                                 &semaphore_ops, &name, req->attributes );
}

/* release a semaphore */
DECL_HANDLER(release_semaphore)
{
    struct semaphore *sem;

    if ((sem = (struct semaphore *)get_handle_obj( current->process, req->handle,
                                                   SEMAPHORE_MODIFY_STATE, &semaphore_ops )))
    {
        struct semaphore_sync *sync = (struct semaphore_sync *)sem->sync;
        assert( sem->sync->ops == &semaphore_sync_ops ); /* never called with inproc syncs */

        release_semaphore( sync, req->count, &reply->prev_count );
        release_object( sem );
    }
}

/* query details about the semaphore */
DECL_HANDLER(query_semaphore)
{
    struct semaphore *sem;

    if ((sem = (struct semaphore *)get_handle_obj( current->process, req->handle,
                                                   SEMAPHORE_QUERY_STATE, &semaphore_ops )))
    {
        struct semaphore_sync *sync = (struct semaphore_sync *)sem->sync;
        assert( sem->sync->ops == &semaphore_sync_ops ); /* never called with inproc syncs */

#ifdef WINE_IOS
        reply->current = semaphore_sync_count( sync );
#else
        reply->current = sync->count;
#endif
        reply->max = sync->max;
        release_object( sem );
    }
}
