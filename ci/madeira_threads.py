# SPDX-License-Identifier: AGPL-3.0-only
"""Track guest pthread creation without changing Wine's join/detach ownership."""
from pathlib import Path
import re


def apply_signal(text, header):
    marker = '#define IOS_MAX_WINE_THREADS 512'
    if text.count(marker) != 1: raise ValueError('Madeira thread registry capacity changed')
    text = text.replace(marker, '#define IOS_MAX_WINE_THREADS IR_WINDOWS_THREAD_SLOTS')
    marker = 'static volatile int32_t ios_thread_count = 0;'
    if text.count(marker) != 1: raise ValueError('Madeira thread registry state changed')
    text = text.replace(marker, marker + '\nstatic pthread_mutex_t ir_registry_lock = PTHREAD_MUTEX_INITIALIZER;')
    for field, atomic in [('thread_t mach_thread;', '_Atomic(thread_t) mach_thread;'),
                          ('uintptr_t teb;', '_Atomic(uintptr_t) teb;'),
                          ('void *trampoline;', '_Atomic(void *) trampoline;')]:
        start = text.index('struct ios_thread_entry {')
        end = text.index('\n};', start)
        entry = text[start:end]
        if entry.count(field) != 1: raise ValueError('Madeira thread registry layout changed')
        text = text[:start] + entry.replace(field, atomic) + text[end:]
    start = text.index('    /* Fallback: use first registered thread */')
    end = text.index('    *teb_out = 0;', start)
    text = text[:start] + text[end:]
    start = text.index('    /* Register this thread in the registry.')
    end = text.index('    /* Set exception port for this thread', start)
    text = text[:start] + '''    int idx = ios_my_slot;
    if (idx < 0 || idx >= IOS_MAX_WINE_THREADS) abort_thread( STATUS_NO_MEMORY );
    pthread_mutex_lock( &ir_registry_lock );
    if (mach_port_mod_refs( mach_task_self(), pe_thread, MACH_PORT_RIGHT_SEND, 1 ) != KERN_SUCCESS)
    {
        pthread_mutex_unlock( &ir_registry_lock );
        abort_thread( STATUS_NO_MEMORY );
    }
    thread_t previous = __c11_atomic_exchange( &ios_thread_registry[idx].mach_thread, 0, __ATOMIC_ACQ_REL );
    ios_thread_registry[idx].teb = teb;
    ios_thread_registry[idx].trampoline = trampoline;
    ios_thread_registry[idx].mach_thread = pe_thread;
    int count = __sync_fetch_and_add( &ios_thread_count, 0 );
    while (count <= idx && !__sync_bool_compare_and_swap( &ios_thread_count, count, idx + 1 ))
        count = __sync_fetch_and_add( &ios_thread_count, 0 );
    if (previous) mach_port_deallocate( mach_task_self(), previous );
    pthread_mutex_unlock( &ir_registry_lock );

''' + text[end:]
    start = text.index('int ios_thread_registry_purge_range(')
    end = text.index('\n/* Is a thread whose TEB', start)
    function = text[start:end]
    function = function.replace('    for (i = 0;', '    pthread_mutex_lock( &ir_registry_lock );\n    for (i = 0;', 1)
    function = function.replace('        ios_thread_registry[i].mach_thread = 0;',
        '        thread_t previous = __c11_atomic_exchange( &ios_thread_registry[i].mach_thread, 0, __ATOMIC_ACQ_REL );')
    function = function.replace('        purged++;', '        if (previous) mach_port_deallocate( mach_task_self(), previous );\n        purged++;')
    function = function.replace('    return purged;', '    pthread_mutex_unlock( &ir_registry_lock );\n    return purged;')
    text = text[:start] + function + text[end:]
    marker = '        ios_my_slot = ios_jit_alloc_trampoline_slot();'
    if text.count(marker) != 1: raise ValueError('Madeira thread trampoline admission changed')
    text = text.replace(marker, marker + '\n        if (ios_my_slot < 0) abort_thread( STATUS_NO_MEMORY );')
    return '#include "' + Path(header).as_posix() + '"\n' + text


