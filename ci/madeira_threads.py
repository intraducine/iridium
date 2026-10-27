# SPDX-License-Identifier: AGPL-3.0-only
"""Track guest pthread creation without changing Wine's join/detach ownership."""
from pathlib import Path


def apply_virtual(text):
    old = 'static struct { uint64_t base; uint64_t size; unsigned tid; unsigned freed; unsigned inuse; } ios_steer[IOS_STEER_MAX];'
    if text.count(old) != 1: raise ValueError('Madeira reservation tracking changed')
    text = text.replace(old, 'static struct { _Atomic uint64_t base, size; _Atomic unsigned tid, freed, inuse; } ios_steer[IOS_STEER_MAX];')
    text = text.replace('static unsigned ios_steer_n;', 'static _Atomic unsigned ios_steer_n;')
    start = text.index('static uint64_t ios_steer_reclaim_dead( void )\n{')
    end = text.index('/* ml255: STORM GATE.', start)
    text = text[:start] + '''static uint64_t ios_steer_reclaim_dead( void );

static void ios_steer_forget( void *base, size_t size )
{
    uint64_t begin = (uintptr_t)base, end = begin + size;
    unsigned i;
    for (i = 0; i < ios_steer_n; i++)
        if (ios_steer[i].base < end && begin < ios_steer[i].base + ios_steer[i].size)
            ios_steer[i].freed = 1;
}

static void ios_steer_record( void *base, size_t size, unsigned tid )
{
    sigset_t sigset;
    unsigned i;
    server_enter_uninterrupted_section( &virtual_mutex, &sigset );
    for (i = 0; i < ios_steer_n; i++) if (ios_steer[i].freed) break;
    if (i < IOS_STEER_MAX)
    {
        ios_steer[i].base = (uintptr_t)base;
        ios_steer[i].size = size;
        ios_steer[i].tid = tid;
        ios_steer[i].freed = ios_steer[i].inuse = 0;
        ios_thread_alive( tid );
        if (i == ios_steer_n) ios_steer_n++;
    }
    server_leave_uninterrupted_section( &virtual_mutex, &sigset );
}

''' + text[end:]
    marker = "    ios_vh_note( 'd', view );   /* madeira-bcd: view history */"
    if text.count(marker) != 1: raise ValueError('Madeira virtual view deletion changed')
    text = text.replace(marker, '    ios_steer_forget( view->base, view->size );\n' + marker)
    marker = '\n\n/***********************************************************************\n *           register_view'
    if text.count(marker) != 1: raise ValueError('Madeira virtual view registration changed')
    text = text.replace(marker, '''

/* Validate and release under one lock. A recycled address is not the old reservation. */
static uint64_t ios_steer_reclaim_dead( void )
{
    uint64_t freed = 0;
    unsigned i;
    sigset_t sigset;
    server_enter_uninterrupted_section( &virtual_mutex, &sigset );
    for (i = 0; i < ios_steer_n; i++)
    {
        struct file_view *view;
        size_t offset;
        if (ios_steer[i].freed || !ios_steer[i].base || ios_steer[i].inuse ||
            !ios_tid_is_dead( ios_steer[i].tid )) continue;
        view = find_view( (void *)(uintptr_t)ios_steer[i].base, 0 );
        if (!view || (uintptr_t)view->base != ios_steer[i].base || view->size != ios_steer[i].size ||
            view->protect || view->ios_flags) continue;
        for (offset = 0; offset < view->size; offset += page_size)
            if (get_page_vprot( (char *)view->base + offset ) & VPROT_COMMITTED) break;
        if (offset < view->size) continue;
        freed += view->size;
        ios_bigres_release( view->base );
        delete_view( view );
    }
    server_leave_uninterrupted_section( &virtual_mutex, &sigset );
    if (freed) dprintf( 2, "[steer-reclaim] released %lluMB of unused reservations\\n",
                        (unsigned long long)(freed >> 20) );
    return freed;
}
''' + marker)
    start = text.index('                if (!sst && ios_steer_n < IOS_STEER_MAX)')
    end = text.index('                /* ml210:', start)
    text = text[:start] + '''                if (!sst) ios_steer_record( *ret, want, stid );
''' + text[end:]
    changes = {
        'ios_tid_dead[tid >> 3] |= (1u << (tid & 7));':
            '__atomic_fetch_or( &ios_tid_dead[tid >> 3], (1u << (tid & 7)), __ATOMIC_RELAXED );',
        'ios_tid_dead[tid >> 3] &= ~(1u << (tid & 7));':
            '__atomic_fetch_and( &ios_tid_dead[tid >> 3], ~(1u << (tid & 7)), __ATOMIC_RELAXED );',
        '(ios_tid_dead[tid >> 3] >> (tid & 7)) & 1':
            '(__atomic_load_n( &ios_tid_dead[tid >> 3], __ATOMIC_RELAXED ) >> (tid & 7)) & 1',
    }
    for old, new in changes.items():
        if text.count(old) != 1: raise ValueError('Madeira reservation thread identity changed')
        text = text.replace(old, new)
    return text


