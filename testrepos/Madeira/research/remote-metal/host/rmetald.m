/* Remote Metal host daemon -- runs on macOS, owns the real MTLDevice.
 *
 * The guest never sees a host pointer. Every Objective-C object it can refer
 * to lives in a generation-tagged table here, and the guest holds only an
 * index. See protocol.h for why that matters.
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <Cocoa/Cocoa.h>
#import <QuartzCore/CAMetalLayer.h>
#include <pthread.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <errno.h>
#include <math.h>
#include <stdatomic.h>
#include <objc/runtime.h>
#include "../protocol.h"
#include "wmt_decode.h"
/* The guest sends WMT*Info structs verbatim, so the host must read them with
 * the SAME declarations. Both sides compile this header. */
#define WINEMETAL_API
#include "../../dxmt/src/winemetal/winemetal.h"

/* ---- handle table ------------------------------------------------------ */

typedef struct {
    __unsafe_unretained id obj;   /* retained manually via CFBridgingRetain */
    uint32_t generation;
    int      in_use;
    uint32_t refs;                /* guest-visible references to this identity */
} rm_slot;

/* Per-class creation census. "No errors logged" is not evidence that objects
 * were created -- a call can return nil with no error, and the guest tolerates
 * nulls. Counting what actually got interned, by class, turns that into a
 * fact the log states outright. */
#define RM_CLASSES 32
static struct { const char *name; unsigned n; } g_census[RM_CLASSES];
static unsigned g_census_n;

static void rm_census_note(id obj) {
    if (!obj) return;
    const char *cls = object_getClassName(obj);
    for (unsigned i = 0; i < g_census_n; i++)
        if (strcmp(g_census[i].name, cls) == 0) { g_census[i].n++; return; }
    if (g_census_n < RM_CLASSES) { g_census[g_census_n].name = cls; g_census[g_census_n].n = 1; g_census_n++; }
}

static void rm_census_report(void) {
    if (!g_census_n) { fprintf(stderr, "[rmetald] census: no objects created\n"); return; }
    fprintf(stderr, "[rmetald] census: objects created this session\n");
    for (unsigned i = 0; i < g_census_n; i++)
        fprintf(stderr, "[rmetald]   %-44s %u\n", g_census[i].name, g_census[i].n);
    memset(g_census, 0, sizeof g_census); g_census_n = 0;
}

static rm_slot  *g_slots;
static uint32_t  g_slot_count;
static uint32_t  g_slot_cap;
static uint32_t  g_live;

static id rm_resolve(uint64_t h, uint32_t *err);   /* defined below */

/* One object == one handle. Interning the same object twice used to mint a
 * second slot, so the guest could hold two identities for one device and any
 * equality test between them would be false. Identity is looked up first and
 * the existing handle returned with its refcount raised. */
static uint32_t rm_find_slot(id obj) {
    for (uint32_t i = 0; i < g_slot_count; i++)
        if (g_slots[i].in_use && g_slots[i].obj == obj) return i;
    return UINT32_MAX;
}

static uint64_t rm_intern(id obj) {
    if (!obj) return RM_NULL_HANDLE;
    uint32_t slot = rm_find_slot(obj);
    if (slot != UINT32_MAX) {
        g_slots[slot].refs++;
        return RM_HANDLE(g_slots[slot].generation, slot);
    }
    slot = UINT32_MAX;
    for (uint32_t i = 0; i < g_slot_count; i++)
        if (!g_slots[i].in_use) { slot = i; break; }
    if (slot == UINT32_MAX) {
        if (g_slot_count == g_slot_cap) {
            g_slot_cap = g_slot_cap ? g_slot_cap * 2 : 256;
            g_slots = realloc(g_slots, g_slot_cap * sizeof(rm_slot));
        }
        slot = g_slot_count++;
        g_slots[slot].generation = 1;
    }
    CFBridgingRetain(obj);              /* +1, balanced when refs reaches 0 */
    rm_census_note(obj);
    g_slots[slot].obj = obj;
    g_slots[slot].in_use = 1;
    g_slots[slot].refs = 1;
    g_live++;
    return RM_HANDLE(g_slots[slot].generation, slot);
}

/* Retain must return the SAME identity. Minting a fresh handle left the guest
 * holding the original while the new one carried the reference, so the next
 * release freed an object the guest still used. */
static uint64_t rm_retain_handle(uint64_t h, uint32_t *err) {
    id obj = rm_resolve(h, err);
    if (*err != RM_OK) return RM_NULL_HANDLE;
    if (!obj) return RM_NULL_HANDLE;
    g_slots[RM_HANDLE_SLOT(h)].refs++;
    return h;
}
/* Returns nil and sets *err when the handle is stale or bogus. Callers must
 * check: silently treating a stale handle as valid is exactly the corruption
 * this table exists to prevent. */
static id rm_resolve(uint64_t h, uint32_t *err) {
    *err = RM_OK;
    if (h == RM_NULL_HANDLE) return nil;
    /* An untagged non-zero value is a LOCAL pointer that reached the wire --
     * a producer that was not switched to remote. Name it: silently treating
     * it as an index would address an arbitrary table slot. */
    if (!RM_IS_REMOTE(h)) {
        fprintf(stderr, "[rmetald] handle %#llx is not tagged remote -- a local "
                "pointer reached the wire from an unswitched producer\n",
                (unsigned long long)h);
        *err = RM_ERR_BAD_HANDLE; return nil;
    }
    uint32_t slot = RM_HANDLE_SLOT(h), gen = RM_HANDLE_GEN(h);
    if (slot >= g_slot_count || !g_slots[slot].in_use) { *err = RM_ERR_BAD_HANDLE; return nil; }
    if (g_slots[slot].generation != gen)                { *err = RM_ERR_STALE_HANDLE; return nil; }
    return g_slots[slot].obj;
}

static uint32_t rm_release_handle(uint64_t h) {
    uint32_t err; id obj = rm_resolve(h, &err);
    if (err != RM_OK) return err;
    if (!obj) return RM_OK;
    uint32_t slot = RM_HANDLE_SLOT(h);
    if (g_slots[slot].refs > 1) { g_slots[slot].refs--; return RM_OK; }
    CFRelease((__bridge CFTypeRef)g_slots[slot].obj);
    g_slots[slot].obj = nil;
    g_slots[slot].in_use = 0;
    g_slots[slot].refs = 0;
    g_slots[slot].generation++;      /* invalidates every outstanding handle */
    g_live--;
    return RM_OK;
}

/* ---- drawable pairing --------------------------------------------------
 *
 * NEXT_DRAWABLE interns TWO handles, and both must die together. Deriving the
 * pairing later -- by trusting the caller's color_texture, or by scanning the
 * table for the texture object -- is wrong on exactly the paths that matter:
 * a malformed stream would release whatever texture the caller named, and a
 * drawable/texture mismatch would release the drawable while stranding its
 * real texture handle. Record the truth at acquisition instead, and route
 * every terminal path through one consume helper. */
#define RM_MAX_DRAWABLES 8
static struct { uint64_t drawable, texture; } g_pairs[RM_MAX_DRAWABLES];

static void rm_pair_record(uint64_t d, uint64_t t) {
    for (int i = 0; i < RM_MAX_DRAWABLES; i++)
        if (!g_pairs[i].drawable) { g_pairs[i].drawable = d; g_pairs[i].texture = t; return; }
    fprintf(stderr, "[rmetald] drawable pair table full -- leaking %llu\n",
            (unsigned long long)d);
}

/* Release a drawable and its texture together. Safe to call on any terminal
 * path, including ones where the drawable was never presented. */
static void rm_consume_drawable(uint64_t d) {
    if (!d) return;
    for (int i = 0; i < RM_MAX_DRAWABLES; i++)
        if (g_pairs[i].drawable == d) {
            rm_release_handle(g_pairs[i].texture);
            g_pairs[i].drawable = g_pairs[i].texture = 0;
            break;
        }
    rm_release_handle(d);
}

/* ---- host window ------------------------------------------------------
 *
 * AppKit owns the main thread; RPC runs on a worker. Every window and layer
 * mutation is bounced to the main queue, because touching either from the
 * socket thread is undefined and fails intermittently rather than loudly.
 */
static NSWindow    *g_window;
static CAMetalLayer *g_layer;
/* Drawable size the guest asked for; 0 until it says. */
static double g_guest_w, g_guest_h;
/* Draw records replayed since the last present. A presented frame with zero
 * draws is a blank frame by definition, which turns "it flickers" into a
 * number instead of a theory. */
static unsigned long g_draws_since_present;
/* Presents, for the title-bar FPS readout. Written by the RPC thread and read
 * by a timer on the main thread, so it is atomic. */
static _Atomic unsigned long long g_present_count;

static void host_window_build(id<MTLDevice> dev) {
        NSRect r = NSMakeRect(120, 120, 640, 480);
        g_window = [[NSWindow alloc] initWithContentRect:r
            styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                       NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable)
            backing:NSBackingStoreBuffered defer:NO];
        [g_window setTitle:@"Madeira remote Metal"];
        g_layer = [CAMetalLayer layer];
        g_layer.device = dev;
        g_layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        g_layer.framebufferOnly = NO;          /* readback allowed for verification */
        /* Bounded acquisition: a drawable that never arrives must become an
         * ANSWER, not a hung RPC thread. */
        /* Time out rather than block.
         *
         * Blocking here DEADLOCKS the whole guest: this daemon serves a client
         * on one thread, and the client serialises its calls behind one mutex,
         * so an acquire that never returns wedges every winemetal call in that
         * process -- observed as a clean hang with all threads parked and no
         * error anywhere. A timeout costs at worst one blank frame, which is
         * counted below.
         *
         * The flicker this was changed for had a different cause entirely: a
         * per-frame display query returning uninitialised memory. */
        g_layer.allowsNextDrawableTimeout = YES;
        NSView *v = [g_window contentView];
        [v setWantsLayer:YES];
        [v setLayer:g_layer];
        g_layer.frame = v.bounds;
        g_layer.drawableSize = CGSizeMake(v.bounds.size.width, v.bounds.size.height);
        [g_window makeKeyAndOrderFront:nil];
}

/* Safe from either thread: build directly when already on main. */
static void host_window_create(id<MTLDevice> dev) {
    if ([NSThread isMainThread]) host_window_build(dev);
    else dispatch_sync(dispatch_get_main_queue(), ^{ host_window_build(dev); });
}

/* ---- framed IO --------------------------------------------------------- */

static int rd(int fd, void *p, size_t n) {
    uint8_t *b = p;
    while (n) { ssize_t r = read(fd, b, n); if (r <= 0) return -1; b += r; n -= (size_t)r; }
    return 0;
}
static int wr(int fd, const void *p, size_t n) {
    const uint8_t *b = p;
    while (n) { ssize_t r = write(fd, b, n); if (r <= 0) return -1; b += r; n -= (size_t)r; }
    return 0;
}

static int reply(int fd, struct rm_hdr *req, uint32_t status, const void *payload, uint32_t len) {
    struct rm_hdr h = { RM_MAGIC, RM_VERSION, req->opcode, req->seq, status, len, 0 };
    if (wr(fd, &h, sizeof h)) return -1;
    return len ? wr(fd, payload, len) : 0;
}

/* Release every handle this connection interned. Without it the table grows
 * for the lifetime of the daemon and GPU memory is never reclaimed -- a
 * long-lived debugging rig would leak every resource of every past session. */
static void rm_reset_table(void) {
    for (uint32_t i = 0; i < g_slot_count; i++)
        if (g_slots[i].in_use) {
            CFRelease((__bridge CFTypeRef)g_slots[i].obj);
            g_slots[i].obj = nil;
            g_slots[i].in_use = 0;
            g_slots[i].generation++;
        }
    g_live = 0;
    memset(g_pairs, 0, sizeof g_pairs);
}

/* Resource uploads are megabytes, not kilobytes. A fixed 64KB payload buffer
 * silently closed the connection on the first 1MB buffer upload, which the
 * guest saw only as SIGPIPE -- grow on demand instead, with a cap so a bogus
 * length field cannot exhaust host memory. */
#define RM_MAX_PAYLOAD (256u << 20)

/* The guest remaps BC formats it cannot sample. The host GPU supports BC, so
 * the only transform needed here is stripping the swizzle bit -- remapping on
 * this side would undo the point of forwarding to a capable GPU. */
static MTLPixelFormat rm_fmt(enum WMTPixelFormat f) {
    return (MTLPixelFormat)ORIGINAL_FORMAT(f);
}

/* Replay a validated packed batch into an EXISTING encoder.
 *
 * Lifted verbatim from the single-shot submit path so both callers run the same
 * code: the frame path needs Metal state to survive across the twelve batches a
 * frame sends, which a build-and-finish-per-RPC path cannot express. Returns the
 * number of records replayed, or -1 if a record referenced a bad handle. */
