/*
 * Network Store Interface
 *
 * Copyright 2021 Huw Davies
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
#include "ntstatus.h"
#define WIN32_NO_STATUS
#include "winsock2.h"
#include "winternl.h"
#include "ws2ipdef.h"
#include "iphlpapi.h"
#include "netioapi.h"
#include "iptypes.h"
#include "netiodef.h"
#include "wine/nsi.h"
#include "wine/debug.h"
#include "wine/unixlib.h"

WINE_DEFAULT_DEBUG_CHANNEL(nsi);

static HANDLE nsi_device = INVALID_HANDLE_VALUE;
static HANDLE nsi_device_async = INVALID_HANDLE_VALUE;

/* iOS-Madeira 2026-08-03 rev=ml470 (#79 transport): nsiproxy.sys is not
 * shipped on iOS, so \\.\Nsi never exists and every NSI table read
 * fails — Steam's loopback peer authentication (GetExtendedTcpTable pid
 * lookup) dies before any pid compare and each CEF connection is
 * rejected as "unknown source". When the device is absent, service the
 * enumerate from a statically linked unixlib (TCP connection tables via
 * the in-process wineserver; see build/ntdll-unix/nsi_unixlib_ios.c).
 * On platforms with a real nsiproxy the device opens and this path
 * never runs. */
static BOOL nsi_unix_fallback( void )
{
    static int available = -1;
    if (available == -1) available = !__wine_init_unix_call();
    return available == 1;
}

/* iOS-Madeira: row and field reads (NsiGetAllParametersEx, NsiGetParameterEx)
 * use unix calls 1 and 2 of the same fallback. An older fallback has only
 * call 0, and nothing checks a call number against the length of its table,
 * so the parameter calls are made only after call 0 has shown that the
 * fallback serves more than TCP connections: a count-only read of the NDIS
 * interface table, which an older fallback (and MADEIRA_NSI_NETWORK_TABLES=0)
 * refuses with STATUS_NOT_SUPPORTED. Asked once per process. */
static BOOL nsi_unix_parameters( void )
{
    static LONG available = -1;

    if (available == -1)
    {
        static const NPI_MODULEID ndis_module =
            { sizeof(NPI_MODULEID), MIT_GUID,
              { { 0xeb004a11, 0x9b1a, 0x11d4, { 0x91, 0x23, 0x00, 0x50, 0x04, 0x77, 0x59, 0xbc } } } };
        struct nsi_enumerate_all_ex probe;
        LONG value = 0;

        if (nsi_unix_fallback())
        {
            memset( &probe, 0, sizeof(probe) );
            probe.module = &ndis_module;
            probe.table = NSI_NDIS_IFINFO_TABLE;
            value = WINE_UNIX_CALL( 0, &probe ) != STATUS_NOT_SUPPORTED;
        }
        InterlockedExchange( &available, value );
    }
    return available == 1;
}

BOOL WINAPI DllMain(HINSTANCE hinst, DWORD reason, void *reserved)
{
    switch (reason)
    {
        case DLL_PROCESS_ATTACH:
            DisableThreadLibraryCalls( hinst );
            break;
        case DLL_PROCESS_DETACH:
            if (nsi_device != INVALID_HANDLE_VALUE) CloseHandle( nsi_device );
            if (nsi_device_async != INVALID_HANDLE_VALUE) CloseHandle( nsi_device_async );
            break;
    }
    return TRUE;
}

/* iOS-Madeira: remember that the device is missing.
 *
 * Where the in-process fallback serves NSI the device never appears, yet
 * every call retried CreateFileW(\\.\Nsi): a full NtCreateFile and a failed
 * wineserver open each time. A program's network-polling thread made about
 * 1,700 of those a second in a device log (all STATUS_OBJECT_NAME_NOT_FOUND),
 * keeping the server busy. The first failure's error is kept and returned by
 * later calls, so callers see exactly what they saw before. Only when the
 * fallback exists; MADEIRA_NSI_DEVICE_CACHE=0 retries every time as before. */
