/* ml759: pack one winemetal render batch into the remote wire format.
 *
 * winemetal's wmtcmd_* list is linked through GUEST POINTERS and carries
 * further pointers for inline bytes, viewports and scissors. None of that
 * survives a machine boundary, so every pointer becomes an offset into a
 * sidecar region travelling with the records.
 *
 * Began as the 15 render opcodes an ARM64 D3D11 cube emits (measured, not
 * assumed: 28,800 records over 12,288 batches, zero compute,
 * zero blit. An unhandled opcode is a NAMED failure carrying the encoder kind,
 * the opcode and the record index, because "packing failed" one machine away
 * from the GPU is close to undebuggable.
 *
 * The walk is bounded and cycle-checked. A corrupt `next` chain would
 * otherwise spin here forever, which is the exact shape the FEX IR list
 * corruption took and it cost days to find.
 */
#ifndef WMT_REMOTE_PACK_H
#define WMT_REMOTE_PACK_H

#include "../../../../remote-metal/wmt_pack.h"
#include "winemetal.h"

static inline enum wmtw_pack_status
wmtw_pack_render(const struct wmtcmd_base *head, struct wmtw_packer *p,
                 struct wmtw_pack_result *res)
{
    /* Tortoise and hare. The tortoise must NOT advance on the first step:
     * starting both at head and advancing both immediately makes them equal
     * after one step, which reports every list of two or more nodes as
     * cyclic. */
    const struct wmtcmd_base *slow = head;
    int advance_slow = 0;
    uint32_t idx = 0;
    res->encoder_kind = 0;

#define FAIL(st) do { res->status = (st); res->record_index = idx; \
                      res->opcode = c ? c->type : 0xffffffffu; return (st); } while (0)
