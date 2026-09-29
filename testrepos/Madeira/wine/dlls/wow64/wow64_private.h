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

#ifndef __WOW64_PRIVATE_H
#define __WOW64_PRIVATE_H

#include "../ntdll/ntsyscalls.h"
#include "struct32.h"

#define SYSCALL_ENTRY(id,name,_args) extern NTSTATUS WINAPI wow64_ ## name( UINT *args );
ALL_SYSCALLS32
#undef SYSCALL_ENTRY

extern void init_image_mapping( HMODULE module );
extern void init_file_redirects(void);
extern BOOL get_file_redirect( OBJECT_ATTRIBUTES *attr );

extern USHORT native_machine;
extern USHORT current_machine;
extern ULONG_PTR args_alignment;
extern ULONG_PTR highest_user_address;
extern ULONG_PTR default_zero_bits;

/* WoW64 guest window.
 *
 * Classic WoW64 assumes guest address == host address for everything the
 * 32-bit side can see.  On the iOS port that identity is impossible (XNU's
 * mandatory 4 GB __PAGEZERO), so each 32-bit process owns a reserved host
 * range [B, B+4G) and guest address `a` lives at host `B + a`.
 *
 * B is read ONCE at process init from
 * NtQueryInformationProcess( ProcessWineIosWowGuestBase ).  It is 0 on every
 * platform that keeps the classic identity, and with B == 0 both helpers
 * below are byte-for-byte the ULongToPtr/PtrToUlong they replace — so the
 * native WoW64 paths are unchanged.
 *
 * Rules:
 *  - only ADDRESSES convert.  Handles, sizes, flags, packed APC parameters,
 *    the IOSB Pointer cookie and self-relative security-descriptor offsets
 *    are never offset.
 *  - NULL/0 converts to NULL/0 in both directions.
 *  - a ceiling the guest sends down (zero_bits, MEM_ADDRESS_REQUIREMENTS) is
 *    a GUEST-namespace number and is passed through untouched; the unix side
 *    translates it into the window.
 *  - cross-process operations use the TARGET process's B, never ours; see
 *    wow_guest_base_for_process().
 */
extern ULONG_PTR wow_guest_base;

/* guest 32-bit address -> host pointer.  NULL stays NULL. */
static inline void *guest_ptr32( ULONG addr )
{
    return addr ? (void *)(wow_guest_base + addr) : NULL;
}

/* host pointer -> guest 32-bit address.  NULL stays 0. */
static inline ULONG host_ptr32( const void *addr )
{
    return addr ? (ULONG)((ULONG_PTR)addr - wow_guest_base) : 0;
}

/* the same pair for another process's window (cross-process VM ops) */
extern ULONG_PTR wow_guest_base_for_process( HANDLE process );

static inline void *guest_ptr32_in( ULONG_PTR base, ULONG addr )
{
    return addr ? (void *)(base + addr) : NULL;
}

static inline ULONG host_ptr32_in( ULONG_PTR base, const void *addr )
{
    return addr ? (ULONG)((ULONG_PTR)addr - base) : 0;
}

/* Re-target a pointer that get_ptr() already converted with OUR window but
 * which actually lives in `base`'s address space.  Used where one syscall
 * mixes both (NtReadVirtualMemory: addr is the target's, buffer is ours). */
static inline void *retarget_ptr( ULONG_PTR base, void *addr )
{
    if (!addr || base == wow_guest_base) return addr;
    return (void *)(base + ((ULONG_PTR)addr - wow_guest_base));
}

extern SYSTEM_DLL_INIT_BLOCK *pLdrSystemDllInitBlock;

extern void     (WINAPI *pBTCpuFlushInstructionCache2)( const void *, SIZE_T );
extern void     (WINAPI *pBTCpuFlushInstructionCacheHeavy)( const void *, SIZE_T );
extern NTSTATUS (WINAPI *pBTCpuNotifyMapViewOfSection)( void *, void *, void *, SIZE_T, ULONG, ULONG );
extern void     (WINAPI *pBTCpuNotifyMemoryAlloc)( void *, SIZE_T, ULONG, ULONG, BOOL, NTSTATUS );
extern void     (WINAPI *pBTCpuNotifyMemoryDirty)( void *, SIZE_T );
extern void     (WINAPI *pBTCpuNotifyMemoryFree)( void *, SIZE_T, ULONG, BOOL, NTSTATUS );
extern void     (WINAPI *pBTCpuNotifyMemoryProtect)( void *, SIZE_T, ULONG, BOOL, NTSTATUS );
extern void     (WINAPI *pBTCpuNotifyProcessExecuteFlagsChange)( ULONG );
extern void     (WINAPI *pBTCpuNotifyReadFile)( HANDLE, void *, SIZE_T, BOOL, NTSTATUS );
extern void     (WINAPI *pBTCpuNotifyUnmapViewOfSection)( void *, BOOL, NTSTATUS );
extern void     (WINAPI *pBTCpuUpdateProcessorInformation)( SYSTEM_CPU_INFORMATION * );
extern void     (WINAPI *pBTCpuProcessTerm)( HANDLE, BOOL, NTSTATUS );
extern void     (WINAPI *pBTCpuThreadTerm)( HANDLE, LONG );