static LONG nsi_device_missing[2];
static DWORD nsi_device_missing_err[2];

static BOOL nsi_missing_cache_enabled( void )
{
    static LONG enabled = -1;
    if (enabled < 0)
    {
        /* On by default: without \\.\Nsi, the failed open is remembered instead of
         * being retried on every call. 0 retries every time. */
        WCHAR value[4];
        DWORD len = GetEnvironmentVariableW( L"MADEIRA_NSI_DEVICE_CACHE", value, ARRAY_SIZE(value) );
        enabled = !(len && len < ARRAY_SIZE(value) && value[0] == '0');
    }
    return enabled;
}

static inline HANDLE get_nsi_device( BOOL async )
{
    HANDLE *cached_device = async ? &nsi_device_async : &nsi_device;
    HANDLE device;

    if (*cached_device == INVALID_HANDLE_VALUE)
    {
        if (nsi_device_missing[async ? 1 : 0])
        {
            SetLastError( nsi_device_missing_err[async ? 1 : 0] );
            return INVALID_HANDLE_VALUE;
        }
        device = CreateFileW( L"\\\\.\\Nsi", 0, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING,
                              async ? FILE_FLAG_OVERLAPPED : 0, NULL );
        if (device == INVALID_HANDLE_VALUE)
        {
            DWORD err = GetLastError();
            if (err == ERROR_FILE_NOT_FOUND && nsi_unix_fallback() && nsi_missing_cache_enabled())
            {
                nsi_device_missing_err[async ? 1 : 0] = err;
                InterlockedExchange( &nsi_device_missing[async ? 1 : 0], 1 );
                ERR( "no \\\\.\\Nsi: not retried from now on (MADEIRA_NSI_DEVICE_CACHE=0 retries)\n" );
            }
            SetLastError( err );
        }
        else if (InterlockedCompareExchangePointer( cached_device, device, INVALID_HANDLE_VALUE ) != INVALID_HANDLE_VALUE)
            CloseHandle( device );
    }
    return *cached_device;
}

/* iOS-Madeira: a change request with no device stays pending.
 *
 * Without \\.\Nsi every NsiRequestChangeNotification (NotifyAddrChange) failed
 * at once, so a caller that waits for an address change and then re-reads the
 * adapters looped instead: a device log had about 40 adapter enumerations a
 * second (NDIS interfaces, IPv4 addresses, IPv4 routes; about 1,500 NSI reads
 * a second) for the whole session. The fallback's addresses do not change
 * during a session, so the honest answer is a request that never completes:
 * the caller's OVERLAPPED is left STATUS_PENDING with its event reset and the
 * returned handle is a private event nothing sets; a caller without an
 * OVERLAPPED waits the way it would for a change. Cancelling completes the
 * request with STATUS_CANCELLED. Only when the fallback serves reads;
 * MADEIRA_NSI_NOTIFY_PENDING=0 fails the request as before. */
static HANDLE nsi_never_event;

static BOOL nsi_notify_pending_enabled( void )
{
    static LONG enabled = -1;
    if (enabled < 0)
    {
        /* On by default: without \\.\Nsi, an address-change request stays pending (the
         * addresses do not change) instead of failing at once. 0 fails it as before. */
        WCHAR value[4];
        DWORD len = GetEnvironmentVariableW( L"MADEIRA_NSI_NOTIFY_PENDING", value, ARRAY_SIZE(value) );
        enabled = !(len && len < ARRAY_SIZE(value) && value[0] == '0');
    }
    return enabled && nsi_unix_fallback();
}

static HANDLE nsi_never_signaled( void )
{
    HANDLE event;

    if (nsi_never_event) return nsi_never_event;
    if (!(event = CreateEventW( NULL, TRUE, FALSE, NULL ))) return NULL;
    if (InterlockedCompareExchangePointer( &nsi_never_event, event, NULL )) CloseHandle( event );
    return nsi_never_event;
}