static int rm_replay_into(id<MTLRenderCommandEncoder> enc, struct wmtw_view v) {
    uint32_t err = RM_OK;
            uint32_t off = 0, bad = 0, replayed = 0;
            while (off < v.rec_bytes) {
                const struct wmtw_hdr *r = (const void *)(v.rec + off);
                switch (r->op) {
                case WMTW_OP_Nop: break;
                case WMTW_OP_SetPSO: {
                    const struct wmtw_setpso *c = (const void *)r;
                    id o = rm_resolve(c->pso, &err); if (err != RM_OK) { bad = 1; break; }
                    [enc setRenderPipelineState:o]; break;
                }
                case WMTW_OP_SetDSSO: {
                    const struct wmtw_setdsso *c = (const void *)r;
                    id o = rm_resolve(c->dsso, &err); if (err != RM_OK) { bad = 1; break; }
                    [enc setDepthStencilState:o];
                    [enc setStencilReferenceValue:c->stencil_ref]; break;
                }
                case WMTW_OP_SetVertexBuffer: {
                    const struct wmtw_setvertexbuffer *c = (const void *)r;
                    id o = rm_resolve(c->buffer, &err); if (err != RM_OK) { bad = 1; break; }
                    [enc setVertexBuffer:o offset:(NSUInteger)c->offset atIndex:(NSUInteger)c->index];
                    break;
                }
                case WMTW_OP_SetVertexBufferOffset: {
                    const struct wmtw_setvertexbufferoffset *c = (const void *)r;
                    [enc setVertexBufferOffset:(NSUInteger)c->offset atIndex:(NSUInteger)c->index];
                    break;
                }
                case WMTW_OP_SetFragmentBufferOffset: {
                    const struct wmtw_setfragmentbufferoffset *c = (const void *)r;
                    [enc setFragmentBufferOffset:(NSUInteger)c->offset atIndex:(NSUInteger)c->index];
                    break;
                }
                case WMTW_OP_SetFragmentBuffer: {
                    const struct wmtw_setfragmentbuffer *c = (const void *)r;
                    id o = rm_resolve(c->buffer, &err); if (err != RM_OK) { bad = 1; break; }
                    [enc setFragmentBuffer:o offset:(NSUInteger)c->offset atIndex:(NSUInteger)c->index];
                    break;
                }
                case WMTW_OP_SetFragmentTexture: {
                    const struct wmtw_setfragmenttexture *c = (const void *)r;
                    id o = rm_resolve(c->texture, &err); if (err != RM_OK) { bad = 1; break; }
                    [enc setFragmentTexture:o atIndex:(NSUInteger)c->index]; break;
                }
                case WMTW_OP_SetFragmentBytes: {
                    const struct wmtw_setfragmentbytes *c = (const void *)r;
                    [enc setFragmentBytes:v.side + c->bytes_offset
                                   length:c->bytes_count atIndex:(NSUInteger)c->index];
                    break;
                }
                case WMTW_OP_SetViewports: {
                    const struct wmtw_setviewports *c = (const void *)r;
                    /* validator proved the range and 8-byte alignment */
                    [enc setViewports:(const MTLViewport *)(v.side + c->viewports_offset)
                                count:c->viewports_count];
                    break;
                }
                case WMTW_OP_SetScissorRects: {
                    const struct wmtw_setscissorrects *c = (const void *)r;
                    [enc setScissorRects:(const MTLScissorRect *)(v.side + c->scissors_offset)
                                   count:c->scissors_count];
                    break;
                }
                case WMTW_OP_SetRasterizerState: {
                    const struct wmtw_setrasterizerstate *c = (const void *)r;
                    [enc setFrontFacingWinding:(MTLWinding)c->front_facing];
                    [enc setCullMode:(MTLCullMode)c->cull_mode];
                    [enc setTriangleFillMode:(MTLTriangleFillMode)c->fill_mode];
                    [enc setDepthClipMode:(MTLDepthClipMode)c->depth_clip_mode];
                    [enc setDepthBias:c->depth_bias slopeScale:c->slope_scale clamp:c->depth_bias_clamp];
                    break;
                }
                case WMTW_OP_SetBlendFactorAndStencilRef: {
                    const struct wmtw_setblendfactorandstencilref *c = (const void *)r;
                    [enc setBlendColorRed:c->r green:c->g blue:c->b alpha:c->a];
                    [enc setStencilReferenceValue:c->stencil_ref]; break;
                }
                case WMTW_OP_UseResource: {
                    const struct wmtw_useresource *c = (const void *)r;
                    id o = rm_resolve(c->resource, &err); if (err != RM_OK) { bad = 1; break; }
                    [enc useResource:o usage:(MTLResourceUsage)c->usage
                              stages:(MTLRenderStages)c->stages]; break;
                }
                case WMTW_OP_Draw: g_draws_since_present++; {
                    const struct wmtw_draw *c = (const void *)r;
                    [enc drawPrimitives:(MTLPrimitiveType)c->primitive
                            vertexStart:(NSUInteger)c->start vertexCount:(NSUInteger)c->count
                          instanceCount:(NSUInteger)(c->instances ?: 1)
                           baseInstance:(NSUInteger)c->base_instance];
                    break;
                }
                case WMTW_OP_DrawIndexed: g_draws_since_present++; {
                    const struct wmtw_drawindexed *c = (const void *)r;
                    id ib = rm_resolve(c->index_buffer, &err); if (err != RM_OK) { bad = 1; break; }
                    [enc drawIndexedPrimitives:(MTLPrimitiveType)c->primitive
                                    indexCount:(NSUInteger)c->index_count
                                     indexType:(MTLIndexType)c->index_type
                                   indexBuffer:ib
                             indexBufferOffset:(NSUInteger)c->index_offset
                                 instanceCount:(NSUInteger)(c->instances ?: 1)
                                    baseVertex:(NSInteger)c->base_vertex
                                  baseInstance:(NSUInteger)c->base_instance];
                    break;
                }
                default:
                    fprintf(stderr, "[rmetald] replay: opcode %u validated but not "
                            "implemented, at record %u\n", r->op, replayed);
                    bad = 1; break;
                }
                if (bad) break;
                off += r->size; replayed++;
            }
    return bad ? -1 : (int)replayed;
}

/* Title-bar FPS, computed the SAME way as the guest's overlay so the two
 * readouts can be compared directly rather than argued about:
 *
 *   - sample the present counter every 100ms into a 5s ring (50 entries)
 *   - every 250ms, walk back from the newest sample until the window holds
 *     >=3 presents AND spans >=1s, then fps = presents / seconds
 *
 * The >=1s minimum is load bearing. With 100ms sampling a short window
 * quantises the readout to multiples of 5 -- a true ~19 FPS reads as a rock
 * steady "20.0" with dips to 15.0, which looks like a frame lock that is not
 * there. One second gives 1-FPS resolution and is still responsive. */
#define RM_FPS_SAMPLES 50