def apply_vertex_outputs(text):
    start = text.index('void handle_signature_vs(')
    end = text.index('void handle_signature_ps(', start)
    vertex = text[start:end]
    old = '''      uint32_t assigned_index = func_signature.DefineOutput(OutputVertex{
        .user = sig.fullSemanticString(),
        .type = to_msl_type(sig.componentType()),
      });
      signature_handlers.push_back([=](SignatureContext &ctx) {
        if (ctx.skip_vertex_output)
          return;
        ctx.epilogue >> pop_output_reg(reg, mask, assigned_index);
      });'''
    if vertex.count(old) != 1: raise ValueError('Madeira vertex output signature changed')
    helper = '''static std::function<IRValue(pvalue)> ir_pop_vertex_output(uint32_t reg, uint32_t mask, uint32_t element) {
  return [=](pvalue ret) {
    return make_irvalue_bind([=](context ctx) -> IRValue {
      auto filled = co_yield pop_output_reg_fill(reg, mask, element)(ret);
      auto value = ctx.builder.CreateExtractValue(filled, {element});
      if (value->getType() == ctx.types._float4) {
        auto finite = ctx.builder.CreateICmpNE(
          ctx.builder.CreateAnd(ctx.builder.CreateBitCast(value, ctx.types._int4), 0x7f800000ull),
          ctx.air.getInt4(0x7f800000, 0x7f800000, 0x7f800000, 0x7f800000));
        value = ctx.builder.CreateSelect(finite, value, llvm::ConstantAggregateZero::get(value->getType()));
      }
      co_return ctx.builder.CreateInsertValue(filled, value, {element});
    });
  };
}

'''
    # Metal interpolation is undefined for NaN/Inf, including unused D3D output lanes.
    return text[:start] + helper + vertex.replace(old, old.replace('pop_output_reg(', 'ir_pop_vertex_output(')) + text[end:]