static DWORD nsi_pending_notification( OVERLAPPED *ovr, HANDLE *handle )
{
    static LONG logged;
    HANDLE never = nsi_never_signaled();

    if (!never) return GetLastError();
    if (!InterlockedExchange( &logged, 1 ))
        ERR( "no \\\\.\\Nsi: change requests stay pending (MADEIRA_NSI_NOTIFY_PENDING=0 fails them)\n" );
    if (!ovr)
    {
        WaitForSingleObject( never, INFINITE );
        return ERROR_SUCCESS;
    }
    ovr->Internal = STATUS_PENDING;
    ovr->InternalHigh = 0;
    if (ovr->hEvent) ResetEvent( (HANDLE)((ULONG_PTR)ovr->hEvent & ~(ULONG_PTR)1) );
    if (handle) *handle = never;
    return ERROR_IO_PENDING;
}

DWORD WINAPI NsiAllocateAndGetTable( DWORD unk, const NPI_MODULEID *module, DWORD table, void **key_data, DWORD key_size,
                                     void **rw_data, DWORD rw_size, void **dynamic_data, DWORD dynamic_size,
                                     void **static_data, DWORD static_size, DWORD *count, DWORD unk2 )
{
    DWORD err, num = 64;
    void *data[4] = { NULL };
    DWORD sizes[4] = { key_size, rw_size, dynamic_size, static_size };
    int i, attempt;

    TRACE( "%ld %p %ld %p %ld %p %ld %p %ld %p %ld %p %ld\n", unk, module, table, key_data, key_size,
           rw_data, rw_size, dynamic_data, dynamic_size, static_data, static_size, count, unk2 );

    for (attempt = 0; attempt < 5; attempt++)
    {
        for (i = 0; i < ARRAY_SIZE(data); i++)
        {
            if (sizes[i])
            {
                data[i] = HeapAlloc( GetProcessHeap(), 0, sizes[i] * num );
                if (!data[i])
                {
                    err = ERROR_OUTOFMEMORY;
                    goto err;
                }
            }
        }

        err = NsiEnumerateObjectsAllParameters( unk, 0, module, table, data[0], sizes[0], data[1], sizes[1],
                                                data[2], sizes[2], data[3], sizes[3], &num );
        if (err != ERROR_MORE_DATA) break;
        TRACE( "Short buffer, attempt %d.\n", attempt );
        NsiFreeTable( data[0], data[1], data[2], data[3] );
        memset( data, 0, sizeof(data) );
        err = NsiEnumerateObjectsAllParameters( unk, 0, module, table, NULL, 0, NULL, 0, NULL, 0, NULL, 0, &num );
        if (err) return err;
        err = ERROR_OUTOFMEMORY; /* fail if this is the last attempt */
        num += num >> 4; /* the tables may grow before the next iteration; get ahead */
    }

    if (!err)
    {
        if (sizes[0]) *key_data = data[0];
        if (sizes[1]) *rw_data = data[1];
        if (sizes[2]) *dynamic_data = data[2];
        if (sizes[3]) *static_data = data[3];
        *count = num;
    }

err:
    if (err) NsiFreeTable( data[0], data[1], data[2], data[3] );
    return err;
}

DWORD WINAPI NsiCancelChangeNotification( OVERLAPPED *ovr )
{
    DWORD err = ERROR_SUCCESS;

    TRACE( "%p.\n", ovr );

    if (!ovr) return ERROR_NOT_FOUND;
    /* iOS-Madeira: a request left pending by nsi_pending_notification() */
    if (nsi_never_event && get_nsi_device( TRUE ) == INVALID_HANDLE_VALUE)
    {
        if (ovr->Internal != STATUS_PENDING) return ERROR_NOT_FOUND;
        ovr->Internal = STATUS_CANCELLED;
        if (ovr->hEvent) SetEvent( (HANDLE)((ULONG_PTR)ovr->hEvent & ~(ULONG_PTR)1) );
        return ERROR_SUCCESS;
    }
    if (!CancelIoEx(  get_nsi_device( TRUE ), ovr ))
        err = GetLastError();

    return err;
}

