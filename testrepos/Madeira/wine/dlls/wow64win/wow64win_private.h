/*
 * WoW64 private definitions
 *
 * Copyright 2021 Alexandre Julliard
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

#ifndef __WOW64WIN_PRIVATE_H
#define __WOW64WIN_PRIVATE_H

#include "../win32u/win32syscalls.h"
#include "ntuser.h"

#define SYSCALL_ENTRY(id,name,_args) extern NTSTATUS WINAPI wow64_ ## name( UINT *args );
ALL_SYSCALLS32
#undef SYSCALL_ENTRY

extern ntuser_callback user_callbacks[];

struct object_attr64
{
    OBJECT_ATTRIBUTES   attr;
    UNICODE_STRING      str;
    SECURITY_DESCRIPTOR sd;
};

typedef struct
{
    ULONG Length;
    ULONG RootDirectory;
    ULONG ObjectName;
    ULONG Attributes;
    ULONG SecurityDescriptor;
    ULONG SecurityQualityOfService;
} OBJECT_ATTRIBUTES32;

/* WoW64 guest window — see wow64/wow64_private.h.
 *
 * wow64win.dll does the same guest<->host pointer conversions as wow64.dll
 * and needs the same B.  It is a separate module with no data import from
 * wow64.dll, so it reads B from the same single source of truth
 * (NtQueryInformationProcess) the first time a conversion happens.  B is 0 on
 * every build that keeps the classic WoW64 identity, and with B == 0 both
 * helpers are exactly the UlongToPtr/PtrToUlong they replace.
 *
 * Rules are identical: only ADDRESSES convert; handles (HWND, HIMC, HKL, ...)
 * and offsets-from-struct-start never do. */
static inline ULONG_PTR wow64win_guest_base(void)
{
    static ULONG_PTR cached = ~(ULONG_PTR)0;   /* ~0 = not queried yet */

    if (cached == ~(ULONG_PTR)0)
    {
        ULONG_PTR base = 0;

        if (NtQueryInformationProcess( GetCurrentProcess(), ProcessWineIosWowGuestBase,
                                       &base, sizeof(base), NULL ))
            base = 0;
        cached = base;
    }
    return cached;
}

/* guest 32-bit address -> host pointer.  NULL stays NULL. */
static inline void *guest_ptr32( ULONG addr )
{
    return addr ? (void *)(wow64win_guest_base() + addr) : NULL;
}

/* host pointer -> guest 32-bit address.  NULL stays 0. */
static inline ULONG host_ptr32( const void *addr )
{
    return addr ? (ULONG)((ULONG_PTR)addr - wow64win_guest_base()) : 0;
}

static inline ULONG get_ulong( UINT **args ) { return *(*args)++; }
static inline HANDLE get_handle( UINT **args ) { return LongToHandle( *(*args)++ ); }
static inline void *get_ptr( UINT **args ) { return guest_ptr32( *(*args)++ ); }

/* iOS-Madeira: AN ATOM IS NOT A POINTER, AND ON THIS PORT THE DIFFERENCE
 * IS FATAL.
 *
 * A few win32u entry points take an argument that is EITHER a string pointer OR
 * a MAKEINTATOM value, told apart downstream by IS_INTRESOURCE(), i.e.
 * ((ULONG_PTR)x >> 16) == 0.  Upstream's guest_ptr32() is the identity on a
 * 32-bit value, so an atom survives get_ptr() unchanged and the test still
 * works.  Here guest_ptr32() ADDS THE WINDOW BASE, so an atom such as 0xc01a
 * arrives as 0x72000000c01a; IS_INTRESOURCE() is then false, the callee takes
 * the string branch, and lstrlenW() walks the reserved-but-uncommitted low
 * megabyte of the guest window until it faults.
 *
 * Observed as a silent 0xC0000005 in every themed installer: the crash is inside
 * NtUserSetProp+0x4c / NtUserGetProp+0x50 on `ldrh w,[x],#2` — the inlined
 * lstrlenW — reached from NtUserCreateWindowEx -> WM_NCCREATE, because a themed
 * or rich-edit control stores its per-window state under an atom during
 * creation.  It kills the process outright because the fault happens on a
 * KeUserModeCallback stack that the SEH dispatcher then refuses
 * ("Exception frame is not in stack limits").
 *
 * So: pass an INTRESOURCE through untranslated.  Nothing is lost — a real
 * pointer below 64 KB cannot exist in a Windows process either, which is the
 * assumption IS_INTRESOURCE itself is built on. */