def apply_metal(text, header):
    fields = {name: 'ret' for name in (
        'MTLCopyAllDevices', 'MTLDevice_newCommandQueue', 'MTLDevice_newSharedEvent',
        'MTLDevice_newBuffer', 'MTLDevice_newSamplerState', 'MTLDevice_newDepthStencilState',
        'MTLDevice_newTexture', 'MTLBuffer_newTexture', 'MTLTexture_newTextureView',
        'MTLLibrary_newFunction', 'MTLDevice_newTemporalScaler', 'MTLDevice_newSpatialScaler',
        'NSString_alloc_init', 'MTLLibrary_newFunctionWithConstants', 'MTLDevice_newFence',
        'MTLDevice_newEvent', 'MTLDevice_newBinaryArchive', 'DispatchData_alloc_init',
        'MTLDevice_newSharedTexture', 'MTLDevice_newResidencySet', 'MTLDevice_newPlacementHeap',
        'MTLHeap_newTextureAtOffset', 'MTLHeap_newBufferAtOffset')}
    fields.update(MTLDevice_newLibrary='ret_library', MTLDevice_newSharedEventWithMachPort='ret_event',
                  MTLDevice_newBinaryArchive='ret_archive')
    fields.update({name: 'ret_pso' for name in (
        'MTLDevice_newComputePipelineState', 'MTLDevice_newRenderPipelineState',
        'MTLDevice_newRenderPipelineStateVD', 'MTLDevice_newMeshRenderPipelineState',
        'MTLDevice_newGeometryEmulationPipelineState')})
    observed = set(re.findall(r'static NTSTATUS\n_([\w]+)\(void \*obj\) \{', text))
    owned = {name for name in observed if '_new' in name and not name.endswith('32')}
    if owned != {name for name in fields if '_new' in name}:
        raise ValueError('Madeira Metal owned-object API changed')
    marker = '#include "wmt_remote_client.h"'
    if text.count(marker) != 1: raise ValueError('Madeira Metal dispatch changed')
    text = text.replace(marker, marker + '\n#include "' + str(header) + '"')
    for marker, replacement in (
        ('  [*obj retain];', '  [*obj retain];\n  ir_metal_acquire(*obj);'),
        ('  [*obj release];', '  ir_metal_release(*obj);\n  [*obj release];'),
    ):
        if text.count(marker) != 1: raise ValueError('Madeira Metal reference handling changed')
        text = text.replace(marker, replacement)
    marker = '  [(id<MTLCommandBuffer>)params->handle commit];'
    if text.count(marker) != 1: raise ValueError('Madeira Metal submission changed')
    text = text.replace(marker, '  ir_metal_submit((id<MTLCommandBuffer>)params->handle);\n' + marker)
    for name, field in fields.items():
        marker = 'static NTSTATUS\n_' + name + '(void *obj) {'
        if text.count(marker) != 1: raise ValueError('Madeira Metal creation changed: ' + name)
        start = text.index(marker)
        end = text.index('\n}', start) + 2
        function = text[start:end]
        match = re.search(r'  struct (\w+) \*params = obj;', function)
        if not match: raise ValueError('Madeira Metal parameter layout changed: ' + name)
        function = function.replace('_' + name + '(void *obj)', '_ir_original_' + name + '(void *obj)', 1)
        function += '\n\n' + marker + '\n  struct ' + match[1] + ' *params = obj;\n'
        function += '  NTSTATUS status = _ir_original_' + name + '(obj);\n'
        function += '  if (status == STATUS_SUCCESS && !RM_IS_REMOTE(params->' + field + '))\n'
        function += '    ir_metal_acquire((id)params->' + field + ');\n'
        function += '  return status;\n}'
        text = text[:start] + function + text[end:]
    start_marker = 'typedef struct {\n  _Atomic(CFRunLoopRef) runloop_ref;'
    end_marker = '\n#else\nstatic NTSTATUS\n_MTLSharedEvent_setWin32EventAtValue(void *obj)'
    if text.count(start_marker) != 1 or text.count(end_marker) != 1:
        raise ValueError('Madeira shared-event listener API changed')
    start = text.index(start_marker)
    end = text.index(end_marker, start)
    methods = set(re.findall(r'static NTSTATUS\n(_\w+)\(void \*obj\)', text[start:end]))
    if methods != {'_MTLSharedEvent_setWin32EventAtValue', '_SharedEventListener_start',
                   '_SharedEventListener_create', '_SharedEventListener_destroy'}:
        raise ValueError('Madeira shared-event listener API changed')
    text = text[:start] + '#include "' + str(header.with_name('IRWindowsMetalEvents.h')) + '"\n' + text[end:]
    return text


def verify_futex_layout(native, pe):
    for source, marker in (
        (native, 'struct ios_shared_futex_queue\n{\n    void *next, *prev;\n    LONG lock;\n};'),
        (native, 'static struct ios_shared_futex_queue ios_shared_futex_queues[256];'),
        (pe, 'struct futex_entry\n{\n    struct list entry;\n    const void *addr;\n    DWORD tid;\n};'),
        (pe, 'struct futex_queue\n{\n    struct list queue;\n    LONG lock;\n};'),
    ):
        if source.count(marker) != 1: raise ValueError('Madeira shared wait queue layout changed')