DWORD WINAPI NsiEnumerateObjectsAllParameters( DWORD unk, DWORD unk2, const NPI_MODULEID *module, DWORD table,
                                               void *key_data, DWORD key_size, void *rw_data, DWORD rw_size,
                                               void *dynamic_data, DWORD dynamic_size, void *static_data, DWORD static_size,
                                               DWORD *count )
{
    struct nsi_enumerate_all_ex params;
    DWORD err;

    TRACE( "%ld %ld %p %ld %p %ld %p %ld %p %ld %p %ld %p\n", unk, unk2, module, table, key_data, key_size,
           rw_data, rw_size, dynamic_data, dynamic_size, static_data, static_size, count );

    params.unknown[0] = 0;
    params.unknown[1] = 0;
    params.module = module;
    params.table = table;
    params.first_arg = unk;
    params.second_arg = unk2;
    params.key_data = key_data;
    params.key_size = key_size;
    params.rw_data = rw_data;
    params.rw_size = rw_size;
    params.dynamic_data = dynamic_data;
    params.dynamic_size = dynamic_size;
    params.static_data = static_data;
    params.static_size = static_size;
    params.count = *count;

    err = NsiEnumerateObjectsAllParametersEx( &params );
    *count = params.count;
    return err;
}

DWORD WINAPI NsiEnumerateObjectsAllParametersEx( struct nsi_enumerate_all_ex *params )
{
    DWORD out_size, received, err = ERROR_SUCCESS;
    HANDLE device = get_nsi_device( FALSE );
    struct nsiproxy_enumerate_all in;
    BYTE *out, *ptr;

    if (device == INVALID_HANDLE_VALUE)
    {
        DWORD device_err = GetLastError();
        NTSTATUS status;
        static LONG logged;

        if (!nsi_unix_fallback()) return device_err;
        status = WINE_UNIX_CALL( 0, params );
        if (!InterlockedExchange( &logged, 1 ))
            ERR( "no \\\\.\\Nsi (err %lu); serviced in-process, status %#lx rev=ml472\n",
                 device_err, status );
        if (status == STATUS_BUFFER_OVERFLOW) return ERROR_MORE_DATA;
        /* ml472: unserviced tables keep the exact pre-fallback error so callers
         * see the same failure (2) they always did, not NOT_SUPPORTED (50) */
        if (status == STATUS_NOT_SUPPORTED) return device_err;
        return RtlNtStatusToDosError( status );
    }

    out_size = sizeof(DWORD) +
        (params->key_size + params->rw_size + params->dynamic_size + params->static_size) * params->count;

    out = malloc( out_size );
    if (!out) return ERROR_OUTOFMEMORY;

    in.module = *params->module;
    in.first_arg = params->first_arg;
    in.second_arg = params->second_arg;
    in.table = params->table;
    in.key_size = params->key_size;
    in.rw_size = params->rw_size;
    in.dynamic_size = params->dynamic_size;
    in.static_size = params->static_size;
    in.count = params->count;

    if (!DeviceIoControl( device, IOCTL_NSIPROXY_WINE_ENUMERATE_ALL, &in, sizeof(in), out, out_size, &received, NULL ))
        err = GetLastError();
    if (err == ERROR_SUCCESS || err == ERROR_MORE_DATA)
    {
        params->count = *(DWORD *)out;
        ptr = out + sizeof(DWORD);
        if (params->key_size) memcpy( params->key_data, ptr, params->key_size * params->count );
        ptr += params->key_size * in.count;
        if (params->rw_size) memcpy( params->rw_data, ptr, params->rw_size * params->count );
        ptr += params->rw_size * in.count;
        if (params->dynamic_size) memcpy( params->dynamic_data, ptr, params->dynamic_size * params->count );
        ptr += params->dynamic_size * in.count;
        if (params->static_size) memcpy( params->static_data, ptr, params->static_size * params->count );
    }

    free( out );

    return err;
}

