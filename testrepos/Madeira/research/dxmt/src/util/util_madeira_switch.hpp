/*
 * util_madeira_switch.hpp -- the default for Madeira's behaviour switches.
 *
 * Madeira adds a 32-bit (WoW64) path to this tree. Behaviour changes made for
 * that path must not change what a 64-bit (arm64ec / aarch64) module does by
 * default, because the 64-bit engine is tested separately. So every such
 * change sits behind a switch that is:
 *
 *   - ON by default in a module that only ever serves 32-bit processes
 *     (the i386 PE build, and the native D3D9 frontend built with
 *     DXMT_MADEIRA);
 *   - OFF by default everywhere else, which keeps upstream behaviour;
 *   - forced either way by its environment variable: "0" disables it on every
 *     architecture, any other non-empty value enables it on every
 *     architecture.
 *
 * Copyright 2026 125hz
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
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#include "util_env.hpp"

#include <string>

namespace dxmt {

/* True in a module that only ever serves 32-bit (WoW64) processes: the i386
 * PE build, and the native ARM64 Direct3D 9 frontend (DXMT_MADEIRA), which
 * only ever runs behind the i386 d3d9 shim. */
constexpr bool kMadeira32BitModule =
#if defined(__i386__) || defined(DXMT_MADEIRA)
    true;
#else
    false;
#endif

/* Is the Madeira behaviour behind environment variable `name` enabled?
 * Unset or empty: kMadeira32BitModule. "0": no. Anything else: yes. */
inline bool
madeiraSwitch(const char *name) {
  const std::string value = env::getEnvVar(name);
  if (value.empty())
    return kMadeira32BitModule;
  return value != "0";
}

} // namespace dxmt