#define ALLOC(T, OP) struct wmtw_##T *w = wmtw_rec_alloc(p, sizeof *w, OP); \
                     if (!w) FAIL(WMTW_PACK_BUFFER_OVERFLOW)

    for (const struct wmtcmd_base *c = head; c; ) {
        if (idx >= WMTW_MAX_RECORDS) FAIL(WMTW_PACK_TOO_MANY_RECORDS);

        switch ((enum WMTRenderCommandType)c->type) {
        case WMTRenderCommandNop: { ALLOC(nop, WMTW_OP_Nop); (void)w; break; }

        case WMTRenderCommandUseResource: {
            const struct wmtcmd_render_useresource *b = (const void *)c;
            ALLOC(useresource, WMTW_OP_UseResource);
            w->resource = b->resource; w->usage = b->usage; w->stages = b->stages;
            break;
        }
        case WMTRenderCommandSetVertexBuffer: {
            const struct wmtcmd_render_setbuffer *b = (const void *)c;
            ALLOC(setvertexbuffer, WMTW_OP_SetVertexBuffer);
            w->buffer = b->buffer; w->offset = b->offset; w->index = b->index;
            break;
        }
        case WMTRenderCommandSetVertexBufferOffset: {
            const struct wmtcmd_render_setbufferoffset *b = (const void *)c;
            ALLOC(setvertexbufferoffset, WMTW_OP_SetVertexBufferOffset);
            w->offset = b->offset; w->index = b->index;
            break;
        }
        case WMTRenderCommandSetMeshBuffer: {
            const struct wmtcmd_render_setbuffer *b = (const void *)c;
            ALLOC(setmeshbuffer, WMTW_OP_SetMeshBuffer);
            w->buffer = b->buffer; w->offset = b->offset; w->index = b->index;
            break;
        }
        case WMTRenderCommandSetMeshBufferOffset: {
            const struct wmtcmd_render_setbufferoffset *b = (const void *)c;
            ALLOC(setmeshbufferoffset, WMTW_OP_SetMeshBufferOffset);
            w->offset = b->offset; w->index = b->index;
            break;
        }
        case WMTRenderCommandSetObjectBuffer: {
            const struct wmtcmd_render_setbuffer *b = (const void *)c;
            ALLOC(setobjectbuffer, WMTW_OP_SetObjectBuffer);
            w->buffer = b->buffer; w->offset = b->offset; w->index = b->index;
            break;
        }
        case WMTRenderCommandDrawMeshThreadgroups: {
            const struct wmtcmd_render_draw_meshthreadgroups *b = (const void *)c;
            ALLOC(drawmeshthreadgroups, WMTW_OP_DrawMeshThreadgroups);
            w->grid_w = b->threadgroup_per_grid.width;
            w->grid_h = b->threadgroup_per_grid.height;
            w->grid_d = b->threadgroup_per_grid.depth;
            w->obj_w  = b->object_threadgroup_size.width;
            w->obj_h  = b->object_threadgroup_size.height;
            w->obj_d  = b->object_threadgroup_size.depth;
            w->mesh_w = b->mesh_threadgroup_size.width;
            w->mesh_h = b->mesh_threadgroup_size.height;
            w->mesh_d = b->mesh_threadgroup_size.depth;
            w->pad = 0;
            break;
        }
        case WMTRenderCommandSetObjectBufferOffset: {
            const struct wmtcmd_render_setbufferoffset *b = (const void *)c;
            ALLOC(setobjectbufferoffset, WMTW_OP_SetObjectBufferOffset);
            w->offset = b->offset; w->index = b->index;
            break;
        }
        case WMTRenderCommandSetVisibilityMode: {
            const struct wmtcmd_render_setvisibilitymode *b = (const void *)c;
            ALLOC(setvisibilitymode, WMTW_OP_SetVisibilityMode);
            w->offset = b->offset; w->mode = (uint32_t)b->mode; w->pad = 0;
            break;
        }
        case WMTRenderCommandDrawIndexedIndirect: {
            const struct wmtcmd_render_draw_indexed_indirect *b = (const void *)c;
            ALLOC(drawindexedindirect, WMTW_OP_DrawIndexedIndirect);
            w->index_buffer = b->index_buffer;
            w->index_buffer_offset = b->index_buffer_offset;
            w->indirect_args_buffer = b->indirect_args_buffer;
            w->indirect_args_offset = b->indirect_args_offset;
            w->primitive_type = (uint32_t)b->primitive_type;
            w->index_type = (uint32_t)b->index_type;
            break;
        }
        case WMTRenderCommandSetFragmentBufferOffset: {
            const struct wmtcmd_render_setbufferoffset *b = (const void *)c;
            ALLOC(setfragmentbufferoffset, WMTW_OP_SetFragmentBufferOffset);
            w->offset = b->offset; w->index = b->index;
            break;
        }
        case WMTRenderCommandSetFragmentBuffer: {
            const struct wmtcmd_render_setbuffer *b = (const void *)c;
            ALLOC(setfragmentbuffer, WMTW_OP_SetFragmentBuffer);
            w->buffer = b->buffer; w->offset = b->offset; w->index = b->index;
            break;
        }
        case WMTRenderCommandSetFragmentTexture: {
            const struct wmtcmd_render_settexture *b = (const void *)c;
            ALLOC(setfragmenttexture, WMTW_OP_SetFragmentTexture);
            w->texture = b->texture; w->index = b->index;
            break;
        }
        case WMTRenderCommandSetFragmentBytes: {
            const struct wmtcmd_render_setbytes *b = (const void *)c;
            if (b->length > WMTW_MAX_SIDECAR_BYTES) FAIL(WMTW_PACK_SIDECAR_OVERFLOW);
            ALLOC(setfragmentbytes, WMTW_OP_SetFragmentBytes);
            w->index = b->index;
            w->bytes_offset = wmtw_side_put(p, b->bytes.ptr, (uint32_t)b->length);
            if (w->bytes_offset == 0xffffffffu) FAIL(WMTW_PACK_SIDECAR_OVERFLOW);
            w->bytes_count = (uint32_t)b->length;
            break;
        }
        case WMTRenderCommandSetRasterizerState: {
            const struct wmtcmd_render_setrasterizerstate *b = (const void *)c;
            ALLOC(setrasterizerstate, WMTW_OP_SetRasterizerState);
            w->front_facing = b->winding; w->cull_mode = b->cull_mode;
            w->fill_mode = b->fill_mode; w->depth_clip_mode = b->depth_clip_mode;
            w->depth_bias = b->depth_bias; w->slope_scale = b->scole_scale;
            w->depth_bias_clamp = b->depth_bias_clamp; w->pad0 = 0;
            break;
        }
        case WMTRenderCommandSetViewports: {
            const struct wmtcmd_render_setviewports *b = (const void *)c;
            if (b->viewport_count > WMTW_MAX_ARRAY_COUNT) FAIL(WMTW_PACK_BAD_ARRAY_COUNT);
            ALLOC(setviewports, WMTW_OP_SetViewports);
            uint32_t bytes = (uint32_t)b->viewport_count * (uint32_t)sizeof(struct wmtw_viewport);
            w->viewports_offset = wmtw_side_put(p, b->viewports.ptr, bytes);
            if (w->viewports_offset == 0xffffffffu) FAIL(WMTW_PACK_SIDECAR_OVERFLOW);
            w->viewports_count = b->viewport_count;
            break;
        }
        case WMTRenderCommandSetScissorRects: {
            const struct wmtcmd_render_setscissorrects *b = (const void *)c;
            if (b->rect_count > WMTW_MAX_ARRAY_COUNT) FAIL(WMTW_PACK_BAD_ARRAY_COUNT);
            ALLOC(setscissorrects, WMTW_OP_SetScissorRects);
            uint32_t bytes = (uint32_t)b->rect_count * (uint32_t)sizeof(struct wmtw_scissor);
            w->scissors_offset = wmtw_side_put(p, b->scissor_rects.ptr, bytes);
            if (w->scissors_offset == 0xffffffffu) FAIL(WMTW_PACK_SIDECAR_OVERFLOW);
            w->scissors_count = b->rect_count;
            break;
        }
        case WMTRenderCommandSetPSO: {
            const struct wmtcmd_render_setpso *b = (const void *)c;
            ALLOC(setpso, WMTW_OP_SetPSO); w->pso = b->pso; break;
        }
        case WMTRenderCommandSetDSSO: {
            const struct wmtcmd_render_setdsso *b = (const void *)c;
            ALLOC(setdsso, WMTW_OP_SetDSSO);
            w->dsso = b->dsso; w->stencil_ref = b->stencil_ref; w->pad0 = 0;
            break;
        }
        case WMTRenderCommandSetBlendFactorAndStencilRef: {
            const struct wmtcmd_render_setblendcolor *b = (const void *)c;
            ALLOC(setblendfactorandstencilref, WMTW_OP_SetBlendFactorAndStencilRef);
            w->r = b->red; w->g = b->green; w->b = b->blue; w->a = b->alpha;
            w->stencil_ref = b->stencil_ref; w->pad0 = 0;
            break;
        }
        case WMTRenderCommandDraw: {
            const struct wmtcmd_render_draw *b = (const void *)c;
            ALLOC(draw, WMTW_OP_Draw);
            w->primitive = b->primitive_type; w->start = b->vertex_start;
            w->count = b->vertex_count; w->instances = b->instance_count;
            w->base_instance = b->base_instance;
            break;
        }
        case WMTRenderCommandDrawIndexed: {
            const struct wmtcmd_render_draw_indexed *b = (const void *)c;
            ALLOC(drawindexed, WMTW_OP_DrawIndexed);
            w->primitive = b->primitive_type; w->index_count = b->index_count;
            w->index_type = b->index_type; w->index_buffer = b->index_buffer;
            w->index_offset = b->index_buffer_offset; w->instances = b->instance_count;
            w->base_vertex = (uint64_t)(int64_t)b->base_vertex;
            w->base_instance = b->base_instance;
            break;
        }
        /* ---- ml817: everything below was UNSUPPORTED in the first in-game run.
         * A batch containing one unsupported command is dropped WHOLE, so the
         * two geometry-shader draws alone removed 2,700+ batches: every draw in
         * them, on top of the record-cap drops. Nothing here is a new Metal
         * concept -- each one packs to what the native encoder does. */
        case WMTRenderCommandDrawIndirect: {
            const struct wmtcmd_render_draw_indirect *b = (const void *)c;
            ALLOC(drawindirect, WMTW_OP_DrawIndirect);
            w->indirect_buffer = b->indirect_args_buffer; w->indirect_offset = b->indirect_args_offset;
            w->primitive = (uint32_t)b->primitive_type; w->pad0 = 0;
            break;
        }
        case WMTRenderCommandDrawMeshThreadgroupsIndirect: {
            const struct wmtcmd_render_draw_meshthreadgroups_indirect *b = (const void *)c;
            ALLOC(drawmeshthreadgroupsindirect, WMTW_OP_DrawMeshThreadgroupsIndirect);
            w->indirect_buffer = b->indirect_args_buffer; w->indirect_offset = b->indirect_args_offset;
            w->obj_w = b->object_threadgroup_size.width;  w->obj_h = b->object_threadgroup_size.height;
            w->obj_d = b->object_threadgroup_size.depth;
            w->mesh_w = b->mesh_threadgroup_size.width;   w->mesh_h = b->mesh_threadgroup_size.height;
            w->mesh_d = b->mesh_threadgroup_size.depth;
            break;
        }
        case WMTRenderCommandMemoryBarrier: {
            const struct wmtcmd_render_memory_barrier *b = (const void *)c;
            ALLOC(memorybarrier, WMTW_OP_MemoryBarrier);
            w->scope = (uint32_t)b->scope; w->stages_after = (uint32_t)b->stages_after;
            w->stages_before = (uint32_t)b->stages_before; w->pad0 = 0;
            break;
        }
        /* Single viewport / scissor: the array forms with count 1. */
        case WMTRenderCommandSetViewport: {
            const struct wmtcmd_render_setviewport *b = (const void *)c;
            ALLOC(setviewports, WMTW_OP_SetViewports);
            struct wmtw_viewport v = { b->viewport.originX, b->viewport.originY, b->viewport.width,
                                       b->viewport.height, b->viewport.znear, b->viewport.zfar };
            uint32_t off = wmtw_side_put(p, &v, sizeof v);
            if (off == 0xffffffffu) FAIL(WMTW_PACK_SIDECAR_OVERFLOW);
            w->viewports_offset = off; w->viewports_count = 1;
            break;
        }
        case WMTRenderCommandSetScissorRect: {
            const struct wmtcmd_render_setscissorrect *b = (const void *)c;
            ALLOC(setscissorrects, WMTW_OP_SetScissorRects);
            struct wmtw_scissor sc = { b->scissor_rect.x, b->scissor_rect.y,
                                       b->scissor_rect.width, b->scissor_rect.height };
            uint32_t off = wmtw_side_put(p, &sc, sizeof sc);
            if (off == 0xffffffffu) FAIL(WMTW_PACK_SIDECAR_OVERFLOW);
            w->scissors_offset = off; w->scissors_count = 1;
            break;
        }
        /* DXMT geometry-shader emulation: an object/mesh pipeline whose draw
         * arguments sit in a buffer already bound at object index 21 (and the
         * index buffer at 20). Exactly what the native encoder issues. */
#define MESH_DRAW(GW, GH, OW, OH, MW) do { \
            ALLOC(drawmeshthreadgroups, WMTW_OP_DrawMeshThreadgroups); \
            w->grid_w = (GW); w->grid_h = (GH); w->grid_d = 1; \
            w->obj_w = (OW); w->obj_h = (OH); w->obj_d = 1; \
            w->mesh_w = (MW); w->mesh_h = 1; w->mesh_d = 1; w->pad = 0; } while (0)
#define OBJ_BUF(BUF, OFF, IDX) do { \
            ALLOC(setobjectbuffer, WMTW_OP_SetObjectBuffer); \
            w->buffer = (BUF); w->offset = (OFF); w->index = (IDX); } while (0)