void WINAPI NsiFreeTable( void *key_data, void *rw_data, void *dynamic_data, void *static_data )
{
    TRACE( "%p %p %p %p\n", key_data, rw_data, dynamic_data, static_data );
    HeapFree( GetProcessHeap(), 0, key_data );
    HeapFree( GetProcessHeap(), 0, rw_data );
    HeapFree( GetProcessHeap(), 0, dynamic_data );
    HeapFree( GetProcessHeap(), 0, static_data );
}

DWORD WINAPI NsiGetAllParameters( DWORD unk, const NPI_MODULEID *module, DWORD table, const void *key, DWORD key_size,
                                  void *rw_data, DWORD rw_size, void *dynamic_data, DWORD dynamic_size,
                                  void *static_data, DWORD static_size )
{
    struct nsi_get_all_parameters_ex params;

    TRACE( "%ld %p %ld %p %ld %p %ld %p %ld %p %ld\n", unk, module, table, key, key_size,
           rw_data, rw_size, dynamic_data, dynamic_size, static_data, static_size );

    params.unknown[0] = 0;
    params.unknown[1] = 0;
    params.module = module;
    params.table = table;
    params.first_arg = unk;
    params.unknown2 = 0;
    params.key = key;
    params.key_size = key_size;
    params.rw_data = rw_data;
    params.rw_size = rw_size;
    params.dynamic_data = dynamic_data;
    params.dynamic_size = dynamic_size;
    params.static_data = static_data;
    params.static_size = static_size;

    return NsiGetAllParametersEx( &params );
}

DWORD WINAPI NsiGetAllParametersEx( struct nsi_get_all_parameters_ex *params )
{
    HANDLE device = get_nsi_device( FALSE );
    struct nsiproxy_get_all_parameters *in;
    ULONG in_size = FIELD_OFFSET( struct nsiproxy_get_all_parameters, key[params->key_size] ), received;
    ULONG out_size = params->rw_size + params->dynamic_size + params->static_size;
    DWORD err = ERROR_SUCCESS;
    BYTE *out, *ptr;

    if (device == INVALID_HANDLE_VALUE)
    {
        DWORD device_err = GetLastError();
        NTSTATUS status;

        /* iOS-Madeira: the in-process fallback; see nsi_unix_parameters() */
        if (!nsi_unix_parameters()) return device_err;
        status = WINE_UNIX_CALL( 1, params );
        return status == STATUS_NOT_SUPPORTED ? device_err : RtlNtStatusToDosError( status );
    }

    in = malloc( in_size );
    out = malloc( out_size );
    if (!in || !out)
    {
        err = ERROR_OUTOFMEMORY;
        goto err;
    }

    in->module = *params->module;
    in->first_arg = params->first_arg;
    in->table = params->table;
    in->key_size = params->key_size;
    in->rw_size = params->rw_size;
    in->dynamic_size = params->dynamic_size;
    in->static_size = params->static_size;
    memcpy( in->key, params->key, params->key_size );

    if (!DeviceIoControl( device, IOCTL_NSIPROXY_WINE_GET_ALL_PARAMETERS, in, in_size, out, out_size, &received, NULL ))
        err = GetLastError();
    if (err == ERROR_SUCCESS)
    {
        ptr = out;
        if (params->rw_size) memcpy( params->rw_data, ptr, params->rw_size );
        ptr += params->rw_size;
        if (params->dynamic_size) memcpy( params->dynamic_data, ptr, params->dynamic_size );
        ptr += params->dynamic_size;
        if (params->static_size) memcpy( params->static_data, ptr, params->static_size );
    }

err:
    free( out );
    free( in );
    return err;
}

DWORD WINAPI NsiGetParameter( DWORD unk, const NPI_MODULEID *module, DWORD table, const void *key, DWORD key_size,
                              DWORD param_type, void *data, DWORD data_size, DWORD data_offset )
{
    struct nsi_get_parameter_ex params;

    TRACE( "%ld %p %ld %p %ld %ld %p %ld %ld\n", unk, module, table, key, key_size,
           param_type, data, data_size, data_offset );

    params.unknown[0] = 0;
    params.unknown[1] = 0;
    params.module = module;
    params.table = table;
    params.first_arg = unk;
    params.unknown2 = 0;
    params.key = key;
    params.key_size = key_size;
    params.param_type = param_type;
    params.data = data;
    params.data_size = data_size;
    params.data_offset = data_offset;
    return NsiGetParameterEx( &params );
}