def apply_image_pool(text, header):
    marker = 'static size_t ios_pool_alloc_range_ex( size_t alloc_size, size_t pool_limit,\n                                       size_t anchor_off, size_t max_dist )'
    if text.count(marker) != 1: raise ValueError('Madeira pool allocator changed')
    native = '''
static bool ir_windows_image_accessible(size_t offset, size_t size, bool writable)
{
    mach_vm_address_t at = (uintptr_t)ios_jit_rx_base_global + offset, end = at + size;
    while (at < end)
    {
        mach_vm_address_t region = at;
        mach_vm_size_t length = 0;
        vm_region_basic_info_data_64_t info;
        mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t object = MACH_PORT_NULL;
        kern_return_t result = mach_vm_region(mach_task_self(), &region, &length, VM_REGION_BASIC_INFO_64,
                                               (vm_region_info_t)&info, &count, &object);
        if (object) mach_port_deallocate(mach_task_self(), object);
        if (result != KERN_SUCCESS || region > at || !length || region > UINT64_MAX - length || region + length <= at) return false;
        if (!(info.protection & VM_PROT_READ)) return false;
        if (writable)
        {
            if (!(info.protection & VM_PROT_WRITE) || (info.max_protection & VM_PROT_EXECUTE)) return false;
        }
        else if (!(info.protection & VM_PROT_EXECUTE) || !(info.max_protection & VM_PROT_EXECUTE)) return false;
        at = region + length;
    }
    return true;
}

static bool ir_windows_image_live(size_t offset, size_t size)
{
    size_t live_offset;
    void *owner;
    return ios_pool_live_overlap((uintptr_t)ios_jit_rw_base_global + offset, size, &live_offset, &owner);
}

'''
    text = text.replace(marker, '#include "' + str(header) + '"\n' + native + marker[:-2]
                        + ', const struct ir_windows_image_request *image_request )')
    old = '    size_t off = ios_pool_alloc_range_ex( alloc_size, pool_limit, (size_t)-1, 0 );'
    if text.count(old) != 1: raise ValueError('Madeira pool range entry changed')
    text = text.replace(old, old.replace('0 );', '0, NULL );'))
    old = '    size_t off = ios_pool_alloc_range_ex( alloc_size, 0, (size_t)-1, 0 );'
    if text.count(old) != 1: raise ValueError('Madeira pool tail entry changed')
    text = text.replace(old, old.replace('0 );', '0, NULL );'))
    start = text.index('static size_t ios_pool_alloc_range_ex(')
    end = text.index('\n/* ml239:', start)
    allocator = text[start:end]
    old = '    pthread_mutex_lock( &ios_pool_lock );\n\n    /* ml1052:'
    if allocator.count(old) != 1: raise ValueError('Madeira pool allocation lock changed')
    allocator = allocator.replace(old, '    pthread_mutex_lock( &ios_pool_lock );' + '''
    if (image_request)
    {
        off = ir_windows_image_take(image_request, pool_limit, &alloc_size, ir_windows_session_epoch(),
                                    ir_windows_image_accessible, ir_windows_image_live);
        if (off != (size_t)-1)
        {
            ios_pool_last_alloc_reused = 1;
            dprintf(2, "[session-reclaim] reused whole image allocation off=0x%lx size=0x%lx\\n",
                    (unsigned long)off, (unsigned long)alloc_size);
            goto record_allocation;
        }
    }
\n    /* ml1052:''')
    old = '\n    if (off != (size_t)-1)\n    {\n        /* Steam S3 run 9/10:'
    if allocator.count(old) != 1: raise ValueError('Madeira pool ownership registration changed')
    allocator = allocator.replace(old, '\nrecord_allocation:' + old)
    old = '            ios_pool_ledger_count++;'
    if allocator.count(old) != 1: raise ValueError('Madeira pool ledger registration changed')
    allocator = allocator.replace(old, old + '''
            if (image_request) ir_windows_image_note(off, alloc_size, ios_jit_current_peb(), ir_windows_session_epoch());''')
    text = text[:start] + allocator + text[end:]
    marker = '/* Default-off overflow for small image copies.'
    if text.count(marker) != 1: raise ValueError('Madeira image allocation entry changed')
    text = text.replace(marker, '''static size_t ios_pool_alloc_image(const void *base, size_t image_size, size_t alloc_size,
                                   size_t limit, size_t delta, size_t trampolines)
{
    const struct ir_windows_image_request request = {base, image_size, delta, trampolines};
    return ios_pool_alloc_range_ex(alloc_size, limit, (size_t)-1, 0, &request);
}

''' + marker)
    start = text.index('            /* ios_image_reload_mode:')
    end = text.index('            /* Copy ENTIRE PE image', start)
    image = text[start:end]
    old = 'ios_pool_alloc_range(alloc_size, jit_pool_size - ios_jit_tail_reserved)'
    if image.count(old) != 2: raise ValueError('Madeira image allocation calls changed')
    image = image.replace(old, 'ios_pool_alloc_image(image_base, image_size, alloc_size, jit_pool_size - ios_jit_tail_reserved, data_delta, tramp_prealloc)')
    text = text[:start] + image + text[end:]
    marker = '        /* madeira-bcd: a range in the big-image slot frees the slot'
    if text.count(marker) != 1: raise ValueError('Madeira image pool retirement changed')
    text = text.replace(marker, '''        /* Data protection removes execute access permanently. Keep image layouts whole for the next job. */
        if (!(ios_pool_big_size && off < ios_pool_big_off + ios_pool_big_size && off + size > ios_pool_big_off) &&
            ir_windows_image_retire(off, size, peb))
        {
            total += size;
            ranges++;
            ios_pool_ledger[i] = ios_pool_ledger[--ios_pool_ledger_count];
            continue;
        }
''' + marker)
    return text


