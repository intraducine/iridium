/* Offline candidate for Wine's import binder, not FEX code.
 * Input is a mapped PE image (RVA == byte offset), not the on-disk file.
 * Pure, bounded, allocation-free classification; no writes or instruction execution.
 * Integrate by preserving find_*_export's result for a selected primary-IAT slot.
 */
#include <stdint.h>
#include <stddef.h>
#include <string.h>

static int inside(size_t size, uint64_t at, uint64_t length)
{
    return at <= size && length <= size - at;
}

static uint32_t read_u32(const unsigned char *p)
{
    uint32_t value;
    memcpy(&value, p, sizeof(value));
    return value;
}

int arm64ec_iat_slot_is_x64_export(const void *module, size_t size,
                                   uint32_t slot, uint32_t exports,
                                   uint32_t export_size, uint32_t code_map,
                                   uint32_t code_count)
{
    const unsigned char *image = module;
    uint32_t count, functions, i, j;

    if (!image || (slot & 7) || !inside(size, slot, 8) ||
        export_size < 40 || !inside(size, exports, export_size) ||
        !code_count || !inside(size, code_map, (uint64_t)code_count * 8))
        return 0;

    count = read_u32(image + exports + 20);
    functions = read_u32(image + exports + 28);
    if (!inside(size, functions, (uint64_t)count * 4)) return 0;

    for (i = 0; i < count; ++i)
    {
        uint32_t rva = read_u32(image + functions + (size_t)i * 4);
        int32_t displacement;
        int64_t target;

        if (!rva || !inside(size, rva, 6)) continue;
        /* EAT entries within the export directory are strings, not code. */
        if (rva >= exports && (uint64_t)rva < (uint64_t)exports + export_size) continue;
        if (image[rva] != 0xff || image[rva + 1] != 0x25) continue;
        memcpy(&displacement, image + rva + 2, sizeof(displacement));
        target = (int64_t)rva + 6 + displacement;
        if (target != slot) continue;

        /* Do not mistake ARM64 bytes or arbitrary data for x64 instructions. */
        for (j = 0; j < code_count; ++j)
        {
            uint32_t start = read_u32(image + code_map + (size_t)j * 8);
            uint32_t length = read_u32(image + code_map + (size_t)j * 8 + 4);
            if ((start & 3) != 2) continue;
            start &= ~3u;
            if (!inside(size, start, length)) continue;
            if (rva >= start && (uint64_t)rva + 6 <= (uint64_t)start + length) return 1;
        }
    }
    return 0;
}