DWORD WINAPI NsiGetParameterEx( struct nsi_get_parameter_ex *params )
{
    HANDLE device = get_nsi_device( FALSE );
    struct nsiproxy_get_parameter *in;
    ULONG in_size = FIELD_OFFSET( struct nsiproxy_get_parameter, key[params->key_size] ), received;
    DWORD err = ERROR_SUCCESS;

    if (device == INVALID_HANDLE_VALUE)
    {
        DWORD device_err = GetLastError();
        NTSTATUS status;

        /* iOS-Madeira: the in-process fallback; see nsi_unix_parameters() */
        if (!nsi_unix_parameters()) return device_err;
        status = WINE_UNIX_CALL( 2, params );
        return status == STATUS_NOT_SUPPORTED ? device_err : RtlNtStatusToDosError( status );
    }

    in = malloc( in_size );
    if (!in) return ERROR_OUTOFMEMORY;
    in->module = *params->module;
    in->first_arg = params->first_arg;
    in->table = params->table;
    in->key_size = params->key_size;
    in->param_type = params->param_type;
    in->data_offset = params->data_offset;
    memcpy( in->key, params->key, params->key_size );

    if (!DeviceIoControl( device, IOCTL_NSIPROXY_WINE_GET_PARAMETER, in, in_size, params->data, params->data_size, &received, NULL ))
        err = GetLastError();

    free( in );
    return err;
}

DWORD WINAPI NsiRequestChangeNotification( DWORD unk, const NPI_MODULEID *module, DWORD table, OVERLAPPED *ovr,
                                           HANDLE *handle )
{
    struct nsi_request_change_notification_ex params;

    TRACE( "%lu %p %lu %p %p stub.\n", unk, module, table, ovr, handle );

    params.unk = unk;
    params.module = module;
    params.table = table;
    params.ovr = ovr;
    params.handle = handle;
    return NsiRequestChangeNotificationEx( &params );
}

DWORD WINAPI NsiRequestChangeNotificationEx( struct nsi_request_change_notification_ex *params )
{
    HANDLE device = get_nsi_device( TRUE );
    struct nsiproxy_request_notification *in;
    ULONG in_size = sizeof(struct nsiproxy_get_parameter), received;
    OVERLAPPED overlapped, *ovr;
    DWORD err = ERROR_SUCCESS;
    DWORD len;

    TRACE( "%p.\n", params );

    if (params->unk) FIXME( "unknown parameter %#lx.\n", params->unk );

    if (device == INVALID_HANDLE_VALUE)
    {
        err = GetLastError();
        /* iOS-Madeira: see nsi_pending_notification() */
        if (err == ERROR_FILE_NOT_FOUND && nsi_notify_pending_enabled())
            return nsi_pending_notification( params->ovr, params->handle );
        return err;
    }

    in = malloc( in_size );
    if (!in) return ERROR_OUTOFMEMORY;
    in->module = *params->module;
    in->table = params->table;

    if (!(ovr = params->ovr))
    {
        overlapped.hEvent = CreateEventW( NULL, FALSE, FALSE, NULL );
        ovr = &overlapped;
    }
    if (!DeviceIoControl( device, IOCTL_NSIPROXY_WINE_CHANGE_NOTIFICATION, in, in_size, NULL, 0, &received, ovr ))
        err = GetLastError();
    if (ovr == &overlapped)
    {
        if (err == ERROR_IO_PENDING)
            err = GetOverlappedResult( device, ovr, &len, TRUE ) ? 0 : GetLastError();
        CloseHandle( overlapped.hEvent );
    }
    else if (params->handle && ovr && err == ERROR_IO_PENDING)
        *params->handle = device;

    free( in );
    return err;
}
