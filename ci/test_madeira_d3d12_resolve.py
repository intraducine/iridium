"""Execute D3D12 resolve recording/replay against a mocked Metal boundary.

These tests establish command shape, ordering and ownership, not GPU rendering.
"""
from pathlib import Path
import shutil
import unittest

from test_madeira_compatibility import function, run_c

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "testrepos/Madeira/research/madeira-d3d12/src/pe/madeira_d3d12.c").read_text()


@unittest.skipUnless(shutil.which("cc"), "C compiler required")
class MadeiraD3D12ResolveTests(unittest.TestCase):
    def test_color_resolve_formats_subresources_resize_order_and_failures(self):
        code = r'''
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <stdarg.h>
typedef unsigned UINT;
typedef uint64_t obj_handle_t;
typedef unsigned DXGI_FORMAT;
#define STDMETHODCALLTYPE
#define D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET 1
#define D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX 1
#define WMTBlitCommandCopyFromTextureToTexture 1
#define WMTLoadActionLoad 1
#define WMTStoreActionStoreAndMultisampleResolve 3
#define WMTTextureType2D 2
#define MC_RESOLVE 1
#define MAD_SKIP(e) ((e)->skipped++)
enum WMTPixelFormat { RGBA = 70, SRGBA = 71, RG = 30, RGBA16 = 115 };
enum WMTTextureSwizzle { Swizzle2 = 2, Swizzle3, Swizzle4, Swizzle5 };
struct WMTTextureSwizzleChannels { enum WMTTextureSwizzle r, g, b, a; };
typedef struct {
    uint64_t Width; UINT Height, DepthOrArraySize, MipLevels, Flags, Format;
    struct { UINT Count; } SampleDesc;
} D3D12_RESOURCE_DESC;
struct WMTTextureInfo { enum WMTPixelFormat pixel_format; UINT width, height; };
struct mad_resource {
    obj_handle_t texture, resolve_tmp;
    UINT resolve_tmp_w, resolve_tmp_h, resolve_tmp_pf, width, height, samples;
    enum WMTPixelFormat tex_pf;
    int is_depth, borrowed;
    D3D12_RESOURCE_DESC desc;
};
typedef struct mad_resource ID3D12Resource;
struct tt {
    struct mad_resource *dst, *src;
    UINT dlevel, dslice, slevel, sslice;
};
struct mad_cmd { int kind; union { struct tt tt; } u; };
struct mad_list { struct mad_cmd cmd; int pushed; };
typedef struct mad_list ID3D12GraphicsCommandList;
typedef struct { ID3D12Resource *pResource; UINT Type, SubresourceIndex; } D3D12_TEXTURE_COPY_LOCATION;
struct attachment { obj_handle_t texture, resolve_texture; UINT level, slice, load_action, store_action, resolve_level, resolve_slice; };
struct WMTRenderPassInfo { struct attachment colors[1]; UINT render_target_width, render_target_height, default_raster_sample_count; };
struct wmtcmd_base { UINT type; };
struct xyz { UINT x, y, z; };
struct whd { UINT width, height, depth; };
struct wmtcmd_blit_copy_from_texture_to_texture {
    UINT type; obj_handle_t src, dst; UINT src_slice, src_level, dst_slice, dst_level;
    struct xyz src_origin, dst_origin; struct whd src_size;
};
struct mad_device { obj_handle_t mtl_device; };
struct mad_queue { struct mad_device *device; };
struct mad_exec { struct mad_queue *q; obj_handle_t cb, benc; UINT npend; int wr_all;
    struct mad_resource *f6_att[2]; UINT f6_natt; int skipped; };
static unsigned g_enc_seq;
static int renders, blits, textures, views, released, ended, fences, copied;
static int fail_view, fail_texture, fail_render, fail_blit;
static struct WMTRenderPassInfo pass;
static struct wmtcmd_blit_copy_from_texture_to_texture blit;
static struct WMTTextureInfo created;
static obj_handle_t last_released;
static UINT view_level, view_slice;
static void d3d12_log(const char *f, ...) { (void)f; }
static UINT mad_pf_bytes(UINT pf);
static int mad_texinfo_from_desc(const D3D12_RESOURCE_DESC *d, struct WMTTextureInfo *t, enum WMTPixelFormat *pf, int *depth) {
    t->width = (UINT)d->Width; t->height = d->Height; *pf = RGBA; *depth = 0;
    assert(d->SampleDesc.Count == 1 && d->DepthOrArraySize == 1 && d->MipLevels == 1);
    assert(d->Flags & D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET); return 1;
}
static obj_handle_t MTLTexture_newTextureView(obj_handle_t t, enum WMTPixelFormat pf, UINT kind,
    uint16_t level, uint16_t nlevel, uint16_t slice, uint16_t nslice, struct WMTTextureSwizzleChannels sw, uint64_t *id) {
    assert(t == 20 && pf && kind == 2 && nlevel == 1 && nslice == 1);
    assert(sw.r == 2 && sw.g == 3 && sw.b == 4 && sw.a == 5); *id = 1;
    view_level = level; view_slice = slice; views++; return fail_view ? 0 : 40;
}
static obj_handle_t MTLDevice_newTexture(obj_handle_t dev, struct WMTTextureInfo *t) {
    assert(dev == 1); created = *t; textures++; return fail_texture ? 0 : 100 + textures;
}
static void NSObject_release(obj_handle_t h) { assert(h); last_released = h; released++; }
static void exec_end(struct mad_exec *e) { (void)e; ended++; }
static void exec_flush_clear(struct mad_exec *e, int i) { assert(i == 0 && e->npend); e->npend--; }
static obj_handle_t MTLCommandBuffer_renderCommandEncoder(obj_handle_t cb, struct WMTRenderPassInfo *p) {
    assert(cb == 2 && ended); pass = *p; renders++; return fail_render ? 0 : 30;
}
static void exec_fence_render(struct mad_exec *e, obj_handle_t enc, int after) {
    assert(enc == 30 && e->npend == 0 && e->f6_natt == 2);
    assert(e->f6_att[0] && e->f6_att[1]); assert(after == (fences % 2)); fences++;
}
static void MTLCommandEncoder_endEncoding(obj_handle_t enc) { assert(enc == 30); }
static int exec_begin_blit(struct mad_exec *e) { assert(renders); e->benc = 50; return !fail_blit; }
static void MTLBlitCommandEncoder_encodeCommands(obj_handle_t enc, const struct wmtcmd_base *k) {
    assert(enc == 50); blit = *(const struct wmtcmd_blit_copy_from_texture_to_texture *)k; blits++;
}
static struct mad_cmd *mad_list_push(struct mad_list *l, int kind) { l->pushed++; l->cmd.kind = kind; return &l->cmd; }
static void list_CopyTextureRegion(ID3D12GraphicsCommandList *l, const D3D12_TEXTURE_COPY_LOCATION *a, UINT x, UINT y, UINT z,
                                  const D3D12_TEXTURE_COPY_LOCATION *b, const void *box) {
    assert(!x && !y && !z && !box && !l->pushed);
    assert(a->pResource && b->pResource && a->Type == 1 && b->Type == 1);
    assert(a->SubresourceIndex == 9 && b->SubresourceIndex == 5); copied++;
}
''' + function(SOURCE, "static UINT mad_pf_bytes(UINT pf) {") + function(SOURCE, "static obj_handle_t mad_resolve_view(") + function(SOURCE, "static void exec_resolve(") + function(SOURCE, "static void mad_subresource(") + function(SOURCE, "static void STDMETHODCALLTYPE list_ResolveSubresource(") + r'''
int main(void) {
    struct mad_device dev = {1}; struct mad_queue q = {&dev};
    struct mad_exec e = {.q = &q, .cb = 2, .npend = 2};
    struct mad_resource src = {.texture = 10, .width = 256, .height = 128, .samples = 4, .tex_pf = SRGBA,
                              .desc = {.MipLevels = 3}};
    struct mad_resource dst = {.texture = 20, .width = 128, .height = 64, .samples = 1, .tex_pf = SRGBA,
                              .desc = {.MipLevels = 4, .Flags = 1}};
    struct mad_list list = {0};
    list_ResolveSubresource(&list, &dst, 9, &src, 5, 0);
    assert(list.pushed == 1 && list.cmd.kind == MC_RESOLVE);
    assert(list.cmd.u.tt.dlevel == 1 && list.cmd.u.tt.dslice == 2);
    assert(list.cmd.u.tt.slevel == 2 && list.cmd.u.tt.sslice == 1);
    exec_resolve(&e, &list.cmd);
    assert(!e.skipped && !e.npend && e.wr_all && !e.f6_natt);
    assert(renders == 1 && fences == 2 && !textures && !blits);
    assert(pass.colors[0].texture == 10 && pass.colors[0].resolve_texture == 20);
    assert(pass.colors[0].level == 2 && pass.colors[0].slice == 1);
    assert(pass.colors[0].resolve_level == 1 && pass.colors[0].resolve_slice == 2);
    assert(pass.colors[0].load_action == 1 && pass.colors[0].store_action == 3);
    assert(pass.render_target_width == 64 && pass.render_target_height == 32 && pass.default_raster_sample_count == 4);
    dst.tex_pf = RGBA; // compatible linear/sRGB destination is viewed in source format
    exec_resolve(&e, &list.cmd);
    assert(views == 1 && released == 1 && last_released == 40);
    assert(view_level == 1 && view_slice == 2 && pass.colors[0].resolve_texture == 40);
    assert(!pass.colors[0].resolve_level && !pass.colors[0].resolve_slice);
    dst.desc.Flags = 0; // non-render-target destination needs an intermediate
    exec_resolve(&e, &list.cmd);
    assert(textures == 1 && created.width == 64 && created.height == 32 && created.pixel_format == SRGBA);
    assert(pass.colors[0].resolve_texture == dst.resolve_tmp && blits == 1);
    assert(blit.src == dst.resolve_tmp && blit.dst == 40 && !blit.dst_level && !blit.dst_slice);
    assert(blit.src_size.width == 64 && blit.src_size.height == 32 && blit.src_size.depth == 1);
    exec_resolve(&e, &list.cmd); assert(textures == 1); // same dimensions/format reuses it
    obj_handle_t old = dst.resolve_tmp;
    list.cmd.u.tt.slevel = 1;
    exec_resolve(&e, &list.cmd);
    assert(textures == 2 && old != dst.resolve_tmp && created.width == 128 && created.height == 64);
    src.tex_pf = RGBA; exec_resolve(&e, &list.cmd);
    assert(textures == 3 && dst.resolve_tmp_pf == RGBA && blit.dst == 20);
    assert(blit.dst_level == 1 && blit.dst_slice == 2);
    int before = renders; src.is_depth = 1; exec_resolve(&e, &list.cmd);
    assert(renders == before && e.skipped == 1); src.is_depth = 0;
    src.tex_pf = RGBA16; exec_resolve(&e, &list.cmd);
    assert(renders == before && e.skipped == 2); // incompatible format width
    src.tex_pf = SRGBA; fail_view = 1; exec_resolve(&e, &list.cmd);
    assert(renders == before && e.skipped == 3); fail_view = 0;
    NSObject_release(dst.resolve_tmp); dst.resolve_tmp = 0;
    int before_release = released;
    fail_texture = 1; exec_resolve(&e, &list.cmd);
    assert(renders == before && e.skipped == 4 && released == before_release + 1); fail_texture = 0;
    fail_render = 1; before_release = released; exec_resolve(&e, &list.cmd);
    assert(e.skipped == 5 && released == before_release + 1); fail_render = 0;
    fail_blit = 1; before_release = released; exec_resolve(&e, &list.cmd);
    assert(e.skipped == 6 && released == before_release + 1); fail_blit = 0;
    memset(&list, 0, sizeof list); src.samples = 1;
    list_ResolveSubresource(&list, &dst, 9, &src, 5, 0);
    assert(copied == 1 && !list.pushed);
    return 0;
}
'''
        run_c(code)

    def test_replay_vtable_census_and_resource_cleanup_are_wired(self):
        self.assertIn("case MC_RESOLVE: exec_resolve(&e, c); break;", SOURCE)
        self.assertIn("g_list_vtbl.ResolveSubresource      = (void *)list_ResolveSubresource;", SOURCE)
        self.assertIn("case MC_COPY_T2T: case MC_RESOLVE:", function(SOURCE, "static void f7_store_census("))
        self.assertIn("if (r->resolve_tmp) NSObject_release(r->resolve_tmp);",
                      function(SOURCE, "static ULONG STDMETHODCALLTYPE res_Release("))


if __name__ == "__main__":
    unittest.main()