def apply_virtual(text, pool_header=None):
    marker = 'static volatile int32_t ios_jit_next_slot = 0;  /* Next slot to allocate */'
    if text.count(marker) != 1: raise ValueError('Madeira trampoline slot state changed')
    text = text.replace(marker, 'extern int ir_windows_thread_slot(void);')
    old = '''    int slot = __sync_fetch_and_add(&ios_jit_next_slot, 1);
    if (slot >= IOS_JIT_MAX_SLOTS) return 0;  /* fallback to slot 0 */'''
    if text.count(old) != 1: raise ValueError('Madeira trampoline allocation changed')
    text = text.replace(old, '    int slot = ir_windows_thread_slot();\n    if (slot < 0 || slot >= IOS_JIT_MAX_SLOTS) return -1;')
    text = text.replace('Keep lifetime-monotonic allocation; never recycle a slot\n * whose trampoline may still be referenced.',
                        'Reuse a slot only after its kernel thread has ended,\n * including its TLS destructors.')
    old = 'static struct { uint64_t base; uint64_t size; unsigned tid; unsigned freed; unsigned inuse; } ios_steer[IOS_STEER_MAX];'
    if text.count(old) != 1: raise ValueError('Madeira reservation tracking changed')
    text = text.replace(old, 'static struct { _Atomic uint64_t base, size, owner, epoch; _Atomic unsigned tid, freed, inuse, retired; } ios_steer[IOS_STEER_MAX];')
    text = text.replace('static unsigned ios_steer_n;', 'static _Atomic unsigned ios_steer_n;')
    marker = '    unsigned int  ios_flags;     /* IOS_VIEW_* */'
    if text.count(marker) != 1: raise ValueError('Madeira virtual view ownership changed')
    text = text.replace(marker, marker + '\n    void *ios_owner;\n    uint64_t ios_epoch;\n    unsigned int ios_retired;')
    marker = '    view->ios_flags = 0;'
    if text.count(marker) != 1: raise ValueError('Madeira virtual view creation changed')
    text = text.replace(marker, marker + '\n    ios_view_created( view );')
    marker = '        new_view->ios_flags = view->ios_flags;'
    if text.count(marker) != 1: raise ValueError('Madeira virtual view splitting changed')
    text = text.replace(marker, marker + '\n        new_view->ios_owner = view->ios_owner;\n        new_view->ios_epoch = view->ios_epoch;\n        new_view->ios_retired = view->ios_retired;')
    marker = '            *p_teb_block = ptr;'
    if text.count(marker) != 1: raise ValueError('Madeira shared TEB cache changed')
    text = text.replace(marker, '''            if (!wow)
            {
                /* The native TEB free list is shared by every pseudo-process. */
                struct file_view *view = find_view( ptr, total );
                if (view)
                {
                    view->ios_owner = NULL;
                    view->ios_epoch = 0;
                    view->ios_retired = 0;
                }
            }
''' + marker)
    start = text.index('static uint64_t ios_steer_reclaim_dead( void )\n{')
    end = text.index('/* ml255: STORM GATE.', start)
    text = text[:start] + '''static uint64_t ios_steer_reclaim_dead( void );
static void ios_views_owner_died( void *peb );
static _Atomic uint64_t ios_cleanup_epoch;
extern void ir_windows_metal_owner_died(void *);
extern bool ir_windows_metal_reclaim(uint64_t);

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
        ios_steer[i].owner = (uintptr_t)ios_jit_current_peb();
        ios_steer[i].epoch = ir_windows_session_epoch();
        ios_steer[i].retired = 0;
        ios_thread_alive( tid );
        if (i == ios_steer_n) ios_steer_n++;
    }
    server_leave_uninterrupted_section( &virtual_mutex, &sigset );
}

static void ios_steer_owner_died( void *peb )
{
    sigset_t sigset;
    unsigned i;
    if (!peb) return;
    server_enter_uninterrupted_section( &virtual_mutex, &sigset );
    for (i = 0; i < ios_steer_n; i++)
        if (!ios_steer[i].freed && ios_steer[i].owner == (uintptr_t)peb) ios_steer[i].retired = 1;
    ios_views_owner_died( peb );
    ir_windows_metal_owner_died( peb );
    server_leave_uninterrupted_section( &virtual_mutex, &sigset );
}

''' + text[end:]
    marker = '    ios_sc_grants_owner_died( peb );'
    if text.count(marker) != 1: raise ValueError('Madeira process reservation cleanup changed')
    text = text.replace(marker, marker + '\n    ios_steer_owner_died( peb );')
    marker = "    ios_vh_note( 'd', view );   /* madeira-bcd: view history */"
    if text.count(marker) != 1: raise ValueError('Madeira virtual view deletion changed')
    text = text.replace(marker, '    ios_steer_forget( view->base, view->size );\n' + marker)
    marker = '\n\n/***********************************************************************\n *           register_view'
    if text.count(marker) != 1: raise ValueError('Madeira virtual view registration changed')
    text = text.replace(marker, '''

static void ios_view_created( struct file_view *view )
{
    view->ios_owner = ios_jit_current_peb();
    view->ios_epoch = ir_windows_session_epoch();
    view->ios_retired = 0;
}

static void ios_views_owner_died( void *peb )
{
    struct file_view *view;
    WINE_RB_FOR_EACH_ENTRY( view, &views_tree, struct file_view, entry )
        if (view->ios_owner == peb) view->ios_retired = 1;
}

static int ios_view_reclaimable( const struct file_view *view, uint64_t epoch )
{
    size_t offset;
    if (!view->ios_owner || !view->ios_retired || !view->ios_epoch || view->ios_epoch >= epoch || view->ios_flags)
        return 0;
    /* Original PE mappings are separate from the reusable executable pool copies. */
    if (view->protect & SEC_IMAGE)
        return !(view->protect & ~(SEC_IMAGE | SEC_FILE | VPROT_READ | VPROT_WRITE | VPROT_WRITECOPY |
                                  VPROT_EXEC | VPROT_COMMITTED | VPROT_ARM64EC));
    if (view->protect & ~(VPROT_READ | VPROT_WRITE | VPROT_COMMITTED | VPROT_WRITEWATCH)) return 0;
    for (offset = 0; offset < view->size; offset += page_size)
        if (get_page_vprot( (char *)view->base + offset ) & VPROT_EXEC) return 0;
    return 1;
}

/* The old process is dead and the next epoch proves all its kernel threads ended. */
static uint64_t ios_views_reclaim( uint64_t epoch )
{
    struct file_view *view, *batch[256];
    uint64_t freed = 0;
    unsigned n, i;
    do
    {
        n = 0;
        WINE_RB_FOR_EACH_ENTRY( view, &views_tree, struct file_view, entry )
            if (ios_view_reclaimable( view, epoch ))
            {
                batch[n++] = view;
                if (n == ARRAY_SIZE(batch)) break;
            }
        for (i = 0; i < n; i++)
        {
            freed += batch[i]->size;
            ios_bigres_release( batch[i]->base );
            delete_view( batch[i] );
        }
    } while (n == ARRAY_SIZE(batch));
    return freed;
}

struct ios_session_futex_queue { struct list queue; LONG lock; };
struct ios_session_futex_entry { struct list entry; const void *addr; DWORD tid; };
extern void *ios_get_shared_futex_queues(void);

/* WaitOnAddress links stack entries into a host-wide list, even after abrupt thread exit. */
static int ios_views_forget_waiters( uint64_t epoch )
{
    struct ios_session_futex_queue *queues = ios_get_shared_futex_queues();
    unsigned i;
    for (i = 0; i < 256; i++)
    {
        struct ios_session_futex_entry *entry, *next;
        if (InterlockedCompareExchange( &queues[i].lock, -1, 0 )) return 0;
        if (queues[i].queue.next)
            LIST_FOR_EACH_ENTRY_SAFE( entry, next, &queues[i].queue, struct ios_session_futex_entry, entry )
            {
                struct file_view *view = find_view( entry, sizeof(*entry) );
                if (view && ios_view_reclaimable( view, epoch ))
                {
                    list_remove( &entry->entry );
                    entry->addr = NULL;
                }
            }
        InterlockedExchange( &queues[i].lock, 0 );
    }
    return 1;
}

/* A later epoch proves the old job's kernel threads and TLS destructors ended. */
static uint64_t ios_steer_reclaim_dead( void )
{
    uint64_t freed = 0;
    uint64_t epoch = ios_cleanup_epoch;
    unsigned i;
    sigset_t sigset;
    server_enter_uninterrupted_section( &virtual_mutex, &sigset );
    if (!ios_views_forget_waiters( epoch ))
    {
        server_leave_uninterrupted_section( &virtual_mutex, &sigset );
        return 0;
    }
    for (i = 0; i < ios_steer_n; i++)
    {
        struct file_view *view;
        if (ios_steer[i].freed || !ios_steer[i].base || !ios_steer[i].owner || !ios_steer[i].retired ||
            !ios_steer[i].epoch || ios_steer[i].epoch >= epoch) continue;
        view = find_view( (void *)(uintptr_t)ios_steer[i].base, 0 );
        if (!view || (uintptr_t)view->base != ios_steer[i].base || view->size != ios_steer[i].size ||
            !ios_view_reclaimable( view, epoch )) continue;
        freed += view->size;
        ios_bigres_release( view->base );
        delete_view( view );
    }
    uint64_t private_freed = ios_views_reclaim( epoch );
    server_leave_uninterrupted_section( &virtual_mutex, &sigset );
    if (freed) dprintf( 2, "[steer-reclaim] released %lluMB from completed jobs\\n",
                        (unsigned long long)(freed >> 20) );
    if (private_freed) dprintf( 2, "[session-reclaim] released %lluMB of private data from completed jobs\\n",
                                (unsigned long long)(private_freed >> 20) );
    return freed + private_freed;
}

void ir_windows_reclaim_completed( void )
{
    uint64_t epoch = ir_windows_session_epoch();
    if (ir_windows_metal_reclaim( epoch ))
    {
        ios_cleanup_epoch = epoch;
        ios_steer_reclaim_dead();
    }
}
''' + marker)
    start = text.index('                if (!sst && ios_steer_n < IOS_STEER_MAX)')
    end = text.index('                /* ml210:', start)
    text = text[:start] + '''                if (!sst) ios_steer_record( *ret, want, stid );
''' + text[end:]
    marker = '                NTSTATUS sst = !steer_top ? STATUS_NO_MEMORY :'
    if text.count(marker) != 1: raise ValueError('Madeira reservation admission changed')
    text = text.replace(marker, '                ios_steer_reclaim_dead();\n' + marker)
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
    text = '#include <stdbool.h>\n#include <stdint.h>\nextern uint64_t ir_windows_session_epoch(void);\n' + text + '''

void ir_windows_keep_view( void *base, size_t size )
{
    sigset_t sigset;
    struct file_view *view;
    server_enter_uninterrupted_section( &virtual_mutex, &sigset );
    if ((view = find_view( base, size )))
    {
        view->ios_owner = NULL;
        view->ios_epoch = 0;
        view->ios_retired = 0;
    }
    server_leave_uninterrupted_section( &virtual_mutex, &sigset );
}
'''
    return apply_image_pool(text, pool_header or Path(__file__).resolve().parents[1] / 'iridium/apps/ios/RuntimeBridge/IRWindowsJITPool.h')