static inline void *get_str_or_atom( UINT **args )
{
    ULONG v = *(*args)++;

    if (!v || (v >> 16)) return guest_ptr32( v );
    return (void *)(ULONG_PTR)v;
}

static inline void **addr_32to64( void **addr, ULONG *addr32 )
{
    if (!addr32) return NULL;
    *addr = guest_ptr32( *addr32 );
    return addr;
}

static inline SIZE_T *size_32to64( SIZE_T *size, ULONG *size32 )
{
    if (!size32) return NULL;
    *size = *size32;
    return size;
}

static inline void put_addr( ULONG *addr32, void *addr )
{
    if (addr32) *addr32 = host_ptr32( addr );
}

static inline void put_size( ULONG *size32, SIZE_T size )
{
    if (size32) *size32 = min( size, MAXDWORD );
}

static inline UNICODE_STRING *unicode_str_32to64( UNICODE_STRING *str, const UNICODE_STRING32 *str32 )
{
    if (!str32) return NULL;
    str->Length = str32->Length;
    str->MaximumLength = str32->MaximumLength;
    str->Buffer = guest_ptr32( str32->Buffer );
    return str;
}

static inline SECURITY_DESCRIPTOR *secdesc_32to64( SECURITY_DESCRIPTOR *out, const SECURITY_DESCRIPTOR *in )
{
    /* relative descr has the same layout for 32 and 64 */
    const SECURITY_DESCRIPTOR_RELATIVE *sd = (const SECURITY_DESCRIPTOR_RELATIVE *)in;

    if (!in) return NULL;
    out->Revision = sd->Revision;
    out->Sbz1     = sd->Sbz1;
    out->Control  = sd->Control & ~SE_SELF_RELATIVE;
    if (sd->Control & SE_SELF_RELATIVE)
    {
        if (sd->Owner) out->Owner = (PSID)((BYTE *)sd + sd->Owner);
        if (sd->Group) out->Group = (PSID)((BYTE *)sd + sd->Group);
        if ((sd->Control & SE_SACL_PRESENT) && sd->Sacl) out->Sacl = (PSID)((BYTE *)sd + sd->Sacl);
        if ((sd->Control & SE_DACL_PRESENT) && sd->Dacl) out->Dacl = (PSID)((BYTE *)sd + sd->Dacl);
    }
    else
    {
        /* absolute descriptor: real guest pointers (the self-relative branch
         * above uses offsets and must stay untouched) */
        out->Owner = guest_ptr32( sd->Owner );
        out->Group = guest_ptr32( sd->Group );
        if (sd->Control & SE_SACL_PRESENT) out->Sacl = guest_ptr32( sd->Sacl );
        if (sd->Control & SE_DACL_PRESENT) out->Dacl = guest_ptr32( sd->Dacl );
    }
    return out;
}

static inline OBJECT_ATTRIBUTES *objattr_32to64( struct object_attr64 *out, const OBJECT_ATTRIBUTES32 *in )
{
    memset( out, 0, sizeof(*out) );
    if (!in) return NULL;
    if (in->Length != sizeof(*in)) return &out->attr;

    out->attr.Length = sizeof(out->attr);
    out->attr.RootDirectory = LongToHandle( in->RootDirectory );
    out->attr.Attributes = in->Attributes;
    out->attr.ObjectName = unicode_str_32to64( &out->str, guest_ptr32( in->ObjectName ));
    out->attr.SecurityQualityOfService = guest_ptr32( in->SecurityQualityOfService );
    out->attr.SecurityDescriptor = secdesc_32to64( &out->sd, guest_ptr32( in->SecurityDescriptor ));
    return &out->attr;
}

static inline void set_last_error32( DWORD err )
{
    TEB *teb = NtCurrentTeb();
    TEB32 *teb32 = (TEB32 *)((char *)teb + teb->WowTebOffset);
    teb32->LastErrorValue = err;
}

#endif /* __WOW64WIN_PRIVATE_H */