def apply_fex(text):
    old = '#if defined(FEX_IOS_HOST) && defined(_WIN32) && !defined(ARCHITECTURE_arm64ec)'
    new = '#if defined(FEX_IOS_HOST) && defined(_WIN32)'
    if text.count(old) == 1:
        return text.replace(old, new)
    if old not in text and text.count(new) == 1:
        return text
    raise ValueError('Madeira FEX allocation-watch thread identity changed')


def apply_loader(text):
    old = 'if (ios_cur_image_info()->Machine == IMAGE_FILE_MACHINE_AMD64 && !is_arm64ec())'
    done = '    CHILD_STAGE( "server_init_process_done" );'
    if text.count(old) != 1 or text.count(done) != 1:
        raise ValueError('Madeira child ntdll selection changed')
    # A pool copy alone still inherits game hooks from the shared PE image.
    text = text.replace(old, 'if (ios_cur_image_info()->Machine == IMAGE_FILE_MACHINE_AMD64)')
    return text.replace(done, '''    /* The shared win32u host must publish its table into every new process. */
    { extern void win32u_gdi_publish_shared(void); win32u_gdi_publish_shared(); }
''' + done)


def apply_window(text):
    changes = {
        'static void *client_objects[MAX_USER_HANDLES];': '''static void *client_objects[MAX_USER_HANDLES];
static struct { HANDLE handle; DWORD pid; } client_object_owners[MAX_USER_HANDLES];

static void cache_user_object(HANDLE handle, void *ptr)
{
    UINT index = USER_HANDLE_TO_INDEX(handle);
    assert(index < MAX_USER_HANDLES);
    user_lock();
    client_object_owners[index].handle = handle;
    client_object_owners[index].pid = GetCurrentProcessId();
    InterlockedExchangePointer(&client_objects[index], ptr);
    user_unlock();
}''',
        '        InterlockedExchangePointer( &client_objects[index], ptr );':
            '        cache_user_object(handle, ptr);',
        '    InterlockedExchangePointer( &client_objects[index], ptr );':
            '    cache_user_object(handle, ptr);',
        '    else ptr = client_objects[index];': '''    else if (client_object_owners[index].handle != handle || client_object_owners[index].pid != entry.pid)
        ptr = OBJ_OTHER_PROCESS;
    else ptr = client_objects[index];''',
        '        return client_objects[i];': '''        if (client_object_owners[i].handle != *handle || client_object_owners[i].pid != entry.pid) continue;
        return client_objects[i];''',
    }
    for old, new in changes.items():
        if text.count(old) != 1: raise ValueError('Madeira USER object cache changed')
        text = text.replace(old, new)
    return text