struct object_attr64
{
    OBJECT_ATTRIBUTES   attr;
    UNICODE_STRING      str;
    SECURITY_DESCRIPTOR sd;
};

/* cf. GetSystemWow64Directory2 */
static inline const WCHAR *get_machine_wow64_dir( USHORT machine )
{
    switch (machine)
    {
    case IMAGE_FILE_MACHINE_TARGET_HOST: return L"\\??\\C:\\windows\\system32";
    case IMAGE_FILE_MACHINE_I386:        return L"\\??\\C:\\windows\\syswow64";
    case IMAGE_FILE_MACHINE_ARMNT:       return L"\\??\\C:\\windows\\sysarm32";
    default: return NULL;
    }
}

static inline TEB32 *NtCurrentTeb32(void)
{
    return (TEB32 *)((char *)NtCurrentTeb() + NtCurrentTeb()->WowTebOffset);
}

static inline ULONG get_ulong( UINT **args ) { return *(*args)++; }
static inline HANDLE get_handle( UINT **args ) { return LongToHandle( *(*args)++ ); }
static inline void *get_ptr( UINT **args ) { return guest_ptr32( *(*args)++ ); }

static inline ULONG64 get_ulong64( UINT **args )
{
    ULONG64 ret;

    *args = (UINT *)(((ULONG_PTR)*args + args_alignment - 1) & ~(args_alignment - 1));
    ret = *(ULONG64 *)*args;
    *args += 2;
    return ret;
}

/* NOT window-converted: zero_bits is a GUEST-namespace ceiling all the way
 * down.  The unix side turns [0, L] into the host range [B, B+L] itself, and
 * default_zero_bits comes from the guest HighestUserAddress that
 * virtual_get_system_info still reports. */
static inline ULONG_PTR get_zero_bits( ULONG_PTR zero_bits )
{
    return zero_bits ? zero_bits : default_zero_bits;
}

static inline void **addr_32to64( void **addr, ULONG *addr32 )
{
    if (!addr32) return NULL;
    *addr = guest_ptr32( *addr32 );
    return addr;
}

/* addr_32to64 for an address in another process's window */
static inline void **addr_32to64_in( ULONG_PTR base, void **addr, ULONG *addr32 )
{
    if (!addr32) return NULL;
    *addr = guest_ptr32_in( base, *addr32 );
    return addr;
}

static inline SIZE_T *size_32to64( SIZE_T *size, ULONG *size32 )
{
    if (!size32) return NULL;
    *size = *size32;
    return size;
}

static inline void *apc_32to64( ULONG func )
{
    return func ? Wow64ApcRoutine : NULL;
}

/* NOT window-converted: this is a PACKED value (the 32-bit APC routine in the
 * high half, its opaque context in the low half), not an address — see
 * Wow64ApcRoutine, which unpacks it again. */
static inline void *apc_param_32to64( ULONG func, ULONG context )
{
    if (!func) return ULongToPtr( context );
    return (void *)(ULONG_PTR)(((ULONG64)func << 32) | context);
}

/* NOT window-converted: io->Pointer is a HOST-only cookie that put_iosb and
 * set_async_iosb compare against and dereference; it never reaches guest
 * code. */
static inline IO_STATUS_BLOCK *iosb_32to64( IO_STATUS_BLOCK *io, IO_STATUS_BLOCK32 *io32 )
{
    if (!io32) return NULL;
    io->Pointer = io32;
    return io;
}

static inline UNICODE_STRING *unicode_str_32to64( UNICODE_STRING *str, const UNICODE_STRING32 *str32 )
{
    if (!str32) return NULL;
    str->Length = str32->Length;
    str->MaximumLength = str32->MaximumLength;
    str->Buffer = guest_ptr32( str32->Buffer );
    return str;
}