static void rm_start_fps_title(void) {
    static double t_ring[RM_FPS_SAMPLES];
    static unsigned long long c_ring[RM_FPS_SAMPLES];
    static unsigned n_ring;                 /* total samples ever taken */
    __block double last_shown = -1.0;

    /* STATIC: under ARC a local dispatch_source_t is released when this
     * function returns, which cancels the timer before it ever fires -- the
     * title simply never changed. */
    static dispatch_source_t sampler;
    sampler =
        dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(sampler, DISPATCH_TIME_NOW, 100ull * NSEC_PER_MSEC, 10ull * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(sampler, ^{
        unsigned idx = n_ring % RM_FPS_SAMPLES;
        t_ring[idx] = CFAbsoluteTimeGetCurrent();
        c_ring[idx] = atomic_load(&g_present_count);
        n_ring++;
    });
    dispatch_resume(sampler);

    static dispatch_source_t shower;
    shower =
        dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(shower, DISPATCH_TIME_NOW, 250ull * NSEC_PER_MSEC, 25ull * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(shower, ^{
        if (n_ring < 2) return;
        unsigned have = n_ring < RM_FPS_SAMPLES ? n_ring : RM_FPS_SAMPLES;
        unsigned newest = (n_ring - 1) % RM_FPS_SAMPLES;
        double   lt = t_ring[newest];
        unsigned long long lc = c_ring[newest];

        /* Walk backwards to the oldest sample, stopping early once the window
         * is both long enough and busy enough. */
        unsigned chosen = (n_ring - have) % RM_FPS_SAMPLES;
        for (unsigned k = 1; k < have; k++) {
            unsigned i = (n_ring - 1 - k) % RM_FPS_SAMPLES;
            chosen = i;
            if ((lc - c_ring[i]) >= 3 && (lt - t_ring[i]) >= 1.0) break;
        }
        double dt = lt - t_ring[chosen];
        unsigned long long dc = lc - c_ring[chosen];
        double fps = dt > 0.0001 ? (double)dc / dt : 0.0;

        if (last_shown >= 0 && fabs(fps - last_shown) < 0.05) return;   /* avoid needless title churn */
        last_shown = fps;
        [g_window setTitle:[NSString stringWithFormat:@"Madeira remote Metal  -  %.1f FPS  -  %llu frames",
                            fps, (unsigned long long)lc]];
    });
    dispatch_resume(shower);
}

static void serve(int fd) {
    uint8_t *payload = NULL;
    uint32_t payload_cap = 0;
    for (;;) {
        struct rm_hdr h;
        if (rd(fd, &h, sizeof h)) break;
        if (h.magic != RM_MAGIC)   { reply(fd, &h, RM_ERR_BAD_MAGIC, NULL, 0); break; }
        if (h.version != RM_VERSION) { reply(fd, &h, RM_ERR_BAD_VERSION, NULL, 0); break; }
        if (h.payload_len > RM_MAX_PAYLOAD) {
            fprintf(stderr, "[rmetald] payload %u exceeds cap\n", h.payload_len);
            reply(fd, &h, RM_ERR_SHORT_PAYLOAD, NULL, 0); break;
        }
        if (h.payload_len > payload_cap) {
            uint8_t *np = realloc(payload, h.payload_len);
            if (!np) { reply(fd, &h, RM_ERR_SHORT_PAYLOAD, NULL, 0); break; }
            payload = np; payload_cap = h.payload_len;
        }
        if (h.payload_len && rd(fd, payload, h.payload_len)) break;

        @autoreleasepool {
        uint32_t err = RM_OK;
        /* A malformed or half-switched guest must not be able to kill the
         * daemon. A wrong-class handle raises an ObjC exception the moment a
         * selector is sent, and an uncaught one terminates the process -- the
         * whole host GPU service, for every client. Sending the wrong selector
         * is still a bug worth seeing, so it is reported and named rather than
         * silently swallowed. */
        @try {
        switch (h.opcode) {
        case RM_OP_PING:
            reply(fd, &h, RM_OK, NULL, 0); break;

        case RM_OP_COPY_ALL_DEVICES: {
            id dev = MTLCreateSystemDefaultDevice();
            NSArray *arr = dev ? @[dev] : @[];
            struct rm_ret_handle r = { rm_intern(arr) };
            reply(fd, &h, RM_OK, &r, sizeof r); break;
        }
        case RM_OP_ARRAY_COUNT: {
            if (h.payload_len < sizeof(struct rm_arg_handle)) { reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            id o = rm_resolve(((struct rm_arg_handle *)payload)->handle, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            if (![o isKindOfClass:[NSArray class]]) { reply(fd,&h,RM_ERR_WRONG_CLASS,NULL,0); break; }
            struct rm_ret_u64 r = { [(NSArray *)o count] };
            reply(fd, &h, RM_OK, &r, sizeof r); break;
        }
        case RM_OP_ARRAY_OBJECT: {
            struct rm_arg_handle_u64 *a = (void *)payload;
            if (h.payload_len < sizeof *a) { reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            id o = rm_resolve(a->handle, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            if (![o isKindOfClass:[NSArray class]]) { reply(fd,&h,RM_ERR_WRONG_CLASS,NULL,0); break; }
            NSArray *arr = o;
            if (a->arg >= arr.count) { reply(fd,&h,RM_ERR_BAD_HANDLE,NULL,0); break; }
            struct rm_ret_handle r = { rm_intern(arr[(NSUInteger)a->arg]) };
            reply(fd, &h, RM_OK, &r, sizeof r); break;
        }
        case RM_OP_DEVICE_NAME: {
            id o = rm_resolve(((struct rm_arg_handle *)payload)->handle, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            const char *n = [[(id<MTLDevice>)o name] UTF8String] ?: "";
            reply(fd, &h, RM_OK, n, (uint32_t)strlen(n)); break;
        }
        case RM_OP_SUPPORTS_FAMILY: {
            struct rm_arg_handle_u64 *a = (void *)payload;
            id o = rm_resolve(a->handle, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            struct rm_ret_u64 r = { [(id<MTLDevice>)o supportsFamily:(MTLGPUFamily)a->arg] ? 1 : 0 };
            reply(fd, &h, RM_OK, &r, sizeof r); break;
        }
        case RM_OP_SUPPORTS_BC: {
            id o = rm_resolve(((struct rm_arg_handle *)payload)->handle, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            struct rm_ret_u64 r = { [(id<MTLDevice>)o supportsBCTextureCompression] ? 1 : 0 };
            reply(fd, &h, RM_OK, &r, sizeof r); break;
        }
        case RM_OP_ALLOCATED_SIZE: {
            id o = rm_resolve(((struct rm_arg_handle *)payload)->handle, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            struct rm_ret_u64 r = { [(id<MTLDevice>)o currentAllocatedSize] };
            reply(fd, &h, RM_OK, &r, sizeof r); break;
        }
        case RM_OP_RETAIN: {
            id o = rm_resolve(((struct rm_arg_handle *)payload)->handle, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            (void)o;
            struct rm_ret_handle r = { rm_retain_handle(((struct rm_arg_handle *)payload)->handle, &err) };
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            reply(fd, &h, RM_OK, &r, sizeof r); break;
        }
        case RM_OP_RELEASE:
            reply(fd, &h, rm_release_handle(((struct rm_arg_handle *)payload)->handle), NULL, 0); break;

        case RM_OP_STATS: {
            struct rm_ret_u64 r = { g_live };
            reply(fd, &h, RM_OK, &r, sizeof r); break;
        }
        case RM_OP_NEW_COMMAND_QUEUE: {
            /* The guest's max-command-buffer-count is load bearing: it bounds how
             * many command buffers may be in flight, and silently substituting
             * Metal's default changes when the guest blocks. */
            struct rm_arg_handle_u64 *a = (void *)payload;
            if (h.payload_len < sizeof *a) { reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            id o = rm_resolve(a->handle, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            id<MTLCommandQueue> q = a->arg
                ? [(id<MTLDevice>)o newCommandQueueWithMaxCommandBufferCount:(NSUInteger)a->arg]
                : [(id<MTLDevice>)o newCommandQueue];
            struct rm_ret_handle r = { rm_intern(q) };
            reply(fd, &h, RM_OK, &r, sizeof r); break;
        }
        case RM_OP_NEW_BUFFER: {
            struct rm_new_buffer *a = (void *)payload;
            if (h.payload_len < sizeof *a) { reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            id o = rm_resolve(a->device, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            uint32_t inline_len = h.payload_len - (uint32_t)sizeof *a;
            if (inline_len && a->length != inline_len) {   /* declared vs delivered */
                reply(fd, &h, RM_ERR_SHORT_PAYLOAD, NULL, 0); break;
            }
            const void *init = inline_len ? payload + sizeof *a : NULL;
            id<MTLBuffer> b = init
                ? [(id<MTLDevice>)o newBufferWithBytes:init length:a->length options:MTLResourceStorageModeShared]
                : [(id<MTLDevice>)o newBufferWithLength:a->length options:MTLResourceStorageModeShared];
            struct rm_ret_handle r = { rm_intern(b) };
            reply(fd, &h, RM_OK, &r, sizeof r); break;
        }
        case RM_OP_NEW_TEXTURE: {
            struct rm_new_texture *a = (void *)payload;
            id o = rm_resolve(a->device, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            MTLTextureDescriptor *d = [MTLTextureDescriptor
                texture2DDescriptorWithPixelFormat:(MTLPixelFormat)a->pixel_format
                width:(NSUInteger)a->width height:(NSUInteger)a->height mipmapped:NO];
            d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
            d.storageMode = MTLStorageModeShared;
            struct rm_ret_handle r = { rm_intern([(id<MTLDevice>)o newTextureWithDescriptor:d]) };
            reply(fd, &h, RM_OK, &r, sizeof r); break;
        }
        case RM_OP_NEW_LIBRARY: {
            struct rm_arg_handle *a = (void *)payload;
            id o = rm_resolve(a->handle, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            NSString *src = [[NSString alloc] initWithBytes:payload + sizeof *a
                             length:h.payload_len - sizeof *a encoding:NSUTF8StringEncoding];
            NSError *e = nil;
            id<MTLLibrary> lib = [(id<MTLDevice>)o newLibraryWithSource:src options:nil error:&e];
            if (!lib) { /* surface the compiler diagnostic; a silent nil is useless */
                const char *m = [[e localizedDescription] UTF8String] ?: "shader compile failed";
                fprintf(stderr, "[rmetald] library: %s\n", m);
                reply(fd, &h, RM_ERR_WRONG_CLASS, NULL, 0); break;
            }
            struct rm_ret_handle r = { rm_intern(lib) };
            reply(fd, &h, RM_OK, &r, sizeof r); break;
        }
        case RM_OP_NEW_FUNCTION: {
            struct rm_arg_handle *a = (void *)payload;
            id o = rm_resolve(a->handle, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            NSString *n = [[NSString alloc] initWithBytes:payload + sizeof *a
                           length:h.payload_len - sizeof *a encoding:NSUTF8StringEncoding];
            struct rm_ret_handle r = { rm_intern([(id<MTLLibrary>)o newFunctionWithName:n]) };
            reply(fd, &h, RM_OK, &r, sizeof r); break;
        }
        case RM_OP_NEW_RENDER_PIPELINE: {
            struct rm_new_pipeline *a = (void *)payload;
            id dev = rm_resolve(a->device, &err); if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            id vfn = rm_resolve(a->vfn, &err);    if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            id ffn = rm_resolve(a->ffn, &err);    if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
            d.vertexFunction = vfn; d.fragmentFunction = ffn;
            d.colorAttachments[0].pixelFormat = (MTLPixelFormat)a->pixel_format;
            NSError *e = nil;
            id ps = [(id<MTLDevice>)dev newRenderPipelineStateWithDescriptor:d error:&e];
            if (!ps) { fprintf(stderr, "[rmetald] pipeline: %s\n",
                               [[e localizedDescription] UTF8String] ?: "?");
                       reply(fd, &h, RM_ERR_WRONG_CLASS, NULL, 0); break; }
            struct rm_ret_handle r = { rm_intern(ps) };
            reply(fd, &h, RM_OK, &r, sizeof r); break;
        }
        case RM_OP_SUBMIT_RENDER_PASS: {
            struct rm_render_pass *a = (void *)payload;
            /* A producer that forgets to zero present_drawable would send
             * stack garbage here, and resolving it silently fails the whole
             * pass with a confusing STALE_HANDLE. Validate it as a handle only
             * when non-zero, and say which field was wrong. */
            /* Two different failures, and only one of them can give the
             * drawable back. If the frame is too short to even contain the
             * struct, present_drawable cannot be READ -- reading it would be
             * an out-of-bounds access on attacker-controlled input -- so the
             * drawable is stranded and the guest must recover it with
             * RM_OP_DISCARD_DRAWABLE. If the struct is present but cmd_bytes
             * is wrong, the handle is readable and must be consumed. */
            if (h.payload_len < sizeof *a) {
                fprintf(stderr, "[rmetald] render pass frame too short (%u < %zu); "
                        "any acquired drawable must be returned with DISCARD_DRAWABLE\n",
                        h.payload_len, sizeof *a);
                reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break;
            }
            if (a->cmd_bytes > h.payload_len - sizeof *a) {   /* stream must fit the frame */
                rm_consume_drawable(a->present_drawable);
                reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break;
            }
            /* From here on, any early return must give the drawable back. */
            id q = rm_resolve(a->queue, &err);
            if (err != RM_OK) { rm_consume_drawable(a->present_drawable);
                                reply(fd,&h,err,NULL,0); break; }
            id tex = rm_resolve(a->color_texture, &err);
            if (err != RM_OK) { rm_consume_drawable(a->present_drawable);
                                reply(fd,&h,err,NULL,0); break; }
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture = tex;
            rp.colorAttachments[0].loadAction = MTLLoadActionClear;
            rp.colorAttachments[0].storeAction = MTLStoreActionStore;
            rp.colorAttachments[0].clearColor = MTLClearColorMake(a->clear_r, a->clear_g, a->clear_b, a->clear_a);
            id<MTLCommandBuffer> cb = [(id<MTLCommandQueue>)q commandBuffer];
            id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];

            /* Walk the CONTIGUOUS stream by size, never by pointer. */
            const uint8_t *p = payload + sizeof *a;
            uint32_t off = 0, bad = 0;
            while (off + sizeof(struct rm_enc_hdr) <= a->cmd_bytes) {
                const struct rm_enc_hdr *rec = (const void *)(p + off);
                if (rec->size < sizeof *rec || off + rec->size > a->cmd_bytes) { bad = 1; break; }
                /* Every record must be at least its own struct size. Without
                 * this a short record would be read past its end -- the
                 * command stream is attacker-controlled input. */
                {
                    uint32_t need = 0;
                    switch (rec->type) {
                    case RM_ENC_SET_PIPELINE:     need = sizeof(struct rm_enc_pipeline); break;
                    case RM_ENC_SET_VERTEX_BUFFER:need = sizeof(struct rm_enc_vbuf);     break;
                    case RM_ENC_SET_VIEWPORT:     need = sizeof(struct rm_enc_viewport); break;
                    case RM_ENC_DRAW:             need = sizeof(struct rm_enc_draw);     break;
                    default: need = 0xffffffff; break;
                    }
                    if (rec->size < need) { bad = 1; break; }
                }
                switch (rec->type) {
                case RM_ENC_SET_PIPELINE: {
                    const struct rm_enc_pipeline *c = (const void *)rec;
                    id ps = rm_resolve(c->pipeline, &err); if (err != RM_OK) { bad = 1; break; }
                    [enc setRenderPipelineState:ps]; break;
                }
                case RM_ENC_SET_VERTEX_BUFFER: {
                    const struct rm_enc_vbuf *c = (const void *)rec;
                    id b = rm_resolve(c->buffer, &err); if (err != RM_OK) { bad = 1; break; }
                    [enc setVertexBuffer:b offset:(NSUInteger)c->offset atIndex:(NSUInteger)c->index]; break;
                }
                case RM_ENC_SET_VIEWPORT: {
                    const struct rm_enc_viewport *c = (const void *)rec;
                    [enc setViewport:(MTLViewport){c->x, c->y, c->w, c->h_, c->znear, c->zfar}]; break;
                }
                case RM_ENC_DRAW: {
                    const struct rm_enc_draw *c = (const void *)rec;
                    [enc drawPrimitives:(MTLPrimitiveType)c->primitive
                            vertexStart:(NSUInteger)c->start vertexCount:(NSUInteger)c->count]; break;
                }
                default: bad = 1; break;
                }
                if (bad) break;
                off += rec->size;
            }
            [enc endEncoding];
            if (bad) {
                /* A malformed command stream must not strand the drawable: it
                 * is single-use, and leaking one per failed frame exhausts the
                 * pool and then blocks acquisition forever. */
                rm_consume_drawable(a->present_drawable);
                reply(fd, &h, err ? err : RM_ERR_BAD_OPCODE, NULL, 0); break;
            }
            /* Present on THIS command buffer, before commit -- Metal's
             * intended sequencing. Presenting from a separate call after this
             * buffer had committed would race the display. */
            if (a->present_drawable) {
                id d = rm_resolve(a->present_drawable, &err);
                /* The pass must render into THIS drawable's texture. Presenting
                 * a drawable whose texture was never drawn shows a stale or
                 * blank frame, which looks like a renderer bug rather than a
                 * protocol misuse. */
                if (err != RM_OK) { rm_consume_drawable(a->present_drawable);
                                    reply(fd,&h,err,NULL,0); break; }
                if (d && tex != [(id<CAMetalDrawable>)d texture]) {
                    fprintf(stderr, "[rmetald] color_texture is not the drawable's texture\n");
                    rm_consume_drawable(a->present_drawable);
                    reply(fd, &h, RM_ERR_WRONG_CLASS, NULL, 0); break;
                }
                if (err != RM_OK) {
                    fprintf(stderr, "[rmetald] present_drawable=%llu invalid (%u) -- "
                            "an uninitialised field in the caller's render pass?\n",
                            (unsigned long long)a->present_drawable, err);
                    reply(fd,&h,err,NULL,0); break;
                }
                [cb presentDrawable:(id<CAMetalDrawable>)d];
            }
            [cb commit];
            [cb waitUntilCompleted];   /* synchronous by design */
            /* Consume the drawable AND its texture. A drawable is single-use,
             * and NEXT_DRAWABLE interns two handles for it -- releasing only
             * the drawable leaked one texture handle per frame, which a 600
             * frame run made obvious (611 live handles). The texture belongs
             * to the drawable, so its handle dies with it. */
            rm_consume_drawable(a->present_drawable);
            struct rm_ret_u64 r = { (uint64_t)[cb status] };
            reply(fd, &h, RM_OK, &r, sizeof r); break;
        }
        case RM_OP_LAYER_SIZE: {
            __block CGSize sz = CGSizeZero;
            dispatch_sync(dispatch_get_main_queue(), ^{ sz = g_layer.drawableSize; });
            struct rm_ret_drawable r = { 0, 0, (uint64_t)sz.width, (uint64_t)sz.height };
            reply(fd, &h, RM_OK, &r, sizeof r); break;
        }
        case RM_OP_NEXT_DRAWABLE: {
            __block CGSize sz = CGSizeZero;
            /* Only the window/layer MUTATION belongs on main. nextDrawable can
             * block -- on the drawable pool, or indefinitely while the window
             * is minimised -- and blocking the main queue there would freeze
             * AppKit event processing, so the user could not even restore the
             * window that is causing the block. Acquire on this thread. */
            dispatch_sync(dispatch_get_main_queue(), ^{
                NSView *v = [g_window contentView];
                /* Only on change. Assigning .frame every acquisition commits a
                 * CoreAnimation layout transaction per frame, which can recycle
                 * the drawable pool underneath frames already in flight. */
                if (!CGRectEqualToRect(g_layer.frame, v.bounds))
                    g_layer.frame = v.bounds;
                /* Honour a size the guest asked for. Overwriting it with the window
                 * backing size on every acquisition left the guest drawing into the
                 * top-left corner of a larger drawable -- the black padding. */
                CGSize want;
                if (g_guest_w > 0 && g_guest_h > 0) {
                    want = CGSizeMake(g_guest_w, g_guest_h);
                } else {
                    CGFloat s = g_window.backingScaleFactor ?: 1.0;
                    want = CGSizeMake(v.bounds.size.width * s, v.bounds.size.height * s);
                }
                if (!CGSizeEqualToSize(want, g_layer.drawableSize) && want.width > 0)
                    g_layer.drawableSize = want;
                sz = g_layer.drawableSize;
            });
            id<CAMetalDrawable> d = [g_layer nextDrawable];
            if (!d) {
                static unsigned long missed;
                if (++missed <= 4 || (missed % 256) == 0)
                    fprintf(stderr, "[rmetald] nextDrawable returned nil (%lu times) -- the "
                                    "guest will present an undrawn frame\n", missed);
                reply(fd, &h, RM_ERR_NO_DRAWABLE, NULL, 0); break;
            }
            uint64_t dh = rm_intern(d), th = rm_intern(d.texture);
            rm_pair_record(dh, th);
            struct rm_ret_drawable r = { dh, th, (uint64_t)sz.width, (uint64_t)sz.height };
            reply(fd, &h, RM_OK, &r, sizeof r); break;
        }
        case RM_OP_DISCARD_DRAWABLE: {
            /* Acquired but never submitted. Without this the guest has no way
             * to give a drawable back, and the single-use pool drains. */
            rm_consume_drawable(((struct rm_arg_handle *)payload)->handle);
            reply(fd, &h, RM_OK, NULL, 0); break;
        }
        case RM_OP_DISPATCH_DATA: {
            /* The blob arrives inline. dispatch_data_create with
             * DISPATCH_DATA_DESTRUCTOR_DEFAULT copies, so the payload buffer
             * may be reused the moment this returns. */
            if (h.payload_len == 0) { reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            dispatch_data_t dd = dispatch_data_create(payload, h.payload_len,
                                    dispatch_get_global_queue(0, 0),
                                    DISPATCH_DATA_DESTRUCTOR_DEFAULT);
            struct rm_ret_handle r = { rm_intern((id)dd) };
            reply(fd, &h, RM_OK, &r, sizeof r); break;
        }
        case RM_OP_NEW_LIBRARY_DATA: {
            struct rm_arg_handle_u64 *a = (void *)payload;
            if (h.payload_len < sizeof *a) { reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            id dev = rm_resolve(a->handle, &err); if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            id dat = rm_resolve(a->arg, &err);    if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            NSError *e = nil;
            id<MTLLibrary> lib = [(id<MTLDevice>)dev newLibraryWithData:(dispatch_data_t)dat error:&e];
            if (!lib) {
                fprintf(stderr, "[rmetald] newLibraryWithData: %s\n",
                        [[e localizedDescription] UTF8String] ?: "?");
                reply(fd, &h, RM_ERR_WRONG_CLASS, NULL, 0); break;
            }
            struct rm_ret_handle r = { rm_intern(lib) };
            reply(fd, &h, RM_OK, &r, sizeof r); break;
        }
        case RM_OP_NEW_COMPUTE_PSO: {
            /* DXMT supplies a full WMTComputePipelineInfo, not just a function:
             * immutable-buffer flags, a serialization archive, and a GUEST
             * POINTER to an array of lookup archives. The pointer cannot cross,
             * so the archives travel as a sidecar of handles. */
            struct rm_compute_pso *a = (void *)payload;
            if (h.payload_len < sizeof *a) { reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            uint32_t need = (uint32_t)a->num_archives * (uint32_t)sizeof(uint64_t);
            if (a->num_archives > 32 || h.payload_len - sizeof *a < need) {
                reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break;
            }
            id dev = rm_resolve(a->device, &err);   if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            id fn  = rm_resolve(a->function, &err); if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }

            MTLComputePipelineDescriptor *d = [MTLComputePipelineDescriptor new];
            d.computeFunction = fn;
            d.threadGroupSizeIsMultipleOfThreadExecutionWidth = a->tgsize_multiple_of_sgwidth != 0;
            for (unsigned i = 0; i < 32; i++)
                if (a->immutable_buffers & (1u << i))
                    d.buffers[i].mutability = MTLMutabilityImmutable;
            /* Lookup archives resolve through the handle table like anything
             * else; a stale one must fail rather than be skipped silently. */
            if (a->num_archives) {
                const uint64_t *hs = (const uint64_t *)(payload + sizeof *a);
                NSMutableArray *arr = [NSMutableArray array];
                for (unsigned i = 0; i < a->num_archives; i++) {
                    id ar = rm_resolve(hs[i], &err);
                    if (err != RM_OK) break;
                    if (ar) [arr addObject:ar];
                }
                if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
                if (arr.count) d.binaryArchives = arr;
            }
            NSError *e = nil;
            MTLComputePipelineReflection *refl = nil;
            id ps = [(id<MTLDevice>)dev newComputePipelineStateWithDescriptor:d
                        options:MTLPipelineOptionNone reflection:&refl error:&e];
            if (!ps) {
                fprintf(stderr, "[rmetald] compute PSO: %s\n",
                        [[e localizedDescription] UTF8String] ?: "?");
                reply(fd, &h, RM_ERR_WRONG_CLASS, NULL, 0); break;
            }
            struct rm_ret_handle r = { rm_intern(ps) };
            reply(fd, &h, RM_OK, &r, sizeof r); break;
        }
        case RM_OP_NEW_DEPTH_STENCIL: {
            struct rm_dss_desc *a = (void *)payload;
            if (h.payload_len < sizeof *a) { reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            id dev = rm_resolve(a->device, &err); if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            MTLDepthStencilDescriptor *d = [MTLDepthStencilDescriptor new];
            d.depthCompareFunction = (MTLCompareFunction)a->depth_compare_function;
            d.depthWriteEnabled = a->depth_write_enabled != 0;
            #define STENCIL(dst, src) do { \
                if ((src).enabled) { \
                    MTLStencilDescriptor *sd = [MTLStencilDescriptor new]; \
                    sd.depthStencilPassOperation = (MTLStencilOperation)(src).depth_stencil_pass_op; \
                    sd.stencilFailureOperation   = (MTLStencilOperation)(src).stencil_fail_op; \
                    sd.depthFailureOperation     = (MTLStencilOperation)(src).depth_fail_op; \
                    sd.stencilCompareFunction    = (MTLCompareFunction)(src).compare_function; \
                    sd.writeMask = (src).write_mask; sd.readMask = (src).read_mask; \
                    dst = sd; \
                } } while (0)
            STENCIL(d.frontFaceStencil, a->front);
            STENCIL(d.backFaceStencil,  a->back);
            #undef STENCIL
            id dss = [(id<MTLDevice>)dev newDepthStencilStateWithDescriptor:d];
            if (!dss) { reply(fd, &h, RM_ERR_WRONG_CLASS, NULL, 0); break; }
            struct rm_ret_resource r = { rm_intern(dss), 0, 0, 0 };
            reply(fd, &h, RM_OK, &r, sizeof r); break;
        }
        case RM_OP_NEW_SAMPLER: {
            struct rm_sampler_desc *a = (void *)payload;
            if (h.payload_len < sizeof *a) { reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            id dev = rm_resolve(a->device, &err); if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            MTLSamplerDescriptor *d = [MTLSamplerDescriptor new];
            d.minFilter = (MTLSamplerMinMagFilter)a->min_filter;
            d.magFilter = (MTLSamplerMinMagFilter)a->mag_filter;
            d.mipFilter = (MTLSamplerMipFilter)a->mip_filter;
            d.rAddressMode = (MTLSamplerAddressMode)a->r_address;
            d.sAddressMode = (MTLSamplerAddressMode)a->s_address;
            d.tAddressMode = (MTLSamplerAddressMode)a->t_address;
            d.borderColor = (MTLSamplerBorderColor)a->border_color;
            d.compareFunction = (MTLCompareFunction)a->compare_function;
            d.lodMinClamp = a->lod_min_clamp; d.lodMaxClamp = a->lod_max_clamp;
            d.maxAnisotropy = a->max_anisotropy ? a->max_anisotropy : 1;
            d.normalizedCoordinates = a->normalized_coords != 0;
            d.lodAverage = a->lod_average != 0;
            d.supportArgumentBuffers = a->support_argument_buffers != 0;
            id<MTLSamplerState> ss = [(id<MTLDevice>)dev newSamplerStateWithDescriptor:d];
            if (!ss) { reply(fd, &h, RM_ERR_WRONG_CLASS, NULL, 0); break; }
            /* gpu_resource_id is an OUT field the caller reads. */
            struct rm_ret_resource r = { rm_intern(ss),
                a->support_argument_buffers ? ss.gpuResourceID._impl : 0, 0, 0 };
            reply(fd, &h, RM_OK, &r, sizeof r); break;
        }
        case RM_OP_NEW_TEXTURE_INFO: {
            struct rm_texture_desc *a = (void *)payload;
            if (h.payload_len < sizeof *a) { reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            id dev = rm_resolve(a->device, &err); if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            MTLTextureDescriptor *d = [MTLTextureDescriptor new];
            d.pixelFormat = (MTLPixelFormat)a->pixel_format;
            d.width = a->width; d.height = a->height; d.depth = a->depth;
            d.arrayLength = a->array_length ? a->array_length : 1;
            d.textureType = (MTLTextureType)a->type;
            d.mipmapLevelCount = a->mipmap_level_count ? a->mipmap_level_count : 1;
            d.sampleCount = a->sample_count ? a->sample_count : 1;
            d.usage = (MTLTextureUsage)a->usage;
            d.storageMode = MTLStorageModeShared;
            id<MTLTexture> t = [(id<MTLDevice>)dev newTextureWithDescriptor:d];
            if (!t) { reply(fd, &h, RM_ERR_WRONG_CLASS, NULL, 0); break; }
            /* mach_port stays 0: a port name cannot cross machines. */
            struct rm_ret_resource r = { rm_intern(t), t.gpuResourceID._impl, 0, 0 };
            reply(fd, &h, RM_OK, &r, sizeof r); break;
        }
        case RM_OP_BUFFER_CREATE: {
            struct rm_buffer_create *a = (void *)payload;
            if (h.payload_len < sizeof *a) { reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            id dev = rm_resolve(a->device, &err); if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            /* Created empty; contents arrive as ranges. Shared storage so the
             * host can write into it without a staging round trip. */
            id<MTLBuffer> b = [(id<MTLDevice>)dev newBufferWithLength:(NSUInteger)a->length
                                  options:MTLResourceStorageModeShared];
            if (!b) { reply(fd, &h, RM_ERR_WRONG_CLASS, NULL, 0); break; }
            struct rm_ret_resource r = { rm_intern(b), b.gpuAddress, 0, 0 };
            reply(fd, &h, RM_OK, &r, sizeof r); break;
        }
        case RM_OP_BUFFER_WRITE: {
            struct rm_buffer_range *a = (void *)payload;
            if (h.payload_len < sizeof *a) { reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            id o = rm_resolve(a->handle, &err); if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            id<MTLBuffer> b = o;
            uint32_t inlined = h.payload_len - (uint32_t)sizeof *a;
            /* Every bound checked in 64-bit against the REAL buffer length.
             * offset+length in 32-bit could wrap and write outside it. */
            if (a->length != inlined ||
                a->length > RM_CHUNK_BYTES ||
                (uint64_t)a->offset + a->length > (uint64_t)b.length) {
                fprintf(stderr, "[rmetald] buffer write out of range: off=%llu len=%llu inline=%u buf=%lu\n",
                        (unsigned long long)a->offset, (unsigned long long)a->length,
                        inlined, (unsigned long)b.length);
                reply(fd, &h, RM_ERR_SHORT_PAYLOAD, NULL, 0); break;
            }
            memcpy((uint8_t *)b.contents + a->offset, payload + sizeof *a, a->length);
            reply(fd, &h, RM_OK, NULL, 0); break;
        }
        case RM_OP_BUFFER_READ: {
            struct rm_buffer_range *a = (void *)payload;
            if (h.payload_len < sizeof *a) { reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            id o = rm_resolve(a->handle, &err); if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            id<MTLBuffer> b = o;
            if (a->length > RM_CHUNK_BYTES ||
                (uint64_t)a->offset + a->length > (uint64_t)b.length) {
                reply(fd, &h, RM_ERR_SHORT_PAYLOAD, NULL, 0); break;
            }
            reply(fd, &h, RM_OK, (const uint8_t *)b.contents + a->offset, (uint32_t)a->length);
            break;
        }
        case RM_OP_SUBMIT_WMT_BATCH: {
            struct rm_wmt_submit *a = (void *)payload;
            if (h.payload_len < sizeof *a ||
                a->batch_bytes > h.payload_len - sizeof *a) {
                reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break;
            }
            id q = rm_resolve(a->queue, &err);
            if (err != RM_OK) { rm_consume_drawable(a->present_drawable);
                                reply(fd,&h,err,NULL,0); break; }
            id tex = rm_resolve(a->color_texture, &err);
            if (err != RM_OK) { rm_consume_drawable(a->present_drawable);
                                reply(fd,&h,err,NULL,0); break; }

            /* VALIDATE BEFORE REPLAY. The batch is untrusted input, and the
             * validator is the same function the test suites exercise -- a
             * second walker here would prove nothing about either. */
            struct wmtw_view v; struct wmtw_dec_result dr;
            if (wmtw_validate_batch(payload + sizeof *a, a->batch_bytes, &v, &dr) != WMTW_DEC_OK) {
                fprintf(stderr, "[rmetald] batch rejected: %s at record %u (opcode %u)\n",
                        wmtw_dec_strerror(dr.status), dr.record_index, dr.opcode);
                rm_consume_drawable(a->present_drawable);
                reply(fd, &h, RM_ERR_BAD_OPCODE, NULL, 0); break;
            }

            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture = tex;
            rp.colorAttachments[0].loadAction = MTLLoadActionClear;
            rp.colorAttachments[0].storeAction = MTLStoreActionStore;
            rp.colorAttachments[0].clearColor =
                MTLClearColorMake(a->clear_r, a->clear_g, a->clear_b, a->clear_a);
            id<MTLCommandBuffer> cb = [(id<MTLCommandQueue>)q commandBuffer];
            id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];

            uint32_t off = 0, bad = 0, replayed = 0;
            while (off < v.rec_bytes) {
                const struct wmtw_hdr *r = (const void *)(v.rec + off);
                switch (r->op) {
                case WMTW_OP_Nop: break;
                case WMTW_OP_SetPSO: {
                    const struct wmtw_setpso *c = (const void *)r;
                    id o = rm_resolve(c->pso, &err); if (err != RM_OK) { bad = 1; break; }
                    [enc setRenderPipelineState:o]; break;
                }
                case WMTW_OP_SetDSSO: {
                    const struct wmtw_setdsso *c = (const void *)r;
                    id o = rm_resolve(c->dsso, &err); if (err != RM_OK) { bad = 1; break; }
                    [enc setDepthStencilState:o];
                    [enc setStencilReferenceValue:c->stencil_ref]; break;
                }
                case WMTW_OP_SetVertexBuffer: {
                    const struct wmtw_setvertexbuffer *c = (const void *)r;
                    id o = rm_resolve(c->buffer, &err); if (err != RM_OK) { bad = 1; break; }
                    [enc setVertexBuffer:o offset:(NSUInteger)c->offset atIndex:(NSUInteger)c->index];
                    break;
                }
                case WMTW_OP_SetVertexBufferOffset: {
                    const struct wmtw_setvertexbufferoffset *c = (const void *)r;
                    [enc setVertexBufferOffset:(NSUInteger)c->offset atIndex:(NSUInteger)c->index];
                    break;
                }
                case WMTW_OP_SetFragmentBufferOffset: {
                    const struct wmtw_setfragmentbufferoffset *c = (const void *)r;
                    [enc setFragmentBufferOffset:(NSUInteger)c->offset atIndex:(NSUInteger)c->index];
                    break;
                }
                case WMTW_OP_SetFragmentBuffer: {
                    const struct wmtw_setfragmentbuffer *c = (const void *)r;
                    id o = rm_resolve(c->buffer, &err); if (err != RM_OK) { bad = 1; break; }
                    [enc setFragmentBuffer:o offset:(NSUInteger)c->offset atIndex:(NSUInteger)c->index];
                    break;
                }
                case WMTW_OP_SetFragmentTexture: {
                    const struct wmtw_setfragmenttexture *c = (const void *)r;
                    id o = rm_resolve(c->texture, &err); if (err != RM_OK) { bad = 1; break; }
                    [enc setFragmentTexture:o atIndex:(NSUInteger)c->index]; break;
                }
                case WMTW_OP_SetFragmentBytes: {
                    const struct wmtw_setfragmentbytes *c = (const void *)r;
                    [enc setFragmentBytes:v.side + c->bytes_offset
                                   length:c->bytes_count atIndex:(NSUInteger)c->index];
                    break;
                }
                case WMTW_OP_SetViewports: {
                    const struct wmtw_setviewports *c = (const void *)r;
                    /* validator proved the range and 8-byte alignment */
                    [enc setViewports:(const MTLViewport *)(v.side + c->viewports_offset)
                                count:c->viewports_count];
                    break;
                }
                case WMTW_OP_SetScissorRects: {
                    const struct wmtw_setscissorrects *c = (const void *)r;
                    [enc setScissorRects:(const MTLScissorRect *)(v.side + c->scissors_offset)
                                   count:c->scissors_count];
                    break;
                }
                case WMTW_OP_SetRasterizerState: {
                    const struct wmtw_setrasterizerstate *c = (const void *)r;
                    [enc setFrontFacingWinding:(MTLWinding)c->front_facing];
                    [enc setCullMode:(MTLCullMode)c->cull_mode];
                    [enc setTriangleFillMode:(MTLTriangleFillMode)c->fill_mode];
                    [enc setDepthClipMode:(MTLDepthClipMode)c->depth_clip_mode];
                    [enc setDepthBias:c->depth_bias slopeScale:c->slope_scale clamp:c->depth_bias_clamp];
                    break;
                }
                case WMTW_OP_SetBlendFactorAndStencilRef: {
                    const struct wmtw_setblendfactorandstencilref *c = (const void *)r;
                    [enc setBlendColorRed:c->r green:c->g blue:c->b alpha:c->a];
                    [enc setStencilReferenceValue:c->stencil_ref]; break;
                }
                case WMTW_OP_UseResource: {
                    const struct wmtw_useresource *c = (const void *)r;
                    id o = rm_resolve(c->resource, &err); if (err != RM_OK) { bad = 1; break; }
                    [enc useResource:o usage:(MTLResourceUsage)c->usage
                              stages:(MTLRenderStages)c->stages]; break;
                }
                case WMTW_OP_Draw: {
                    const struct wmtw_draw *c = (const void *)r;
                    [enc drawPrimitives:(MTLPrimitiveType)c->primitive
                            vertexStart:(NSUInteger)c->start vertexCount:(NSUInteger)c->count
                          instanceCount:(NSUInteger)(c->instances ?: 1)
                           baseInstance:(NSUInteger)c->base_instance];
                    break;
                }
                case WMTW_OP_DrawIndexed: {
                    const struct wmtw_drawindexed *c = (const void *)r;
                    id ib = rm_resolve(c->index_buffer, &err); if (err != RM_OK) { bad = 1; break; }
                    [enc drawIndexedPrimitives:(MTLPrimitiveType)c->primitive
                                    indexCount:(NSUInteger)c->index_count
                                     indexType:(MTLIndexType)c->index_type
                                   indexBuffer:ib
                             indexBufferOffset:(NSUInteger)c->index_offset
                                 instanceCount:(NSUInteger)(c->instances ?: 1)
                                    baseVertex:(NSInteger)c->base_vertex
                                  baseInstance:(NSUInteger)c->base_instance];
                    break;
                }
                default:
                    fprintf(stderr, "[rmetald] replay: opcode %u validated but not "
                            "implemented, at record %u\n", r->op, replayed);
                    bad = 1; break;
                }
                if (bad) break;
                off += r->size; replayed++;
            }
            [enc endEncoding];
            if (bad) {
                rm_consume_drawable(a->present_drawable);
                reply(fd, &h, err ? err : RM_ERR_BAD_OPCODE, NULL, 0); break;
            }
            if (a->present_drawable) {
                id d = rm_resolve(a->present_drawable, &err);
                if (err == RM_OK && d) [cb presentDrawable:(id<CAMetalDrawable>)d];
            }
            [cb commit];
            [cb waitUntilCompleted];
            rm_consume_drawable(a->present_drawable);
            struct rm_ret_u64 rr2 = { replayed };
            reply(fd, &h, RM_OK, &rr2, sizeof rr2); break;
        }
        case RM_OP_TEXTURE_GETBYTES: {
            id o = rm_resolve(((struct rm_arg_handle *)payload)->handle, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            id<MTLTexture> t = o;
            NSUInteger w = t.width, ht = t.height, bpr = w * 4, total = bpr * ht;
            uint8_t *px = malloc(total);
            [t getBytes:px bytesPerRow:bpr fromRegion:MTLRegionMake2D(0,0,w,ht) mipmapLevel:0];
            reply(fd, &h, RM_OK, px, (uint32_t)total);
            free(px); break;
        }
        /* ---- descriptor calls: verbatim WMT*Info in, real Metal object out ---- */
        case RM_OP_COMMAND_BUFFER: {
            id q = rm_resolve(((struct rm_arg_handle *)payload)->handle, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            id<MTLCommandBuffer> cb = [(id<MTLCommandQueue>)q commandBuffer];
            struct rm_ret_handle r = { rm_intern(cb) };
            reply(fd, &h, cb ? RM_OK : RM_ERR_WRONG_CLASS, &r, sizeof r); break;
        }
        case RM_OP_RENDER_ENCODER: {
            struct rm_wmt_info *a = (void *)payload;
            if (h.payload_len < sizeof *a + sizeof(struct WMTRenderPassInfo)) {
                reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            id cb = rm_resolve(a->owner, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            const struct WMTRenderPassInfo *i = (void *)(a + 1);
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            /* The REAL pass: eight colour attachments with their own load/store
             * actions, levels, slices and resolve targets, plus depth and
             * stencil. A single hardcoded clear-to-colour attachment is what the
             * throwaway test path used and it cannot draw a cube. */
            for (unsigned c = 0; c < 8; c++) {
                if (!i->colors[c].texture) continue;
                uint32_t e2 = RM_OK;
                id t = rm_resolve((uint64_t)i->colors[c].texture, &e2);
                if (e2 != RM_OK) {
                    /* Silently skipping leaves a pass that disagrees with the
                     * pipeline -- which is how the encoder abort happened. */
                    fprintf(stderr, "[rmetald] render pass: colour attachment %u handle "
                                    "0x%llx did not resolve (status %u)\n", c,
                            (unsigned long long)i->colors[c].texture, e2);
                    continue;
                }
                rp.colorAttachments[c].texture     = t;
                rp.colorAttachments[c].loadAction  = (MTLLoadAction)i->colors[c].load_action;
                rp.colorAttachments[c].storeAction = (MTLStoreAction)i->colors[c].store_action;
                rp.colorAttachments[c].level       = i->colors[c].level;
                rp.colorAttachments[c].slice       = i->colors[c].slice;
                rp.colorAttachments[c].depthPlane  = i->colors[c].depth_plane;
                rp.colorAttachments[c].clearColor  = MTLClearColorMake(
                    i->colors[c].clear_color.r, i->colors[c].clear_color.g,
                    i->colors[c].clear_color.b, i->colors[c].clear_color.a);
                if (i->colors[c].resolve_texture) {
                    uint32_t e3 = RM_OK;
                    id rt = rm_resolve((uint64_t)i->colors[c].resolve_texture, &e3);
                    if (e3 == RM_OK) {
                        rp.colorAttachments[c].resolveTexture    = rt;
                        rp.colorAttachments[c].resolveLevel      = i->colors[c].resolve_level;
                        rp.colorAttachments[c].resolveSlice      = i->colors[c].resolve_slice;
                        rp.colorAttachments[c].resolveDepthPlane = i->colors[c].resolve_depth_plane;
                    }
                }
            }
            if (i->depth.texture) {
                uint32_t e2 = RM_OK; id t = rm_resolve((uint64_t)i->depth.texture, &e2);
                if (e2 == RM_OK) {
                    rp.depthAttachment.texture     = t;
                    rp.depthAttachment.loadAction  = (MTLLoadAction)i->depth.load_action;
                    rp.depthAttachment.storeAction = (MTLStoreAction)i->depth.store_action;
                    rp.depthAttachment.level       = i->depth.level;
                    rp.depthAttachment.slice       = i->depth.slice;
                    rp.depthAttachment.clearDepth  = i->depth.clear_depth;
                }
            }
            if (i->stencil.texture) {
                uint32_t e2 = RM_OK; id t = rm_resolve((uint64_t)i->stencil.texture, &e2);
                if (e2 == RM_OK) {
                    rp.stencilAttachment.texture      = t;
                    rp.stencilAttachment.loadAction   = (MTLLoadAction)i->stencil.load_action;
                    rp.stencilAttachment.storeAction  = (MTLStoreAction)i->stencil.store_action;
                    rp.stencilAttachment.level        = i->stencil.level;
                    rp.stencilAttachment.slice        = i->stencil.slice;
                    rp.stencilAttachment.clearStencil = i->stencil.clear_stencil;
                }
            }
            if (i->render_target_height) rp.renderTargetHeight = i->render_target_height;
            if (i->render_target_width)  rp.renderTargetWidth  = i->render_target_width;
            if (i->default_raster_sample_count) rp.defaultRasterSampleCount = i->default_raster_sample_count;
            id<MTLRenderCommandEncoder> enc =
                [(id<MTLCommandBuffer>)cb renderCommandEncoderWithDescriptor:rp];
            struct rm_ret_handle r = { rm_intern(enc) };
            reply(fd, &h, enc ? RM_OK : RM_ERR_WRONG_CLASS, &r, sizeof r); break;
        }
        case RM_OP_ENCODE_INTO: {
            struct rm_arg_handle *a = (void *)payload;
            if (h.payload_len < sizeof *a) { reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            id e2 = rm_resolve(a->handle, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            struct wmtw_view v; struct wmtw_dec_result dr;
            if (wmtw_validate_batch((const uint8_t *)payload + sizeof *a,
                                    h.payload_len - (uint32_t)sizeof *a, &v, &dr) != WMTW_DEC_OK) {
                fprintf(stderr, "[rmetald] batch rejected: %s at record %u (opcode %u)\n",
                        wmtw_dec_strerror(dr.status), dr.record_index, dr.opcode);
                reply(fd, &h, RM_ERR_BAD_OPCODE, NULL, 0); break;
            }
            int n = rm_replay_into((id<MTLRenderCommandEncoder>)e2, v);
            struct rm_ret_u64 r = { n < 0 ? 0 : (uint64_t)n };
            reply(fd, &h, n < 0 ? RM_ERR_BAD_HANDLE : RM_OK, &r, sizeof r); break;
        }
        case RM_OP_END_ENCODING: {
            id o = rm_resolve(((struct rm_arg_handle *)payload)->handle, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            [(id<MTLCommandEncoder>)o endEncoding];
            reply(fd, &h, RM_OK, NULL, 0); break;
        }
        case RM_OP_PRESENT_DRAWABLE: {
            struct rm_present *a = (void *)payload;
            if (h.payload_len < sizeof *a) { reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            id cb = rm_resolve(a->cmdbuf, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            uint32_t e2 = RM_OK;
            id d = rm_resolve(a->drawable, &e2);
            if (e2 != RM_OK) { reply(fd,&h,e2,NULL,0); break; }
            {
                static unsigned long frames, blank;
                frames++;
                atomic_fetch_add(&g_present_count, 1);
                if (g_draws_since_present == 0) {
                    blank++;
                    if (blank <= 4 || (blank % 64) == 0)
                        fprintf(stderr, "[rmetald] BLANK frame presented: no draw records "
                                        "since the last present (%lu blank of %lu)\n",
                                blank, frames);
                } else if ((frames % 600) == 0) {
                    fprintf(stderr, "[rmetald] frames=%lu blank=%lu (%.2f%%) draws/frame=%lu\n",
                            frames, blank, 100.0 * blank / frames, g_draws_since_present);
                }
                g_draws_since_present = 0;
            }
            [(id<MTLCommandBuffer>)cb presentDrawable:(id<CAMetalDrawable>)d];
            /* Presented: the drawable is the layer's again, so drop the pairing
             * that was holding it. Without this the pool leaks a drawable a
             * frame and acquisition eventually blocks forever. */
            rm_consume_drawable(a->drawable);
            reply(fd, &h, RM_OK, NULL, 0); break;
        }
        case RM_OP_COMMIT: {
            id o = rm_resolve(((struct rm_arg_handle *)payload)->handle, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            [(id<MTLCommandBuffer>)o commit];
            reply(fd, &h, RM_OK, NULL, 0); break;
        }
        case RM_OP_WAIT_COMPLETED: {
            id o = rm_resolve(((struct rm_arg_handle *)payload)->handle, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            [(id<MTLCommandBuffer>)o waitUntilCompleted];
            reply(fd, &h, RM_OK, NULL, 0); break;
        }
        case RM_OP_CMDBUF_STATUS: {
            id o = rm_resolve(((struct rm_arg_handle *)payload)->handle, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            struct rm_ret_u64 r = { (uint64_t)[(id<MTLCommandBuffer>)o status] };
            reply(fd, &h, RM_OK, &r, sizeof r); break;
        }
        case RM_OP_ENCODE_SIGNAL:
        case RM_OP_ENCODE_WAIT: {
            struct rm_encode_sig *a = (void *)payload;
            if (h.payload_len < sizeof *a) { reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            id cb = rm_resolve(a->cmdbuf, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            uint32_t e2 = RM_OK; id ev = rm_resolve(a->event, &e2);
            if (e2 != RM_OK) { reply(fd,&h,e2,NULL,0); break; }
            if (h.opcode == RM_OP_ENCODE_SIGNAL)
                [(id<MTLCommandBuffer>)cb encodeSignalEvent:(id<MTLEvent>)ev value:a->value];
            else
                [(id<MTLCommandBuffer>)cb encodeWaitForEvent:(id<MTLEvent>)ev value:a->value];
            reply(fd, &h, RM_OK, NULL, 0); break;
        }
        case RM_OP_NEW_TEXTURE_FULL: {
            struct rm_wmt_info *a = (void *)payload;
            if (h.payload_len < sizeof *a + sizeof(struct WMTTextureInfo)) {
                reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            id dev = rm_resolve(a->owner, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            const struct WMTTextureInfo *i = (void *)(a + 1);
            MTLTextureDescriptor *d = [[MTLTextureDescriptor alloc] init];
            d.pixelFormat      = rm_fmt(i->pixel_format);
            d.width            = i->width  ? i->width  : 1;
            d.height           = i->height ? i->height : 1;
            d.depth            = i->depth  ? i->depth  : 1;
            d.arrayLength      = i->array_length ? i->array_length : 1;
            d.textureType      = (MTLTextureType)i->type;
            d.mipmapLevelCount = i->mipmap_level_count ? i->mipmap_level_count : 1;
            d.sampleCount      = i->sample_count ? i->sample_count : 1;
            d.usage            = (MTLTextureUsage)i->usage;
            d.resourceOptions  = (MTLResourceOptions)i->options;
            id<MTLTexture> t = [(id<MTLDevice>)dev newTextureWithDescriptor:d];
            if (!t) fprintf(stderr, "[rmetald] newTexture %ux%u fmt %u type %u usage %u FAILED\n",
                            i->width, i->height, (unsigned)i->pixel_format,
                            (unsigned)i->type, (unsigned)i->usage);
            struct rm_ret_handle_u64 r = { rm_intern(t), t ? t.gpuResourceID._impl : 0 };
            reply(fd, &h, t ? RM_OK : RM_ERR_WRONG_CLASS, &r, sizeof r); break;
        }
        case RM_OP_TEXTURE_REPLACE: {
            struct rm_tex_replace *a = (void *)payload;
            if (h.payload_len < sizeof *a) { reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            id o = rm_resolve(a->texture, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            uint32_t have = h.payload_len - (uint32_t)sizeof *a;
            uint64_t need = (uint64_t)a->bytes_per_row * a->h * (a->d ? a->d : 1);
            if (need > have) {
                fprintf(stderr, "[rmetald] texture upload short: need %llu have %u\n",
                        (unsigned long long)need, have);
                reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            [(id<MTLTexture>)o replaceRegion:MTLRegionMake3D(a->x, a->y, a->z, a->w, a->h, a->d ? a->d : 1)
                                 mipmapLevel:a->level
                                       slice:a->slice
                                   withBytes:(const uint8_t *)payload + sizeof *a
                                 bytesPerRow:a->bytes_per_row
                               bytesPerImage:a->bytes_per_image];
            reply(fd, &h, RM_OK, NULL, 0); break;
        }
        case RM_OP_NEW_TEXTURE_VIEW: {
            struct rm_tex_view *a = (void *)payload;
            if (h.payload_len < sizeof *a) { reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            id o = rm_resolve(a->texture, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            id<MTLTexture> t = [(id<MTLTexture>)o
                newTextureViewWithPixelFormat:rm_fmt((enum WMTPixelFormat)a->format)
                                  textureType:(MTLTextureType)a->texture_type
                                       levels:NSMakeRange(a->level_start, a->level_count)
                                       slices:NSMakeRange(a->slice_start, a->slice_count)];
            struct rm_ret_handle_u64 r = { rm_intern(t), t ? t.gpuResourceID._impl : 0 };
            reply(fd, &h, t ? RM_OK : RM_ERR_WRONG_CLASS, &r, sizeof r); break;
        }
        case RM_OP_LAYER_SET_PROPS: {
            struct rm_wmt_info *a = (void *)payload;
            if (h.payload_len < sizeof *a + sizeof(struct WMTLayerProps)) {
                reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            const struct WMTLayerProps *p = (void *)(a + 1);
            double w = p->drawable_width, ht = p->drawable_height;
            unsigned pf = (unsigned)p->pixel_format;
            int opaque = p->opaque, fbonly = p->framebuffer_only;
            /* Assign ONLY on change.
             *
             * Writing drawableSize makes CoreAnimation tear down and rebuild the
             * layer's drawable pool even when the value is identical. The guest
             * re-sends the same 1024x768 about ten times a second, so the pool
             * was being recycled underneath frames in flight -- which presents
             * blank, and reads as a black flash a few times a second. Same care
             * for the other properties: they are all pool-affecting. */
            __block int changed = 0;
            dispatch_sync(dispatch_get_main_queue(), ^{
                if (w > 0 && ht > 0) {
                    CGSize want = CGSizeMake(w, ht);
                    g_guest_w = w; g_guest_h = ht;
                    if (!CGSizeEqualToSize(g_layer.drawableSize, want)) {
                        g_layer.drawableSize = want; changed = 1;
                    }
                }
                if (pf) {
                    MTLPixelFormat f = rm_fmt((enum WMTPixelFormat)pf);
                    if (g_layer.pixelFormat != f) { g_layer.pixelFormat = f; changed = 1; }
                }
                BOOL o = opaque ? YES : NO, fb = fbonly ? YES : NO;
                if (g_layer.opaque != o)          { g_layer.opaque = o; changed = 1; }
                if (g_layer.framebufferOnly != fb) { g_layer.framebufferOnly = fb; changed = 1; }
            });
            {
                static unsigned long calls, applied;
                calls++; if (changed) applied++;
                if (changed || calls <= 2 || (calls % 512) == 0)
                    fprintf(stderr, "[rmetald] layer props %.0fx%.0f fmt %u -- %s "
                                    "(%lu calls, %lu applied)\n", w, ht, pf,
                            changed ? "APPLIED" : "no change, pool preserved", calls, applied);
            }
            reply(fd, &h, RM_OK, NULL, 0); break;
        }
        case RM_OP_LAYER_GET_PROPS: {
            __block struct WMTLayerProps r;
            memset(&r, 0, sizeof r);
            dispatch_sync(dispatch_get_main_queue(), ^{
                r.contents_scale   = g_layer.contentsScale;
                r.drawable_width   = g_layer.drawableSize.width;
                r.drawable_height  = g_layer.drawableSize.height;
                r.opaque           = g_layer.opaque;
                r.framebuffer_only = g_layer.framebufferOnly;
                r.display_sync_enabled = 1;
                r.pixel_format     = (enum WMTPixelFormat)g_layer.pixelFormat;
            });
            reply(fd, &h, RM_OK, &r, sizeof r); break;
        }
        case RM_OP_MIN_LINEAR_ALIGN: {
            struct rm_arg_handle_u64 *a = (void *)payload;
            if (h.payload_len < sizeof *a) { reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            id o = rm_resolve(a->handle, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            NSUInteger al = [(id<MTLDevice>)o minimumLinearTextureAlignmentForPixelFormat:
                             rm_fmt((enum WMTPixelFormat)a->arg)];
            /* Never hand back zero: the caller divides by this. */
            struct rm_ret_u64 r = { al ? al : 256 };
            reply(fd, &h, RM_OK, &r, sizeof r); break;
        }
        case RM_OP_SUPPORTS_SAMPLE_COUNT: {
            struct rm_arg_handle_u64 *a = (void *)payload;
            if (h.payload_len < sizeof *a) { reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            id o = rm_resolve(a->handle, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            struct rm_ret_u64 r = { [(id<MTLDevice>)o supportsTextureSampleCount:a->arg] ? 1 : 0 };
            reply(fd, &h, RM_OK, &r, sizeof r); break;
        }
        case RM_OP_BLIT_ENCODER: {
            id cb = rm_resolve(((struct rm_arg_handle *)payload)->handle, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            id<MTLBlitCommandEncoder> e2 = [(id<MTLCommandBuffer>)cb blitCommandEncoder];
            struct rm_ret_handle r = { rm_intern(e2) };
            reply(fd, &h, e2 ? RM_OK : RM_ERR_WRONG_CLASS, &r, sizeof r); break;
        }
        case RM_OP_SET_LABEL: {
            struct rm_arg_handle *a = (void *)payload;
            if (h.payload_len < sizeof *a) { reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            id o = rm_resolve(a->handle, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            NSString *l = [[NSString alloc] initWithBytes:(const uint8_t *)payload + sizeof *a
                           length:h.payload_len - sizeof *a encoding:NSUTF8StringEncoding];
            [(id<MTLCommandEncoder>)o setLabel:l];
            reply(fd, &h, RM_OK, NULL, 0); break;
        }
        case RM_OP_BLIT_INTO: {
            /* Blit commands are handles and scalars only -- no inline pointers
             * -- so each command's struct travels verbatim and is translated
             * here, the same discipline the descriptors use. Records are
             * {type, size, bytes}; the guest's `next` pointer is not sent. */
            struct rm_arg_handle *a = (void *)payload;
            if (h.payload_len < sizeof *a) { reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            id eo = rm_resolve(a->handle, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            id<MTLBlitCommandEncoder> enc = eo;
            const uint8_t *p = (const uint8_t *)payload + sizeof *a;
            const uint8_t *end = (const uint8_t *)payload + h.payload_len;
            uint64_t done = 0, skipped = 0;
            while ((size_t)(end - p) >= 8) {
                uint32_t type = *(const uint32_t *)p, sz = *(const uint32_t *)(p + 4);
                const uint8_t *rec = p + 8;
                if (sz > (size_t)(end - rec)) break;
                p = rec + sz;
                uint32_t e2 = RM_OK;
                #define RES(h_) rm_resolve((uint64_t)(h_), &e2)
                switch (type) {
                case WMTBlitCommandNop: break;
                case WMTBlitCommandCopyFromBufferToBuffer: {
                    const struct wmtcmd_blit_copy_from_buffer_to_buffer *c = (const void *)rec;
                    id sb = RES(c->src), db = RES(c->dst);
                    if (e2 != RM_OK || !sb || !db) { skipped++; break; }
                    [enc copyFromBuffer:sb sourceOffset:c->src_offset toBuffer:db
              destinationOffset:c->dst_offset size:c->copy_length];
                    done++; break;
                }
                case WMTBlitCommandCopyFromBufferToTexture: {
                    const struct wmtcmd_blit_copy_from_buffer_to_texture *c = (const void *)rec;
                    id sb = RES(c->src), dt = RES(c->dst);
                    if (e2 != RM_OK || !sb || !dt) { skipped++; break; }
                    [enc copyFromBuffer:sb sourceOffset:c->src_offset
                      sourceBytesPerRow:c->bytes_per_row sourceBytesPerImage:c->bytes_per_image
                             sourceSize:MTLSizeMake(c->size.width, c->size.height, c->size.depth)
                              toTexture:dt destinationSlice:c->slice destinationLevel:c->level
                     destinationOrigin:MTLOriginMake(c->origin.x, c->origin.y, c->origin.z)];
                    done++; break;
                }
                case WMTBlitCommandCopyFromTextureToBuffer: {
                    const struct wmtcmd_blit_copy_from_texture_to_buffer *c = (const void *)rec;
                    id st2 = RES(c->src), db = RES(c->dst);
                    if (e2 != RM_OK || !st2 || !db) { skipped++; break; }
                    [enc copyFromTexture:st2 sourceSlice:c->slice sourceLevel:c->level
                            sourceOrigin:MTLOriginMake(c->origin.x, c->origin.y, c->origin.z)
                              sourceSize:MTLSizeMake(c->size.width, c->size.height, c->size.depth)
                                toBuffer:db destinationOffset:c->offset
                   destinationBytesPerRow:c->bytes_per_row
                 destinationBytesPerImage:c->bytes_per_image];
                    done++; break;
                }
                case WMTBlitCommandCopyFromTextureToTexture: {
                    const struct wmtcmd_blit_copy_from_texture_to_texture *c = (const void *)rec;
                    id st2 = RES(c->src), dt = RES(c->dst);
                    if (e2 != RM_OK || !st2 || !dt) { skipped++; break; }
                    [enc copyFromTexture:st2 sourceSlice:c->src_slice sourceLevel:c->src_level
                            sourceOrigin:MTLOriginMake(c->src_origin.x, c->src_origin.y, c->src_origin.z)
                              sourceSize:MTLSizeMake(c->src_size.width, c->src_size.height, c->src_size.depth)
                               toTexture:dt destinationSlice:c->dst_slice
                        destinationLevel:c->dst_level
                       destinationOrigin:MTLOriginMake(c->dst_origin.x, c->dst_origin.y, c->dst_origin.z)];
                    done++; break;
                }
                case WMTBlitCommandGenerateMipmaps: {
                    const struct wmtcmd_blit_generate_mipmaps *c = (const void *)rec;
                    id t = RES(c->texture);
                    if (e2 != RM_OK || !t) { skipped++; break; }
                    [enc generateMipmapsForTexture:t]; done++; break;
                }
                case WMTBlitCommandFillBuffer: {
                    const struct wmtcmd_blit_fillbuffer *c = (const void *)rec;
                    id b = RES(c->buffer);
                    if (e2 != RM_OK || !b) { skipped++; break; }
                    [enc fillBuffer:b range:NSMakeRange(c->offset, c->length) value:c->value];
                    done++; break;
                }
                case WMTBlitCommandWaitForFence:
                case WMTBlitCommandUpdateFence: {
                    const struct wmtcmd_blit_fence_op *c = (const void *)rec;
                    id f = c->fence ? RES(c->fence) : nil;
                    if (e2 != RM_OK || !f) { skipped++; break; }
                    if (type == WMTBlitCommandUpdateFence) [enc updateFence:f];
                    else                                   [enc waitForFence:f];
                    done++; break;
                }
                default: {
                    static unsigned told;
                    if (told++ < 8)
                        fprintf(stderr, "[rmetald] blit: unknown command type %u -- skipped\n", type);
                    skipped++; break;
                }
                }
                #undef RES
            }
            if (skipped) {
                static unsigned told;
                if (told++ < 8)
                    fprintf(stderr, "[rmetald] blit batch: %llu replayed, %llu SKIPPED "
                                    "(a skipped copy leaves its destination stale)\n",
                            (unsigned long long)done, (unsigned long long)skipped);
            }
            struct rm_ret_u64 r = { done };
            reply(fd, &h, RM_OK, &r, sizeof r); break;
        }
        case RM_OP_BUFFER_NEW_TEXTURE: {
            /* A texture VIEWING a buffer's memory. Streaming creates these, so
             * an unrouted one stalls loading rather than failing visibly. */
            struct rm_buf_texture *a = (void *)payload;
            if (h.payload_len < sizeof *a + sizeof(struct WMTTextureInfo)) {
                reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            id b = rm_resolve(a->buffer, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            const struct WMTTextureInfo *i = (void *)(a + 1);
            MTLTextureDescriptor *d = [[MTLTextureDescriptor alloc] init];
            d.pixelFormat      = rm_fmt(i->pixel_format);
            d.width            = i->width  ? i->width  : 1;
            d.height           = i->height ? i->height : 1;
            d.depth            = i->depth  ? i->depth  : 1;
            d.arrayLength      = i->array_length ? i->array_length : 1;
            d.textureType      = (MTLTextureType)i->type;
            d.mipmapLevelCount = i->mipmap_level_count ? i->mipmap_level_count : 1;
            d.sampleCount      = i->sample_count ? i->sample_count : 1;
            d.usage            = (MTLTextureUsage)i->usage;
            d.resourceOptions  = (MTLResourceOptions)i->options;
            id<MTLTexture> t = [(id<MTLBuffer>)b newTextureWithDescriptor:d
                                                                  offset:a->offset
                                                             bytesPerRow:a->bytes_per_row];
            if (!t) fprintf(stderr, "[rmetald] buffer-backed texture %ux%u fmt %u bpr %llu FAILED\n",
                            i->width, i->height, (unsigned)i->pixel_format,
                            (unsigned long long)a->bytes_per_row);
            struct rm_ret_handle_u64 r = { rm_intern(t), t ? t.gpuResourceID._impl : 0 };
            reply(fd, &h, t ? RM_OK : RM_ERR_WRONG_CLASS, &r, sizeof r); break;
        }
        case RM_OP_TEXTURE_DIMS: {
            id o = rm_resolve(((struct rm_arg_handle *)payload)->handle, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            id<MTLTexture> t = o;
            struct rm_ret_handle_u64 r = { t.width, t.height };
            reply(fd, &h, RM_OK, &r, sizeof r); break;
        }
        case RM_OP_CREATE_VIEW: {
            id dev = rm_resolve(((struct rm_arg_handle *)payload)->handle, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            /* The guest's HWND is deliberately not transported: it names a
             * window in the guest's own windowing system, which has no meaning
             * here. What the guest actually needs back is something it can
             * acquire drawables from -- the host's layer. */
            (void)dev;
            __block id viewObj = nil;
            dispatch_sync(dispatch_get_main_queue(), ^{ viewObj = [g_window contentView]; });
            struct rm_ret_view r = { rm_intern(viewObj), rm_intern(g_layer) };
            fprintf(stderr, "[rmetald] view bound: layer 0x%llx (host window)\n",
                    (unsigned long long)r.layer);
            reply(fd, &h, (r.view && r.layer) ? RM_OK : RM_ERR_WRONG_CLASS, &r, sizeof r); break;
        }
        case RM_OP_RELEASE_VIEW: {
            reply(fd, &h, rm_release_handle(((struct rm_arg_handle *)payload)->handle), NULL, 0); break;
        }
        case RM_OP_NEW_SHARED_EVENT: {
            id o = rm_resolve(((struct rm_arg_handle *)payload)->handle, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            id<MTLSharedEvent> ev = [(id<MTLDevice>)o newSharedEvent];
            struct rm_ret_handle r = { rm_intern(ev) };
            reply(fd, &h, ev ? RM_OK : RM_ERR_WRONG_CLASS, &r, sizeof r); break;
        }
        case RM_OP_SHARED_EVENT_VALUE: {
            id o = rm_resolve(((struct rm_arg_handle *)payload)->handle, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            struct rm_ret_u64 r = { [(id<MTLSharedEvent>)o signaledValue] };
            reply(fd, &h, RM_OK, &r, sizeof r); break;
        }
        case RM_OP_NEW_BUFFER_INFO: {
            struct rm_wmt_info *a = (void *)payload;
            if (h.payload_len < sizeof *a + sizeof(struct WMTBufferInfo)) {
                reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            id dev = rm_resolve(a->owner, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            const struct WMTBufferInfo *i = (void *)(a + 1);
            /* The host ALLOCATES; the guest's memory pointer is a guest address
             * and must never be handed to newBufferWithBytesNoCopy here. */
            id<MTLBuffer> b = [(id<MTLDevice>)dev newBufferWithLength:i->length
                                                              options:(MTLResourceOptions)i->options];
            if (!b) fprintf(stderr, "[rmetald] newBuffer(%llu bytes, options %u) failed\n",
                            (unsigned long long)i->length, (unsigned)i->options);
            struct rm_ret_handle_u64 r = { rm_intern(b), b ? b.gpuAddress : 0 };
            reply(fd, &h, b ? RM_OK : RM_ERR_WRONG_CLASS, &r, sizeof r); break;
        }
        case RM_OP_BUFFER_UPLOAD: {
            struct rm_buffer_range *a = (void *)payload;
            if (h.payload_len < sizeof *a) { reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            id o = rm_resolve(a->handle, &err);
            if (err != RM_OK) {
                static unsigned told;
                if (told++ < 8)
                    fprintf(stderr, "[rmetald] buffer upload: handle 0x%llx did not resolve "
                                    "(status %u)\n", (unsigned long long)a->handle, err);
                reply(fd,&h,err,NULL,0); break;
            }
            id<MTLBuffer> b = o;
            uint64_t have = h.payload_len - sizeof *a;
            if (a->offset + a->length > b.length || a->length > have) {
                fprintf(stderr, "[rmetald] buffer upload out of range: off %llu len %llu into %llu\n",
                        (unsigned long long)a->offset, (unsigned long long)a->length,
                        (unsigned long long)b.length);
                reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            if (b.storageMode == MTLStorageModePrivate) {
                /* Silent before: the guest saw a failed upload with no reason
                 * on this side, which is the hardest kind of gap to chase. */
                static unsigned told;
                if (told++ < 8)
                    fprintf(stderr, "[rmetald] buffer 0x%llx is PRIVATE -- upload refused "
                                    "(guest believes it is CPU visible)\n",
                            (unsigned long long)a->handle);
                reply(fd,&h,RM_ERR_WRONG_CLASS,NULL,0); break;
            }
            memcpy((uint8_t *)b.contents + a->offset, (const uint8_t *)payload + sizeof *a, a->length);
            if (b.storageMode == MTLStorageModeManaged)
                [b didModifyRange:NSMakeRange(a->offset, a->length)];
            reply(fd, &h, RM_OK, NULL, 0); break;
        }
        case RM_OP_NEW_RENDER_PSO_INFO: {
            struct rm_wmt_info *a = (void *)payload;
            if (h.payload_len < sizeof *a + sizeof(struct WMTRenderPipelineInfo)) {
                reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            id dev = rm_resolve(a->owner, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            const struct WMTRenderPipelineInfo *i = (void *)(a + 1);
            MTLRenderPipelineDescriptor *d = [[MTLRenderPipelineDescriptor alloc] init];
            for (unsigned c = 0; c < 8; c++) {
                d.colorAttachments[c].pixelFormat     = rm_fmt(i->colors[c].pixel_format);
                d.colorAttachments[c].blendingEnabled = i->colors[c].blending_enabled;
                d.colorAttachments[c].writeMask       = (MTLColorWriteMask)i->colors[c].write_mask;
                d.colorAttachments[c].alphaBlendOperation = (MTLBlendOperation)i->colors[c].alpha_blend_operation;
                d.colorAttachments[c].rgbBlendOperation   = (MTLBlendOperation)i->colors[c].rgb_blend_operation;
                d.colorAttachments[c].sourceRGBBlendFactor        = (MTLBlendFactor)i->colors[c].src_rgb_blend_factor;
                d.colorAttachments[c].sourceAlphaBlendFactor      = (MTLBlendFactor)i->colors[c].src_alpha_blend_factor;
                d.colorAttachments[c].destinationRGBBlendFactor   = (MTLBlendFactor)i->colors[c].dst_rgb_blend_factor;
                d.colorAttachments[c].destinationAlphaBlendFactor = (MTLBlendFactor)i->colors[c].dst_alpha_blend_factor;
            }
            for (unsigned b = 0; b < 31; b++) {
                if (i->immutable_fragment_buffers & (1u << b)) d.fragmentBuffers[b].mutability = MTLMutabilityImmutable;
                if (i->immutable_vertex_buffers   & (1u << b)) d.vertexBuffers[b].mutability   = MTLMutabilityImmutable;
            }
            d.depthAttachmentPixelFormat   = rm_fmt(i->depth_pixel_format);
            d.stencilAttachmentPixelFormat = rm_fmt(i->stencil_pixel_format);
            d.alphaToCoverageEnabled = i->alpha_to_coverage_enabled;
            d.rasterizationEnabled   = i->rasterization_enabled;
            d.rasterSampleCount      = i->raster_sample_count ? i->raster_sample_count : 1;
            d.inputPrimitiveTopology = (MTLPrimitiveTopologyClass)i->input_primitive_topology;
            d.tessellationPartitionMode        = (MTLTessellationPartitionMode)i->tessellation_partition_mode;
            d.tessellationFactorStepFunction   = (MTLTessellationFactorStepFunction)i->tessellation_factor_step;
            d.tessellationOutputWindingOrder   = (MTLWinding)i->tessellation_output_winding_order;
            d.maxTessellationFactor            = i->max_tessellation_factor;
            uint32_t bad = RM_OK;
            id vf = i->vertex_function   ? rm_resolve((uint64_t)i->vertex_function, &bad)   : nil;
            uint32_t bad2 = RM_OK;
            id ff = i->fragment_function ? rm_resolve((uint64_t)i->fragment_function, &bad2) : nil;
            /* Metal ABORTS the process for an invalid pipeline descriptor -- it
             * is not an ObjC exception, so the @try around this switch cannot
             * catch it and the whole GPU service dies mid-session. A nil vertex
             * function is the common way to get there, and it happens whenever a
             * function handle fails to resolve. Refuse the call instead. */
            if (!vf || bad != RM_OK) {
                fprintf(stderr, "[rmetald] render pipeline REFUSED: vertex function %llu "
                                "did not resolve (status %u) -- not handing a nil function "
                                "to Metal\n", (unsigned long long)i->vertex_function, bad);
                struct rm_ret_handle z = { 0 };
                reply(fd, &h, RM_ERR_BAD_HANDLE, &z, sizeof z); break;
            }
            if (i->fragment_function && (!ff || bad2 != RM_OK)) {
                fprintf(stderr, "[rmetald] render pipeline REFUSED: fragment function %llu "
                                "did not resolve (status %u)\n",
                        (unsigned long long)i->fragment_function, bad2);
                struct rm_ret_handle z = { 0 };
                reply(fd, &h, RM_ERR_BAD_HANDLE, &z, sizeof z); break;
            }
            d.vertexFunction = (id<MTLFunction>)vf;
            d.fragmentFunction = (id<MTLFunction>)ff;
            NSError *e = nil;
            id<MTLRenderPipelineState> pso =
                [(id<MTLDevice>)dev newRenderPipelineStateWithDescriptor:d error:&e];
            if (!pso) fprintf(stderr, "[rmetald] newRenderPipelineState: %s\n",
                              e ? [[e localizedDescription] UTF8String] : "?");
            struct rm_ret_handle r = { rm_intern(pso) };
            reply(fd, &h, pso ? RM_OK : RM_ERR_WRONG_CLASS, &r, sizeof r); break;
        }
        case RM_OP_NEW_FUNCTION_CONSTS: {
            struct rm_wmt_info *a = (void *)payload;
            if (h.payload_len < sizeof *a + a->info_len) { reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            id lib = rm_resolve(a->owner, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            const uint8_t *p = (const uint8_t *)(a + 1);
            NSString *nm = [[NSString alloc] initWithBytes:p length:a->info_len encoding:NSUTF8StringEncoding];
            p += a->info_len;
            const uint8_t *end = (const uint8_t *)payload + h.payload_len;
            MTLFunctionConstantValues *cv = [[MTLFunctionConstantValues alloc] init];
            for (uint32_t c = 0; c < a->extra_count; c++) {
                if ((size_t)(end - p) < sizeof(struct rm_fn_const)) break;
                const struct rm_fn_const *fc = (const void *)p;
                p += sizeof *fc;
                if ((size_t)(end - p) < fc->value_len) break;
                [cv setConstantValue:p type:(MTLDataType)fc->type atIndex:fc->index];
                p += fc->value_len;
            }
            NSError *e = nil;
            id<MTLFunction> fn = [(id<MTLLibrary>)lib newFunctionWithName:nm constantValues:cv error:&e];
            if (!fn) fprintf(stderr, "[rmetald] newFunctionWithConstants(%s): %s\n",
                             [nm UTF8String] ?: "?", e ? [[e localizedDescription] UTF8String] : "?");
            struct rm_ret_handle r = { rm_intern(fn) };
            reply(fd, &h, fn ? RM_OK : RM_ERR_WRONG_CLASS, &r, sizeof r); break;
        }
        case RM_OP_NEW_DSS_INFO: {
            struct rm_wmt_info *a = (void *)payload;
            if (h.payload_len < sizeof *a + sizeof(struct WMTDepthStencilInfo) ||
                a->info_len < sizeof(struct WMTDepthStencilInfo)) {
                reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            id dev = rm_resolve(a->owner, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            const struct WMTDepthStencilInfo *i = (void *)(a + 1);
            MTLDepthStencilDescriptor *d = [[MTLDepthStencilDescriptor alloc] init];
            d.depthCompareFunction = (MTLCompareFunction)i->depth_compare_function;
            d.depthWriteEnabled    = i->depth_write_enabled;
            if (i->front_stencil.enabled) {
                d.frontFaceStencil.depthStencilPassOperation = (MTLStencilOperation)i->front_stencil.depth_stencil_pass_op;
                d.frontFaceStencil.depthFailureOperation     = (MTLStencilOperation)i->front_stencil.depth_fail_op;
                d.frontFaceStencil.stencilFailureOperation   = (MTLStencilOperation)i->front_stencil.stencil_fail_op;
                d.frontFaceStencil.stencilCompareFunction    = (MTLCompareFunction)i->front_stencil.stencil_compare_function;
                d.frontFaceStencil.writeMask                 = i->front_stencil.write_mask;
                d.frontFaceStencil.readMask                  = i->front_stencil.read_mask;
            }
            if (i->back_stencil.enabled) {
                d.backFaceStencil.depthStencilPassOperation = (MTLStencilOperation)i->back_stencil.depth_stencil_pass_op;
                d.backFaceStencil.depthFailureOperation     = (MTLStencilOperation)i->back_stencil.depth_fail_op;
                d.backFaceStencil.stencilFailureOperation   = (MTLStencilOperation)i->back_stencil.stencil_fail_op;
                d.backFaceStencil.stencilCompareFunction    = (MTLCompareFunction)i->back_stencil.stencil_compare_function;
                d.backFaceStencil.writeMask                 = i->back_stencil.write_mask;
                d.backFaceStencil.readMask                  = i->back_stencil.read_mask;
            }
            struct rm_ret_handle r = { rm_intern([(id<MTLDevice>)dev newDepthStencilStateWithDescriptor:d]) };
            reply(fd, &h, r.handle ? RM_OK : RM_ERR_WRONG_CLASS, &r, sizeof r); break;
        }
        case RM_OP_NEW_SAMPLER_INFO: {
            struct rm_wmt_info *a = (void *)payload;
            if (h.payload_len < sizeof *a + sizeof(struct WMTSamplerInfo)) {
                reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            id dev = rm_resolve(a->owner, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            const struct WMTSamplerInfo *i = (void *)(a + 1);
            MTLSamplerDescriptor *d = [[MTLSamplerDescriptor alloc] init];
            d.minFilter = (MTLSamplerMinMagFilter)i->min_filter;
            d.magFilter = (MTLSamplerMinMagFilter)i->mag_filter;
            d.mipFilter = (MTLSamplerMipFilter)i->mip_filter;
            d.rAddressMode = (MTLSamplerAddressMode)i->r_address_mode;
            d.sAddressMode = (MTLSamplerAddressMode)i->s_address_mode;
            d.tAddressMode = (MTLSamplerAddressMode)i->t_address_mode;
            d.borderColor = (MTLSamplerBorderColor)i->border_color;
            d.compareFunction = (MTLCompareFunction)i->compare_function;
            d.lodMinClamp = i->lod_min_clamp;
            d.lodMaxClamp = i->lod_max_clamp;
            d.maxAnisotropy = i->max_anisotroy ? i->max_anisotroy : 1;
            d.normalizedCoordinates = i->normalized_coords;
            d.lodAverage = i->lod_average;
            d.supportArgumentBuffers = i->support_argument_buffers;
            id<MTLSamplerState> ss = [(id<MTLDevice>)dev newSamplerStateWithDescriptor:d];
            /* gpu_resource_id is an OUT field the guest binds with. */
            struct rm_ret_handle_u64 r = { rm_intern(ss),
                ss && i->support_argument_buffers ? ss.gpuResourceID._impl : 0 };
            reply(fd, &h, r.handle ? RM_OK : RM_ERR_WRONG_CLASS, &r, sizeof r); break;
        }
        case RM_OP_NEW_COMPUTE_PSO_INFO: {
            struct rm_wmt_info *a = (void *)payload;
            if (h.payload_len < sizeof *a + sizeof(struct WMTComputePipelineInfo)) {
                reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            id dev = rm_resolve(a->owner, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            const struct WMTComputePipelineInfo *i = (void *)(a + 1);
            id fn = i->compute_function ? rm_resolve((uint64_t)i->compute_function, &err) : nil;
            if (err != RM_OK || !fn) {
                /* Same abort hazard as the render path: a nil compute function
                 * takes the process down rather than returning an error. */
                fprintf(stderr, "[rmetald] compute pipeline REFUSED: function %llu did not "
                                "resolve (status %u)\n",
                        (unsigned long long)i->compute_function, err);
                struct rm_ret_handle z = { 0 };
                reply(fd, &h, RM_ERR_BAD_HANDLE, &z, sizeof z); break;
            }
            MTLComputePipelineDescriptor *d = [[MTLComputePipelineDescriptor alloc] init];
            d.computeFunction = (id<MTLFunction>)fn;
            d.threadGroupSizeIsMultipleOfThreadExecutionWidth = i->tgsize_is_multiple_of_sgwidth;
            for (unsigned b = 0; b < 31; b++)
                if (i->immutable_buffers & (1u << b))
                    d.buffers[b].mutability = MTLMutabilityImmutable;
            NSError *e = nil;
            id<MTLComputePipelineState> pso =
                [(id<MTLDevice>)dev newComputePipelineStateWithDescriptor:d
                                                                  options:MTLPipelineOptionNone
                                                               reflection:nil error:&e];
            if (!pso) fprintf(stderr, "[rmetald] newComputePipelineState: %s\n",
                              e ? [[e localizedDescription] UTF8String] : "?");
            struct rm_ret_handle r = { rm_intern(pso) };
            reply(fd, &h, pso ? RM_OK : RM_ERR_WRONG_CLASS, &r, sizeof r); break;
        }
        case RM_OP_DEVICE_REGISTRY_ID: {
            id o = rm_resolve(((struct rm_arg_handle *)payload)->handle, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            struct rm_ret_u64 r = { [(id<MTLDevice>)o registryID] };
            reply(fd, &h, RM_OK, &r, sizeof r); break;
        }
        case RM_OP_DEVICE_UNIFIED_MEM: {
            id o = rm_resolve(((struct rm_arg_handle *)payload)->handle, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            struct rm_ret_u64 r = { [(id<MTLDevice>)o hasUnifiedMemory] ? 1u : 0u };
            reply(fd, &h, RM_OK, &r, sizeof r); break;
        }
        case RM_OP_DEVICE_MAX_WORKING_SET: {
            id o = rm_resolve(((struct rm_arg_handle *)payload)->handle, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            struct rm_ret_u64 r = { [(id<MTLDevice>)o recommendedMaxWorkingSetSize] };
            reply(fd, &h, RM_OK, &r, sizeof r); break;
        }
        case RM_OP_OS_VERSION: {
            NSOperatingSystemVersion v = [NSProcessInfo processInfo].operatingSystemVersion;
            struct rm_os_version r = { (uint32_t)v.majorVersion, (uint32_t)v.minorVersion,
                                       (uint32_t)v.patchVersion, 0 };
            reply(fd, &h, RM_OK, &r, sizeof r); break;
        }
        case RM_OP_DEVICE_SET_MAXCC: {
            struct rm_arg_handle_u64 *a = (void *)payload;
            if (h.payload_len < sizeof *a) { reply(fd,&h,RM_ERR_SHORT_PAYLOAD,NULL,0); break; }
            id o = rm_resolve(a->handle, &err);
            if (err != RM_OK) { reply(fd,&h,err,NULL,0); break; }
            [(id<MTLDevice>)o setShouldMaximizeConcurrentCompilation:(a->arg != 0)];
            reply(fd, &h, RM_OK, NULL, 0); break;
        }
        default:
            reply(fd, &h, RM_ERR_BAD_OPCODE, NULL, 0); break;
        }
        } @catch (NSException *e) {
            /* Report and name it -- a wrong selector is still a real bug -- but
             * answer the client instead of taking the whole GPU service down. */
            fprintf(stderr, "[rmetald] opcode %u raised %s (%s) -- replying "
                            "WRONG_CLASS rather than terminating\n", h.opcode,
                    e.name ? e.name.UTF8String : "?",
                    e.reason ? e.reason.UTF8String : "?");
            reply(fd, &h, RM_ERR_WRONG_CLASS, NULL, 0);
        }
        }
    }
    free(payload);
}

/* A shared secret, required as the first frame of every connection. The daemon
 * compiles arbitrary shader source and allocates GPU memory on request, so an
 * unauthenticated listener on a routable interface is a remote code-execution
 * surface for anyone on the network. Bound to an explicit address as well. */
static char g_token[64];

static int authenticate(int fd) {
    struct rm_hdr h;
    if (rd(fd, &h, sizeof h)) return 0;
    if (h.magic != RM_MAGIC || h.opcode != RM_OP_PING) return 0;
    if (h.payload_len != strlen(g_token)) return 0;
    char got[sizeof g_token];
    if (rd(fd, got, h.payload_len)) return 0;
    if (memcmp(got, g_token, h.payload_len) != 0) return 0;
    reply(fd, &h, RM_OK, NULL, 0);
    return 1;
}

static int g_listen_fd;

static void *rpc_thread(void *unused) {
    (void)unused;
    for (;;) {
        int c = accept(g_listen_fd, NULL, NULL);
        if (c < 0) continue;
        int one = 1;
        setsockopt(c, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
        setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
        struct timeval tv = { .tv_sec = 30 };
        setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
        setsockopt(c, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
        if (!authenticate(c)) {
            fprintf(stderr, "[rmetald] rejected unauthenticated client\n");
            close(c); continue;
        }
        fprintf(stderr, "[rmetald] client authenticated\n");
        serve(c);
        close(c);
        fprintf(stderr, "[rmetald] client gone; releasing %u session handles\n", g_live);
        rm_census_report();
        rm_reset_table();
    }
    return NULL;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        id<MTLDevice> d = MTLCreateSystemDefaultDevice();
        if (!d) { fprintf(stderr, "no Metal device\n"); return 1; }
        fprintf(stderr, "[rmetald] host GPU: %s\n", [[d name] UTF8String]);
        fprintf(stderr, "[rmetald] Apple7=%d Apple8=%d Apple9=%d BC=%d\n",
                [d supportsFamily:MTLGPUFamilyApple7], [d supportsFamily:MTLGPUFamilyApple8],
                [d supportsFamily:MTLGPUFamilyApple9], [d supportsBCTextureCompression]);
    }
    const char *bind_addr = (argc > 1) ? argv[1] : "127.0.0.1";
    const char *tok = getenv("RMETAL_TOKEN");
    if (!tok || !*tok) { fprintf(stderr, "set RMETAL_TOKEN to a shared secret\n"); return 1; }
    snprintf(g_token, sizeof g_token, "%s", tok);

    int s = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1; setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct sockaddr_in a = { .sin_family = AF_INET, .sin_port = htons(RM_PORT) };
    if (inet_pton(AF_INET, bind_addr, &a.sin_addr) != 1) {
        fprintf(stderr, "bad bind address %s\n", bind_addr); return 1;
    }
    if (bind(s, (struct sockaddr *)&a, sizeof a) || listen(s, 4)) { perror("bind/listen"); return 1; }
    fprintf(stderr, "[rmetald] listening on %s:%d (token required)\n", bind_addr, RM_PORT);
    g_listen_fd = s;

    /* AppKit owns the main thread; RPC runs on a worker. The window is created
     * here, directly -- NOT via dispatch_sync to the main queue, which from the
     * main thread before [NSApp run] is an immediate deadlock. dispatch_sync is
     * only correct from the RPC thread, where it is used. */
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        host_window_create(MTLCreateSystemDefaultDevice());
        [NSApp activateIgnoringOtherApps:YES];
        rm_start_fps_title();   /* timers live on the main queue, so start here */
        pthread_t t;
        pthread_create(&t, NULL, rpc_thread, NULL);
        [NSApp run];
    }
    return 0;
}