def apply_dc(text):
    marker = '            bucket->next_free = NULL;'
    if text.count(marker) != 1: raise ValueError('Madeira shared DC cache changed')
    return '#include <stddef.h>\nextern void ir_windows_keep_view(void *, size_t);\n' + text.replace(marker, '''            /* Native DC buckets are shared across 64-bit pseudo-processes. */
            if (!cur_wow) ir_windows_keep_view( bucket->entries, size );
''' + marker)


def apply_gdi(text):
    marker = '    next_unused = gdi_shared->Handles + FIRST_GDI_HANDLE;'
    if text.count(marker) != 1: raise ValueError('Madeira shared GDI table changed')
    return '#include <stddef.h>\nextern void ir_windows_keep_view(void *, size_t);\n' + text.replace(marker,
        '    ir_windows_keep_view( gdi_shared, size );\n' + marker)


def apply_fex(text):
    old = '#if defined(FEX_IOS_HOST) && defined(_WIN32) && !defined(ARCHITECTURE_arm64ec)'
    new = '#if defined(FEX_IOS_HOST) && defined(_WIN32)'
    if text.count(old) == 1:
        return text.replace(old, new)
    if old not in text and text.count(new) == 1:
        return text
    raise ValueError('Madeira FEX allocation-watch thread identity changed')


