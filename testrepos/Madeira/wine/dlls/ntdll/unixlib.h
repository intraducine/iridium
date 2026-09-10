/*
 * Ntdll Unix interface
 *
 * Copyright (C) 2020 Alexandre Julliard
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public
 * License as published by the Free Software Foundation; either
 * version 3 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * General Public License for more details.
 *
 * You should have received a copy of the GNU General Public
 * License along with this library; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301, USA
 */

#ifndef __NTDLL_UNIXLIB_H
#define __NTDLL_UNIXLIB_H

#include "wine/unixlib.h"

struct _DISPATCHER_CONTEXT;

struct wine_dbg_write_params
{
    const char  *str;
    unsigned int len;
};

struct wine_server_fd_to_handle_params
{
    int          fd;
    unsigned int access;
    unsigned int attributes;
    HANDLE      *handle;
};

struct wine_server_handle_to_fd_params
{
    HANDLE        handle;
    unsigned int  access;
    int          *unix_fd;
    unsigned int *options;
};

struct wine_spawnvp_params
{
    char       **argv;
    int          wait;
};

struct load_so_dll_params
{
    UNICODE_STRING              nt_name;
    void                      **module;
};

struct unwind_builtin_dll_params
{
    ULONG                       type;
    struct _DISPATCHER_CONTEXT *dispatch;
    CONTEXT                    *context;
};

/* iOS only: push the iOS JIT-pool alias table to FEX/xtajit64. Wine
 * ntdll-unix knows the (PE_base, JIT_alias_base, size) tuples for every
 * ARM64EC PE image that got copied into the JIT pool (required because
 * iOS rejects mprotect(RX) on file-backed mmaps). PE-side ntdll calls
 * this after binding xtajit64's BTCpu64IosAddAliasMapping export so FEX
 * can resolve alias addresses as executable. */
struct ios_push_jit_aliases_params
{
    void (*callback)(unsigned long long pe_base,
                     unsigned long long jit_base,
                     unsigned long long size);
};

/* iOS-Madeira ml618: register the per-pseudo-process leaked-hold release callback.
 *
 * A NEW ordinal with its own size/version, deliberately NOT an extension of
 * ios_push_jit_aliases_params: an old one-field caller gives the callee no way
 * to discover whether trailing bytes exist, so retrofitting a version field onto
 * that struct would itself be an out-of-bounds read (that bug shipped once —
 * ml549's rip_from_hostpc — and was removed in ml613).
 *
 * callback MUST be the arm64ec_redirect_ptr()-resolved pointer. */
struct ios_register_hold_release_params
{
    unsigned int size;      /* sizeof(struct) — set by caller, checked by callee */
    unsigned int version;   /* 1 */
    void *peb;              /* selects the pseudo-process this callback serves */
    void *callback;         /* uint32_t (*)(void *teb, uint64_t*, uint32_t*, uint32_t*) */
};

/* iOS-Madeira ml631: read-only probe of the anon-JIT alias table.
 *
 * Given a guest address inside a Mono JIT buffer, hand back the RW alias so the
 * PE side can read the SAME bytes through both views and compare them. That
 * separates "the guest x86 really is this" from "the RX and RW views disagree"
 * (alias coherency / finalisation) without another device run. */
struct ios_jit_alias_probe_params
{
    unsigned int size;        /* sizeof(struct) — set by caller, checked by callee */
    unsigned int version;     /* 1 */
    unsigned long long addr;  /* IN:  guest address to resolve */
    unsigned long long rw;    /* OUT: RW alias for addr, or 0 if not aliased */
    unsigned long long base;  /* OUT: alias user_va base, or 0 */
    unsigned long long end;   /* OUT: alias user_va end, or 0 */
    unsigned int write_gen;   /* OUT: ml635 emulated-write count for this alias */
    unsigned int written;     /* OUT: ml635 bit per 16KB chunk ever written */
    unsigned long long highest;/* OUT: ml636 highest offset ever written, +1 */
    unsigned int at_end;      /* OUT: ml636 1 = addr is exactly this alias's END */
    unsigned long long rw_base;/* OUT: ml639 alias jit_rw_alias BASE (never offset) */
    unsigned long long rx_base;/* OUT: ml639 alias jit_rx_alias BASE (never offset) */
    unsigned int slot;        /* OUT: ml639 matched table slot index */
    unsigned int dup_end;     /* OUT: ml639 live entries sharing this end */
};

enum ntdll_unix_funcs
{
    unix_load_so_dll,
    unix_unwind_builtin_dll,
    unix_wine_dbg_write,
    unix_wine_server_call,
    unix_wine_server_fd_to_handle,
    unix_wine_server_handle_to_fd,
    unix_wine_spawnvp,
    unix_system_time_precise,
    unix_ios_push_jit_aliases,
    /* ml618: APPEND ONLY — inserting anywhere above renumbers every existing
     * ordinal and silently mismatches the PE and unix halves. */
    unix_ios_register_hold_release,
    unix_ios_jit_alias_probe,   /* ml631 — APPEND ONLY (see note above) */
    unix_ios_mono_bridge_ptr,   /* ml648 — APPEND ONLY: inserting renumbers every later ordinal */
};

extern unixlib_handle_t __wine_unixlib_handle;

#endif /* __NTDLL_UNIXLIB_H */
