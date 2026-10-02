/*
 * d3d9shim_fpu.c -- setupFpu(), moved into the shim
 *
 * MUST-NOT-FORGET item of WOW64_DESIGN.md 8.2(b): D3D9 reprograms the x87 FPU
 * at device creation, and it has to happen on the GUEST's creating thread --
 * the native ARM64 frontend has no x87 word to set, so leaving this behind
 * would be a silent CPU-math change for every 32-bit title (8.9-3a).
 *
 * PROVENANCE: the body of d3d9shim_setup_fpu() below is moved VERBATIM from
 * research/dxmt/src/d3d9/d3d9_device.cpp (static setupFpu(), the block the
 * design calls `d3d9_device.cpp:512-521`), which was imported from
 * dacevedo12/dxmt v0.4-d3d9 under LGPL-2.1-or-later (COPYING.LIB); that
 * tree's own comment says the routine was ported from Wine's wined3d
 * setup_fpu and DXVK's SetupFPU.  The moved block keeps its licence; the
 * rest of this file is GPL-3.0-or-later.  See research/dxmt/LICENSE-MADEIRA.md.
 *
 * Moved block: written by David Acevedo for the Direct3D 9 frontend of
 * https://github.com/dacevedo12/dxmt (tag v0.4-d3d9, commit e8dd4c65), a DXMT
 * fork distributed under LGPL-2.1-or-later (COPYING.LIB).
 * Everything else: Copyright 2026 125hz
 *
 * This program is free software: you can redistribute it and/or modify it
 * under the terms of the GNU General Public License as published by the Free
 * Software Foundation, either version 3 of the License, or (at your option)
 * any later version.
 *
 * This program is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
 * or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
 * for more details.
 *
 * You should have received a copy of the GNU General Public License along
 * with this program.  If not, see <https://www.gnu.org/licenses/>.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later AND LGPL-2.1-or-later
 */

#include "d3d9shim_object.h"

/* D3D9 reprograms the x87 FPU at device creation (unless D3DCREATE_FPU_PRESERVE):
 * single precision (24-bit mantissa), all exceptions masked, round-to-nearest.
 * 32-bit games carry their float math on x87, so without this their CPU-side
 * work (culling, LOD, exposure / tonemap divisors, matrix prep) runs at the
 * default extended precision and diverges from Windows. Ported from wined3d
 * device.c setup_fpu and DXVK SetupFPU; the mask is identical, (cw & 0xf0c0) |
 * 0x003f. x86 only: SSE-compiled x86_64 code ignores the x87 word, but native
 * reprograms it there too (the conformance suite expects that on 64-bit). */
void
d3d9shim_setup_fpu(void)
{
#if defined(__i386__) || (defined(__x86_64__) && !defined(__arm64ec__))
    uint16_t control;

    __asm__ __volatile__("fnstcw %0" : "=m"(*&control));
    control &= 0xf0c0;
    control |= 0x003f;
    __asm__ __volatile__("fldcw %0" : : "m"(*&control));
#endif
}