static inline CLIENT_ID *client_id_32to64( CLIENT_ID *id, const CLIENT_ID32 *id32 )
{
    if (!id32) return NULL;
    id->UniqueProcess = LongToHandle( id32->UniqueProcess );
    id->UniqueThread = LongToHandle( id32->UniqueThread );
    return id;
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
        out->Owner = sd->Owner ? (PSID)((BYTE *)sd + sd->Owner) : NULL;
        out->Group = sd->Group ? (PSID)((BYTE *)sd + sd->Group) : NULL;
        out->Sacl = ((sd->Control & SE_SACL_PRESENT) && sd->Sacl) ? (PSID)((BYTE *)sd + sd->Sacl) : NULL;
        out->Dacl = ((sd->Control & SE_DACL_PRESENT) && sd->Dacl) ? (PSID)((BYTE *)sd + sd->Dacl) : NULL;
    }
    else
    {
        /* absolute descriptor: these are real guest pointers (the self-
         * relative branch above uses offsets and must stay untouched) */
        out->Owner = guest_ptr32( sd->Owner );
        out->Group = guest_ptr32( sd->Group );
        out->Sacl = (sd->Control & SE_SACL_PRESENT) ? guest_ptr32( sd->Sacl ) : NULL;
        out->Dacl = (sd->Control & SE_DACL_PRESENT) ? guest_ptr32( sd->Dacl ) : NULL;
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

static inline OBJECT_ATTRIBUTES *objattr_32to64_redirect( struct object_attr64 *out,
                                                          const OBJECT_ATTRIBUTES32 *in )
{
    OBJECT_ATTRIBUTES *attr = objattr_32to64( out, in );

    if (attr) get_file_redirect( attr );
    return attr;
}

static inline TOKEN_USER *token_user_32to64( TOKEN_USER *out, const TOKEN_USER32 *in )
{
    out->User.Sid = guest_ptr32( in->User.Sid );
    out->User.Attributes = in->User.Attributes;
    return out;
}

static inline TOKEN_OWNER *token_owner_32to64( TOKEN_OWNER *out, const TOKEN_OWNER32 *in )
{
    out->Owner = guest_ptr32( in->Owner );
    return out;
}

static inline TOKEN_PRIMARY_GROUP *token_primary_group_32to64( TOKEN_PRIMARY_GROUP *out, const TOKEN_PRIMARY_GROUP32 *in )
{
    out->PrimaryGroup = guest_ptr32( in->PrimaryGroup );
    return out;
}

static inline TOKEN_DEFAULT_DACL *token_default_dacl_32to64( TOKEN_DEFAULT_DACL *out, const TOKEN_DEFAULT_DACL32 *in )
{
    out->DefaultDacl = guest_ptr32( in->DefaultDacl );
    return out;
}

static inline void put_handle( ULONG *handle32, HANDLE handle )
{
    *handle32 = HandleToULong( handle );
}

static inline void put_addr( ULONG *addr32, void *addr )
{
    if (addr32) *addr32 = host_ptr32( addr );
}

/* put_addr for an address in another process's window */
static inline void put_addr_in( ULONG_PTR base, ULONG *addr32, void *addr )
{
    if (addr32) *addr32 = host_ptr32_in( base, addr );
}

static inline void put_size( ULONG *size32, SIZE_T size )
{
    if (size32) *size32 = min( size, MAXDWORD );
}

static inline void put_client_id( CLIENT_ID32 *id32, const CLIENT_ID *id )
{
    if (!id32) return;
    id32->UniqueProcess = HandleToLong( id->UniqueProcess );
    id32->UniqueThread = HandleToLong( id->UniqueThread );
}

static inline void put_iosb( IO_STATUS_BLOCK32 *io32, const IO_STATUS_BLOCK *io )
{
    /* sync I/O modifies the 64-bit iosb right away, so in that case we update the 32-bit one */
    /* async I/O leaves the 64-bit one untouched and updates the 32-bit one directly later on */
    if (io32 && io->Pointer != io32)
    {
        io32->Status = io->Status;
        io32->Information = io->Information;
    }
}

extern void put_section_image_info( SECTION_IMAGE_INFORMATION32 *info32,
                                    const SECTION_IMAGE_INFORMATION *info );
extern void put_vm_counters( VM_COUNTERS_EX32 *info32, const VM_COUNTERS_EX *info,
                             ULONG size );

#endif /* __WOW64_PRIVATE_H */