def apply_class(text):
    changes = {
        'static WINDOWPROC winproc_array[MAX_WINPROCS];': '''static WINDOWPROC winproc_array[MAX_WINPROCS];
static void *winproc_owners[MAX_WINPROCS];''',
        'static int ios_client_procs_count;': '''static int ios_client_procs_count;

void ios_client_procs_release(void *peb)
{
    UINT i;
    pthread_mutex_lock(&winproc_lock);
    for (i = 0; i < (UINT)ios_client_procs_count; i++)
        if (ios_client_procs_reg[i].peb == peb)
        {
            if (user32_module == ios_client_procs_reg[i].user32_module)
            {
                user32_module = 0;
                memset(winproc_array, 0, NTUSER_NB_PROCS * sizeof(*winproc_array));
            }
            __atomic_store_n(&ios_client_procs_reg[i].peb, NULL, __ATOMIC_RELEASE);
            memset(ios_client_procs_reg[i].procs, 0, sizeof(ios_client_procs_reg[i].procs));
            ios_client_procs_reg[i].user32_module = 0;
        }
    for (i = NTUSER_NB_PROCS; i < winproc_used; i++)
        if (winproc_owners[i] == peb)
        {
            memset(&winproc_array[i], 0, sizeof(winproc_array[i]));
            __atomic_store_n(&winproc_owners[i], NULL, __ATOMIC_RELEASE);
        }
    pthread_mutex_unlock(&winproc_lock);
}''',
        '        if (ansi && winproc_array[i].procA != func) continue;': '''        if (__atomic_load_n(&winproc_owners[i], __ATOMIC_ACQUIRE) != NtCurrentTeb()->Peb) continue;
        if (ansi && winproc_array[i].procA != func) continue;''',
        '    if (index >= winproc_used) return NULL;': '''    if (index >= winproc_used) return NULL;
    if (index >= NTUSER_NB_PROCS && __atomic_load_n(&winproc_owners[index], __ATOMIC_ACQUIRE) != NtCurrentTeb()->Peb) return NULL;''',
        '    int i, n = ios_client_procs_count;':
            '    int i, n = __atomic_load_n(&ios_client_procs_count, __ATOMIC_ACQUIRE);',
        '        if (ios_client_procs_reg[i].peb == peb) return &ios_client_procs_reg[i];':
            '        if (__atomic_load_n(&ios_client_procs_reg[i].peb, __ATOMIC_ACQUIRE) == peb) return &ios_client_procs_reg[i];',
        '            entry->peb = peb;': '            __atomic_store_n(&entry->peb, peb, __ATOMIC_RELEASE);',
        '''static inline WINDOWPROC *alloc_winproc_ptr( WNDPROC func, BOOL ansi )
{
    WINDOWPROC *proc;''': '''static inline WINDOWPROC *alloc_winproc_ptr( WNDPROC func, BOOL ansi )
{
    WINDOWPROC *proc;
    UINT slot;''',
        '        if (winproc_used < MAX_WINPROCS)': '''        for (slot = NTUSER_NB_PROCS; slot < winproc_used; slot++)
            if (!winproc_owners[slot]) break;
        if (slot < MAX_WINPROCS)''',
        '            proc = &winproc_array[winproc_used++];': '''            proc = &winproc_array[slot];
            __atomic_store_n(&winproc_owners[slot], NtCurrentTeb()->Peb, __ATOMIC_RELEASE);
            if (slot == winproc_used) winproc_used++;''',
        '    if (!entry && n < IOS_MAX_CLIENT_PROCS) entry = &ios_client_procs_reg[n];': '''    if (!entry)
        for (slot = 0; slot < n; slot++)
            if (!ios_client_procs_reg[slot].peb) { entry = &ios_client_procs_reg[slot]; break; }
    if (!entry && n < IOS_MAX_CLIENT_PROCS) entry = &ios_client_procs_reg[n];''',
        '            ios_client_procs_count = n + 1;':
            '            if (entry == &ios_client_procs_reg[n]) __atomic_store_n(&ios_client_procs_count, n + 1, __ATOMIC_RELEASE);',
    }
    for old, new in changes.items():
        if text.count(old) != 1: raise ValueError('Madeira window procedure lifecycle changed')
        text = text.replace(old, new)
    return text


def apply(text, source, header):
    calls = {
        'process_ios.c': 'pthread_create( &child_thread, NULL, ios_child_thread_entry, args )',
        'thread_ios.c': 'pthread_create( &pthread_id, &pthread_attr, (void * (*)(void *))start_thread, teb )',
    }
    call = calls[source]
    if text.count(call) != 1:
        raise ValueError('Madeira guest thread creation changed: ' + source)
    text = text.replace(call, 'ir_windows_' + call)
    if source == 'process_ios.c':
        begin = text.index('static void *ios_child_thread_entry( void *arg )')
        end = text.index('\n#endif', begin)
        entry = text[begin:end]
        old = '''    ios_child_slot_release( args->slot );
    free( args->argv );
    free( args );'''
        if entry.count(old) != 1 or entry.count('    return NULL;') != 1:
            raise ValueError('Madeira child cleanup changed')
        entry = entry.replace(old, '')
        entry = entry.replace('    struct ios_child_args *args = arg;',
            '    struct ios_child_args *args = arg;\n    pthread_cleanup_push( ios_child_args_release, args );')
        entry = entry.replace('    return NULL;', '    pthread_cleanup_pop( 1 );\n    return NULL;')
        cleanup = '''static void ios_child_args_release( void *arg )
{
    struct ios_child_args *args = arg;
    extern void ios_child_boot_unlock( void );
    ios_child_boot_unlock();
    ios_child_slot_release( args->slot );
    free( args->argv );
    free( args );
}

'''
        text = text[:begin] + cleanup + entry + text[end:]
    if source == 'thread_ios.c':
        changes = {
            '''void abort_thread( int status )
{''': '''void abort_thread( int status )
{
    if (!NtCurrentTeb()) pthread_exit_wrapper( status );''',
            'static LONG nb_threads = 1;': '''extern LONG *ios_process_thread_count_ptr(void);
extern TEB **ios_process_previous_teb_ptr(void);
#define nb_threads (*ios_process_thread_count_ptr())

BOOL ios_end_process_thread(void)
{
    static _Thread_local BOOL ended, last;
    if (!ended)
    {
        ended = TRUE;
        last = InterlockedDecrement( &nb_threads ) <= 0;
    }
    return last;
}''',
            'if (InterlockedDecrement( &nb_threads ) <= 0) abort_process( status );':
                'if (ios_end_process_thread()) abort_process( status );',
            'if (InterlockedDecrement( &nb_threads ) <= 0) exit_process( status );':
                'if (ios_end_process_thread()) exit_process( status );',
            '    static void *prev_teb;\n': '',
            'InterlockedExchangePointer( &prev_teb, NtCurrentTeb() )':
                'InterlockedExchangePointer( ios_process_previous_teb_ptr(), NtCurrentTeb() )',
        }
        for old, new in changes.items():
            if text.count(old) != 1: raise ValueError('Madeira process thread accounting changed')
            text = text.replace(old, new)
    return '#include "' + Path(header).as_posix() + '"\n' + text