#define OBJ_OFF(OFF, IDX) do { \
            ALLOC(setobjectbufferoffset, WMTW_OP_SetObjectBufferOffset); \
            w->offset = (OFF); w->index = (IDX); } while (0)
        case WMTRenderCommandDXMTGeometryDraw: {
            const struct wmtcmd_render_dxmt_geometry_draw *b = (const void *)c;
            { OBJ_OFF(b->draw_arguments_offset, 21); }
            { MESH_DRAW(b->warp_count, b->instance_count, b->vertex_per_warp, 1, 1); }
            break;
        }
        case WMTRenderCommandDXMTGeometryDrawIndexed: {
            const struct wmtcmd_render_dxmt_geometry_draw_indexed *b = (const void *)c;
            { OBJ_BUF(b->index_buffer, b->index_buffer_offset, 20); }
            { OBJ_OFF(b->draw_arguments_offset, 21); }
            { MESH_DRAW(b->warp_count, b->instance_count, b->vertex_per_warp, 1, 1); }
            break;
        }
        case WMTRenderCommandDXMTGeometryDrawIndirect: {
            const struct wmtcmd_render_dxmt_geometry_draw_indirect *b = (const void *)c;
            { OBJ_BUF(b->indirect_args_buffer, b->indirect_args_offset, 21); }
            { ALLOC(drawmeshthreadgroupsindirect, WMTW_OP_DrawMeshThreadgroupsIndirect);
              w->indirect_buffer = b->dispatch_args_buffer; w->indirect_offset = b->dispatch_args_offset;
              w->obj_w = b->vertex_per_warp; w->obj_h = 1; w->obj_d = 1;
              w->mesh_w = 1; w->mesh_h = 1; w->mesh_d = 1; }
            { OBJ_BUF(b->imm_draw_arguments, 0, 21); }
            break;
        }
        case WMTRenderCommandDXMTGeometryDrawIndexedIndirect: {
            const struct wmtcmd_render_dxmt_geometry_draw_indexed_indirect *b = (const void *)c;
            { OBJ_BUF(b->index_buffer, b->index_buffer_offset, 20); }
            { OBJ_BUF(b->indirect_args_buffer, b->indirect_args_offset, 21); }
            { ALLOC(drawmeshthreadgroupsindirect, WMTW_OP_DrawMeshThreadgroupsIndirect);
              w->indirect_buffer = b->dispatch_args_buffer; w->indirect_offset = b->dispatch_args_offset;
              w->obj_w = b->vertex_per_warp; w->obj_h = 1; w->obj_d = 1;
              w->mesh_w = 1; w->mesh_h = 1; w->mesh_d = 1; }
            { OBJ_BUF(b->imm_draw_arguments, 0, 21); }
            break;
        }
        /* DXMT tessellation emulation: same shape, mesh threadgroup of 32. */
        case WMTRenderCommandDXMTTessellationMeshDraw: {
            const struct wmtcmd_render_dxmt_tessellation_mesh_draw *b = (const void *)c;
            { OBJ_OFF(b->draw_arguments_offset, 21); }
            { MESH_DRAW(b->patch_per_mesh_instance, b->instance_count, b->threads_per_patch, b->patch_per_group, 32); }
            break;
        }
        case WMTRenderCommandDXMTTessellationMeshDrawIndexed: {
            const struct wmtcmd_render_dxmt_tessellation_mesh_draw_indexed *b = (const void *)c;
            { OBJ_BUF(b->index_buffer, b->index_buffer_offset, 20); }
            { OBJ_OFF(b->draw_arguments_offset, 21); }
            { MESH_DRAW(b->patch_per_mesh_instance, b->instance_count, b->threads_per_patch, b->patch_per_group, 32); }
            break;
        }
        case WMTRenderCommandDXMTTessellationMeshDrawIndirect: {
            const struct wmtcmd_render_dxmt_tessellation_mesh_draw_indirect *b = (const void *)c;
            { OBJ_BUF(b->indirect_args_buffer, b->indirect_args_offset, 21); }
            { ALLOC(drawmeshthreadgroupsindirect, WMTW_OP_DrawMeshThreadgroupsIndirect);
              w->indirect_buffer = b->dispatch_args_buffer; w->indirect_offset = b->dispatch_args_offset;
              w->obj_w = b->threads_per_patch; w->obj_h = b->patch_per_group; w->obj_d = 1;
              w->mesh_w = 32; w->mesh_h = 1; w->mesh_d = 1; }
            { OBJ_BUF(b->imm_draw_arguments, 0, 21); }
            break;
        }
        case WMTRenderCommandDXMTTessellationMeshDrawIndexedIndirect: {
            const struct wmtcmd_render_dxmt_tessellation_mesh_draw_indexed_indirect *b = (const void *)c;
            { OBJ_BUF(b->index_buffer, b->index_buffer_offset, 20); }
            { OBJ_BUF(b->indirect_args_buffer, b->indirect_args_offset, 21); }
            { ALLOC(drawmeshthreadgroupsindirect, WMTW_OP_DrawMeshThreadgroupsIndirect);
              w->indirect_buffer = b->dispatch_args_buffer; w->indirect_offset = b->dispatch_args_offset;
              w->obj_w = b->threads_per_patch; w->obj_h = b->patch_per_group; w->obj_d = 1;
              w->mesh_w = 32; w->mesh_h = 1; w->mesh_d = 1; }
            { OBJ_BUF(b->imm_draw_arguments, 0, 21); }
            break;
        }
#undef MESH_DRAW
#undef OBJ_BUF
#undef OBJ_OFF
        default:
            /* Name it. A title needing a new command family should say which
             * one, not fail anonymously on the far side of the wire. */
            FAIL(WMTW_PACK_UNSUPPORTED_OP);
        }

        c = (const struct wmtcmd_base *)c->next.ptr;
        idx++;
        if (advance_slow && slow) slow = (const struct wmtcmd_base *)slow->next.ptr;
        advance_slow = !advance_slow;
        if (c && c == slow) { res->status = WMTW_PACK_CYCLE; res->record_index = idx;
                              res->opcode = c->type; return WMTW_PACK_CYCLE; }
    }
#undef FAIL
#undef ALLOC
    res->status = WMTW_PACK_OK;
    res->record_bytes = p->rec_len;
    res->record_count = p->count;
    res->sidecar_bytes = p->side_len;
    return WMTW_PACK_OK;
}

#endif