def apply_fex_arm64ec(text):
    marker = '  uint64_t& DispatcherLoopTopEnterEC() const {'
    helper = '''  FEXCore::Core::InternalThreadState* ThreadStateIfPresent() const {
    // Native startup threads can receive callbacks before ARM64EC initialization.
    return Area ? ThreadState() : nullptr;
  }

'''
    if text.count(marker) != 1: raise ValueError('Madeira ARM64EC CPU area changed')
    if helper not in text:
        if text.count('GetCPUArea().ThreadState()') != 13 or text.count('if (!CPUArea.ThreadState())') != 1:
            raise ValueError('Madeira ARM64EC thread-state callbacks changed')
        text = text.replace(marker, helper + marker)
        text = text.replace('GetCPUArea().ThreadState()', 'GetCPUArea().ThreadStateIfPresent()')
        text = text.replace('if (!CPUArea.ThreadState())', 'if (!CPUArea.ThreadStateIfPresent())')
        marker = '  bool Cont {};\n  if (Exception->ExceptionCode == EXCEPTION_ACCESS_VIOLATION) {'
        if text.count(marker) != 1: raise ValueError('Madeira ARM64EC exception callback changed')
        text = text.replace(marker, '  if (!GetCPUArea().Area) return STATUS_SUCCESS;\n' + marker)
    return text


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
            'ios_ii->Machine == IMAGE_FILE_MACHINE_AMD64)':
                '''(ios_ii->Machine == IMAGE_FILE_MACHINE_AMD64 ||
         (ios_ii->Machine == IMAGE_FILE_MACHINE_ARM64 && is_arm64ec())))''',
            "     * desktop need it, aarch64 threads must not get it. */":
                "     * desktop need it. Native ARM64 children also need it when they\n     * inherit the session's ARM64EC ntdll and its dispatch interface. */",
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