def apply_process_server(text):
    changes = {
        '        ios_jit_reclaim_process( dead_peb );': '''        { extern void ios_client_procs_release(void *); ios_client_procs_release(dead_peb); }
        ios_jit_reclaim_process( dead_peb );''',
        '    BOOL exiting;   /* per-process process_exiting flag */': '''    BOOL exiting;   /* per-process process_exiting flag */
    LONG threads;
    TEB *previous_teb;''',
        '/* Master socket for the CURRENT thread\'s pseudo-process (parent = global). */': '''/* Thread counts and deferred TEB disposal belong to one pseudo-process. */
LONG *ios_process_thread_count_ptr(void)
{
    static LONG parent_threads = 1;
    int i = ios_proc_socket_index();
    return i >= 0 ? &ios_proc_sockets[i].threads : &parent_threads;
}
TEB **ios_process_previous_teb_ptr(void)
{
    static TEB *parent_previous_teb;
    int i = ios_proc_socket_index();
    return i >= 0 ? &ios_proc_sockets[i].previous_teb : &parent_previous_teb;
}

/* Master socket for the CURRENT thread's pseudo-process (parent = global). */''',
        '    int idx = __sync_fetch_and_add(&ios_proc_socket_count, 1);': '''    int idx;
    /* Child startup is serialized by ios_child_boot_lock. Reuse completed slots. */
    for (idx = 0; idx < ios_proc_socket_count; idx++)
        if (!ios_proc_sockets[idx].peb) break;''',
        '    ios_fdt_reg( fd, FDT_MASTER, peb_id );': '''    if (idx == ios_proc_socket_count) ios_proc_socket_count++;
    ios_proc_sockets[idx].threads = 1;
    ios_proc_sockets[idx].previous_teb = NULL;
    ios_fdt_reg( fd, FDT_MASTER, peb_id );''',
        '        ios_wow_window_release( dead_peb );': '''        ios_wow_window_release( dead_peb );
        { extern void ios_proc_ident_release(void *); ios_proc_ident_release(dead_peb); }''',
        '    if (n < IOS_MAX_FD_CACHES)\n': '''    for (i = 0; i < n && i < IOS_MAX_FD_CACHES; i++)
        if (!ios_fd_caches[i].in_use) break;
    if (i < IOS_MAX_FD_CACHES)
''',
        '            ios_fd_caches[n].cache = c;': '            ios_fd_caches[i].cache = c;',
        '            ios_fd_caches[n].peb   = cur;': '            ios_fd_caches[i].peb   = cur;',
        '            ios_fd_caches[n].in_use = 1;': '            ios_fd_caches[i].in_use = 1;',
        '            __sync_fetch_and_add( &ios_fd_cache_count, 1 );':
            '            if (i == n) __sync_fetch_and_add( &ios_fd_cache_count, 1 );',
        'slot=%d peb=%p\\n", n, cur );': 'slot=%d peb=%p\\n", i, cur );',
        '''void process_exit_wrapper( int status )
{
#ifdef WINE_IOS''': '''void process_exit_wrapper( int status )
{
#ifdef WINE_IOS
    extern BOOL ios_end_process_thread(void);
    /* Keep process mappings and its master socket until the last guest thread exits. */
    if (!ios_end_process_thread()) abort_thread( status );
    if (ios_peb_is_dead( ios_jit_current_peb() )) exit( status );''',
    }
    for old, new in changes.items():
        if text.count(old) != 1: raise ValueError('Madeira process teardown changed')
        text = text.replace(old, new)
    return text


def apply_server(text):
    begin = text.index('int send_thread_signal( struct thread *thread, int sig )')
    end = text.index('\n#ifdef WINE_IOS', begin)
    old = '    mach_port_t process_port = get_process_port( thread->process );\n'
    function = text[begin:end]
    if function.count(old) != 1:
        raise ValueError('Madeira thread signal delivery changed')
    new = old + '''#ifdef WINE_IOS
    /* Pseudo-process threads share this task; stop must not require a debugger port. */
    if (!process_port && sig == SIGQUIT && thread->unix_pid == getpid())
        process_port = mach_task_self();
#endif
'''
    return text[:begin] + function.replace(old, new) + text[end:]
