/*
 * Windows sockets
 *
 * Copyright 2021 Zebediah Figura for CodeWeavers
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

#if 0
#pragma makedep unix
#endif

#include "config.h"
#include <assert.h>
#include <errno.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <time.h>   /* ml591: CLOCK_MONOTONIC for the per-socket TLS timeline */
#ifdef HAVE_IFADDRS_H
# include <ifaddrs.h>
#endif
#ifdef HAVE_NET_IF_H
# include <net/if.h>
#endif
#ifdef HAVE_NETINET_IN_H
# define __APPLE_USE_RFC_3542
# include <netinet/in.h>
#endif
#ifdef HAVE_NETINET_TCP_H
# include <netinet/tcp.h>
#endif

#ifdef HAVE_NETIPX_IPX_H
# include <netipx/ipx.h>
# define HAS_IPX
#elif defined(HAVE_LINUX_IPX_H)
# ifdef HAVE_ASM_TYPES_H
#  include <asm/types.h>
# endif
# ifdef HAVE_LINUX_TYPES_H
#  include <linux/types.h>
# endif
# include <linux/ipx.h>
# ifdef SOL_IPX
#  define HAS_IPX
# endif
#endif

#ifdef HAVE_LINUX_IRDA_H
# ifdef HAVE_LINUX_TYPES_H
#  include <linux/types.h>
# endif
# include <linux/irda.h>
# define HAS_IRDA
#endif

#include "ntstatus.h"
#include "windef.h"
#include "winioctl.h"
#define USE_WS_PREFIX
#include "winsock2.h"
#include "mswsock.h"
#include "mstcpip.h"
#include "ws2tcpip.h"
#include "wsipx.h"
#include "af_irda.h"
#include "wine/afd.h"

#include "unix_private.h"

#if !defined(TCP_KEEPIDLE) && defined(TCP_KEEPALIVE)
/* TCP_KEEPALIVE is the Mac OS name for TCP_KEEPIDLE */
#define TCP_KEEPIDLE TCP_KEEPALIVE
#endif

#if defined(linux) && !defined(IP_UNICAST_IF)
#define IP_UNICAST_IF 50
#endif

WINE_DEFAULT_DEBUG_CHANNEL(winsock);

#define u64_to_user_ptr(u) ((void *)(uintptr_t)(u))

union unix_sockaddr
{
    struct sockaddr addr;
    struct sockaddr_in in;
    struct sockaddr_in6 in6;
#ifdef HAS_IPX
    struct sockaddr_ipx ipx;
#endif
#ifdef HAS_IRDA
    struct sockaddr_irda irda;
#endif
};

struct async_recv_ioctl
{
    struct async_fileio io;
    void *control;
    struct WS_sockaddr *addr;
    int *addr_len;
    unsigned int *ret_flags;
    int unix_flags;
    unsigned int count;
    BOOL icmp_over_dgram;
    struct iovec iov[1];
};

struct async_send_ioctl
{
    struct async_fileio io;
    const struct WS_sockaddr *addr;
    int addr_len;
    int unix_flags;
    unsigned int sent_len;
    unsigned int count;
    unsigned int iov_cursor;
    int fd;
    struct iovec iov[1];
};

struct async_transmit_ioctl
{
    struct async_fileio io;
    HANDLE file;
    char *buffer;
    unsigned int buffer_size;   /* allocated size of buffer */
    unsigned int read_len;      /* amount of valid data currently in the buffer */
    unsigned int head_cursor;   /* amount of header data already sent */
    unsigned int file_cursor;   /* amount of file data already sent */
    unsigned int buffer_cursor; /* amount of data currently in the buffer already sent */
    unsigned int tail_cursor;   /* amount of tail data already sent */
    unsigned int file_len;      /* total file length to send */
    unsigned int flags;
    const char *head;
    const char *tail;
    unsigned int head_len;
    unsigned int tail_len;
    LARGE_INTEGER offset;
};

static NTSTATUS sock_errno_to_status( int err )
{
    switch (err)
    {
        case EBADF:             return STATUS_INVALID_HANDLE;
        case EBUSY:             return STATUS_DEVICE_BUSY;
        case EPERM:
        case EACCES:            return STATUS_ACCESS_DENIED;
        case EFAULT:            return STATUS_ACCESS_VIOLATION;
        case EINVAL:            return STATUS_INVALID_PARAMETER;
        case ENFILE:
        case EMFILE:            return STATUS_TOO_MANY_OPENED_FILES;
        case EINPROGRESS:
        case EWOULDBLOCK:       return STATUS_DEVICE_NOT_READY;
        case EALREADY:          return STATUS_NETWORK_BUSY;
        case ENOTSOCK:          return STATUS_OBJECT_TYPE_MISMATCH;
        case EDESTADDRREQ:      return STATUS_INVALID_CONNECTION;
        case EMSGSIZE:          return STATUS_BUFFER_OVERFLOW;
        case EPROTONOSUPPORT:
        case ESOCKTNOSUPPORT:
        case EPFNOSUPPORT:
        case EAFNOSUPPORT:
        case EPROTOTYPE:        return STATUS_NOT_SUPPORTED;
        case ENOPROTOOPT:       return STATUS_INVALID_PARAMETER;
        case EOPNOTSUPP:        return STATUS_NOT_SUPPORTED;
        case EADDRINUSE:        return STATUS_SHARING_VIOLATION;
        case EADDRNOTAVAIL:     return STATUS_INVALID_PARAMETER;
        case ECONNREFUSED:      return STATUS_CONNECTION_REFUSED;
        case ESHUTDOWN:         return STATUS_PIPE_DISCONNECTED;
        case ENOTCONN:          return STATUS_INVALID_CONNECTION;
        case ETIMEDOUT:         return STATUS_IO_TIMEOUT;
        case ENETUNREACH:       return STATUS_NETWORK_UNREACHABLE;
        case EHOSTUNREACH:      return STATUS_HOST_UNREACHABLE;
        case ENETDOWN:          return STATUS_NETWORK_BUSY;
        case EPIPE:
        case ECONNRESET:        return STATUS_CONNECTION_RESET;
        case ECONNABORTED:      return STATUS_CONNECTION_ABORTED;
        case EISCONN:           return STATUS_CONNECTION_ACTIVE;

        case 0:                 return STATUS_SUCCESS;
        default:
            FIXME( "unknown errno %d\n", err );
            return STATUS_UNSUCCESSFUL;
    }
}

static socklen_t sockaddr_to_unix( const struct WS_sockaddr *wsaddr, int wsaddrlen, union unix_sockaddr *uaddr )
{
    memset( uaddr, 0, sizeof(*uaddr) );

    switch (wsaddr->sa_family)
    {
    case WS_AF_INET:
    {
        struct WS_sockaddr_in win = {0};

        if (wsaddrlen < sizeof(win)) return 0;
        memcpy( &win, wsaddr, sizeof(win) );
        uaddr->in.sin_family = AF_INET;
        uaddr->in.sin_port = win.sin_port;
        memcpy( &uaddr->in.sin_addr, &win.sin_addr, sizeof(win.sin_addr) );
        return sizeof(uaddr->in);
    }

    case WS_AF_INET6:
    {
        struct WS_sockaddr_in6 win = {0};

        if (wsaddrlen < sizeof(win)) return 0;
        memcpy( &win, wsaddr, sizeof(win) );
        uaddr->in6.sin6_family = AF_INET6;
        uaddr->in6.sin6_port = win.sin6_port;
        uaddr->in6.sin6_flowinfo = win.sin6_flowinfo;
        memcpy( &uaddr->in6.sin6_addr, &win.sin6_addr, sizeof(win.sin6_addr) );
#ifdef HAVE_STRUCT_SOCKADDR_IN6_SIN6_SCOPE_ID
        uaddr->in6.sin6_scope_id = win.sin6_scope_id;
#endif
        return sizeof(uaddr->in6);
    }

#ifdef HAS_IPX
    case WS_AF_IPX:
    {
        struct WS_sockaddr_ipx win = {0};

        if (wsaddrlen < sizeof(win)) return 0;
        memcpy( &win, wsaddr, sizeof(win) );
        uaddr->ipx.sipx_family = AF_IPX;
        memcpy( &uaddr->ipx.sipx_network, win.sa_netnum, sizeof(win.sa_netnum) );
        memcpy( &uaddr->ipx.sipx_node, win.sa_nodenum, sizeof(win.sa_nodenum) );
        uaddr->ipx.sipx_port = win.sa_socket;
        return sizeof(uaddr->ipx);
    }
#endif

#ifdef HAS_IRDA
    case WS_AF_IRDA:
    {
        SOCKADDR_IRDA win = {0};
        unsigned int lsap_sel;

        if (wsaddrlen < sizeof(win)) return 0;
        memcpy( &win, wsaddr, sizeof(win) );
        uaddr->irda.sir_family = AF_IRDA;
        if (sscanf( win.irdaServiceName, "LSAP-SEL%u", &lsap_sel ) == 1)
            uaddr->irda.sir_lsap_sel = lsap_sel;
        else
        {
            uaddr->irda.sir_lsap_sel = LSAP_ANY;
            memcpy( uaddr->irda.sir_name, win.irdaServiceName, sizeof(win.irdaServiceName) );
        }
        memcpy( &uaddr->irda.sir_addr, win.irdaDeviceID, sizeof(win.irdaDeviceID) );
        return sizeof(uaddr->irda);
    }
#endif

    case WS_AF_UNSPEC:
        switch (wsaddrlen)
        {
        default: /* likely an ipv4 address */
        case sizeof(struct WS_sockaddr_in):
            return sizeof(uaddr->in);

#ifdef HAS_IPX
        case sizeof(struct WS_sockaddr_ipx):
            return sizeof(uaddr->ipx);
#endif

#ifdef HAS_IRDA
        case sizeof(SOCKADDR_IRDA):
            return sizeof(uaddr->irda);
#endif

        case sizeof(struct WS_sockaddr_in6):
            return sizeof(uaddr->in6);
        }

    default:
        FIXME( "unknown address family %u\n", wsaddr->sa_family );
        return 0;
    }
}

static int sockaddr_from_unix( const union unix_sockaddr *uaddr, struct WS_sockaddr *wsaddr, socklen_t wsaddrlen )
{
    switch (uaddr->addr.sa_family)
    {
    case AF_INET:
    {
        struct WS_sockaddr_in win = {0};

        if (wsaddrlen < sizeof(win)) return -1;
        win.sin_family = WS_AF_INET;
        win.sin_port = uaddr->in.sin_port;
        memcpy( &win.sin_addr, &uaddr->in.sin_addr, sizeof(win.sin_addr) );
        memcpy( wsaddr, &win, sizeof(win) );
        return sizeof(win);
    }

    case AF_INET6:
    {
        struct WS_sockaddr_in6 win = {0};

        if (wsaddrlen < sizeof(win)) return -1;
        win.sin6_family = WS_AF_INET6;
        win.sin6_port = uaddr->in6.sin6_port;
        win.sin6_flowinfo = uaddr->in6.sin6_flowinfo;
        memcpy( &win.sin6_addr, &uaddr->in6.sin6_addr, sizeof(win.sin6_addr) );
#ifdef HAVE_STRUCT_SOCKADDR_IN6_SIN6_SCOPE_ID
        win.sin6_scope_id = uaddr->in6.sin6_scope_id;
#endif
        memcpy( wsaddr, &win, sizeof(win) );
        return sizeof(win);
    }

#ifdef HAS_IPX
    case AF_IPX:
    {
        struct WS_sockaddr_ipx win = {0};

        if (wsaddrlen < sizeof(win)) return -1;
        win.sa_family = WS_AF_IPX;
        memcpy( win.sa_netnum, &uaddr->ipx.sipx_network, sizeof(win.sa_netnum) );
        memcpy( win.sa_nodenum, &uaddr->ipx.sipx_node, sizeof(win.sa_nodenum) );
        win.sa_socket = uaddr->ipx.sipx_port;
        memcpy( wsaddr, &win, sizeof(win) );
        return sizeof(win);
    }
#endif

#ifdef HAS_IRDA
    case AF_IRDA:
    {
        SOCKADDR_IRDA win;

        if (wsaddrlen < sizeof(win)) return -1;
        win.irdaAddressFamily = WS_AF_IRDA;
        memcpy( win.irdaDeviceID, &uaddr->irda.sir_addr, sizeof(win.irdaDeviceID) );
        if (uaddr->irda.sir_lsap_sel != LSAP_ANY)
            snprintf( win.irdaServiceName, sizeof(win.irdaServiceName), "LSAP-SEL%u", uaddr->irda.sir_lsap_sel );
        else
            memcpy( win.irdaServiceName, uaddr->irda.sir_name, sizeof(win.irdaServiceName) );
        memcpy( wsaddr, &win, sizeof(win) );
        return sizeof(win);
    }
#endif

    case AF_UNSPEC:
        return 0;

    default:
        FIXME( "unknown address family %d\n", uaddr->addr.sa_family );
        return -1;
    }
}

static WSACMSGHDR *fill_control_message( int level, int type, WSACMSGHDR *current, ULONG *maxsize, void *data, int len )
{
    ULONG msgsize = sizeof(WSACMSGHDR) + WSA_CMSG_ALIGN(len);
    char *ptr = (char *) current + sizeof(WSACMSGHDR);

    if (msgsize > *maxsize)
        return NULL;
    *maxsize -= msgsize;
    current->cmsg_len = sizeof(WSACMSGHDR) + len;
    current->cmsg_level = level;
    current->cmsg_type = type;
    memcpy(ptr, data, len);
    return (WSACMSGHDR *)(ptr + WSA_CMSG_ALIGN(len));
}

static int convert_control_headers(struct msghdr *hdr, WSABUF *control)
{
    WSACMSGHDR *cmsg_win = (WSACMSGHDR *)control->buf, *ptr;
    ULONG ctlsize = control->len;
    struct cmsghdr *cmsg_unix;

    ptr = cmsg_win;
    for (cmsg_unix = CMSG_FIRSTHDR(hdr); cmsg_unix != NULL; cmsg_unix = CMSG_NXTHDR(hdr, cmsg_unix))
    {
        switch (cmsg_unix->cmsg_level)
        {
            case IPPROTO_IP:
                switch (cmsg_unix->cmsg_type)
                {
#if defined(IP_PKTINFO)
                    case IP_PKTINFO:
                    {
                        const struct in_pktinfo *data_unix = (struct in_pktinfo *)CMSG_DATA(cmsg_unix);
                        struct WS_in_pktinfo data_win;

                        memcpy( &data_win.ipi_addr, &data_unix->ipi_addr.s_addr, 4 ); /* 4 bytes = 32 address bits */
                        data_win.ipi_ifindex = data_unix->ipi_ifindex;
                        ptr = fill_control_message( WS_IPPROTO_IP, WS_IP_PKTINFO, ptr, &ctlsize,
                                                    (void *)&data_win, sizeof(data_win) );
                        if (!ptr) goto error;
                        break;
                    }
#elif defined(IP_RECVDSTADDR)
                    case IP_RECVDSTADDR:
                    {
                        const struct in_addr *addr_unix = (struct in_addr *)CMSG_DATA(cmsg_unix);
                        struct WS_in_pktinfo data_win;

                        memcpy( &data_win.ipi_addr, &addr_unix->s_addr, 4 ); /* 4 bytes = 32 address bits */
                        data_win.ipi_ifindex = 0; /* FIXME */
                        ptr = fill_control_message( WS_IPPROTO_IP, WS_IP_PKTINFO, ptr, &ctlsize,
                                                    (void *)&data_win, sizeof(data_win) );
                        if (!ptr) goto error;
                        break;
                    }
#endif /* IP_PKTINFO */

#if defined(IP_TOS)
                    case IP_TOS:
                    {
                        INT tos = *(unsigned char *)CMSG_DATA(cmsg_unix);
                        ptr = fill_control_message( WS_IPPROTO_IP, WS_IP_TOS, ptr, &ctlsize,
                                                    &tos, sizeof(INT) );
                        if (!ptr) goto error;
                        break;
                    }
#endif /* IP_TOS */

#if defined(IP_TTL)
                    case IP_TTL:
                    {
                        ptr = fill_control_message( WS_IPPROTO_IP, WS_IP_TTL, ptr, &ctlsize,
                                                    CMSG_DATA(cmsg_unix), sizeof(INT) );
                        if (!ptr) goto error;
                        break;
                    }
#endif /* IP_TTL */

                    default:
                        FIXME("Unhandled IPPROTO_IP message header type %d\n", cmsg_unix->cmsg_type);
                        break;
                }
                break;

            case IPPROTO_IPV6:
                switch (cmsg_unix->cmsg_type)
                {
#if defined(IPV6_HOPLIMIT)
                    case IPV6_HOPLIMIT:
                    {
                        ptr = fill_control_message( WS_IPPROTO_IPV6, WS_IPV6_HOPLIMIT, ptr, &ctlsize,
                                                    CMSG_DATA(cmsg_unix), sizeof(INT) );
                        if (!ptr) goto error;
                        break;
                    }
#endif /* IPV6_HOPLIMIT */

#if defined(IPV6_PKTINFO) && defined(HAVE_STRUCT_IN6_PKTINFO_IPI6_ADDR)
                    case IPV6_PKTINFO:
                    {
                        struct in6_pktinfo *data_unix = (struct in6_pktinfo *)CMSG_DATA(cmsg_unix);
                        struct WS_in6_pktinfo data_win;

                        memcpy(&data_win.ipi6_addr, &data_unix->ipi6_addr.s6_addr, 16);
                        data_win.ipi6_ifindex = data_unix->ipi6_ifindex;
                        ptr = fill_control_message( WS_IPPROTO_IPV6, WS_IPV6_PKTINFO, ptr, &ctlsize,
                                                    (void *)&data_win, sizeof(data_win) );
                        if (!ptr) goto error;
                        break;
                    }
#endif /* IPV6_PKTINFO */

#if defined(IPV6_TCLASS)
                    case IPV6_TCLASS:
                    {
                        ptr = fill_control_message( WS_IPPROTO_IPV6, WS_IPV6_TCLASS, ptr, &ctlsize,
                                                    CMSG_DATA(cmsg_unix), sizeof(INT) );
                        if (!ptr) goto error;
                        break;
                    }
#endif /* IPV6_TCLASS */

                    default:
                        FIXME("Unhandled IPPROTO_IPV6 message header type %d\n", cmsg_unix->cmsg_type);
                        break;
                }
                break;

            default:
                FIXME("Unhandled message header level %d\n", cmsg_unix->cmsg_level);
                break;
        }
    }

    control->len = (char *)ptr - (char *)cmsg_win;
    return 1;

error:
    control->len = 0;
    return 0;
}

struct cmsghdr_32
{
    ULONG cmsg_len;
    INT cmsg_level;
    INT cmsg_type;
    /* UCHAR cmsg_data[]; */
};

static size_t cmsg_align_32( size_t len )
{
    return (len + sizeof(ULONG) - 1) & ~(sizeof(ULONG) - 1);
}

/* we assume that cmsg_data does not require translation, which is currently
 * true for all messages */
static int wow64_translate_control( const WSABUF *control64, struct afd_wsabuf_32 *control32 )
{
    char *const buf32 = ULongToPtr(control32->buf);
    const ULONG max_len = control32->len;
    const char *ptr64 = control64->buf;
    char *ptr32 = buf32;

    while (ptr64 < control64->buf + control64->len)
    {
        struct cmsghdr_32 *cmsg32 = (struct cmsghdr_32 *)ptr32;
        const WSACMSGHDR *cmsg64 = (const WSACMSGHDR *)ptr64;

        if (ptr32 + sizeof(*cmsg32) + cmsg_align_32( cmsg64->cmsg_len ) > buf32 + max_len)
        {
            control32->len = 0;
            return 0;
        }

        cmsg32->cmsg_len = cmsg64->cmsg_len - sizeof(*cmsg64) + sizeof(*cmsg32);
        cmsg32->cmsg_level = cmsg64->cmsg_level;
        cmsg32->cmsg_type = cmsg64->cmsg_type;
        memcpy( cmsg32 + 1, cmsg64 + 1, cmsg64->cmsg_len );

        ptr64 += WSA_CMSG_ALIGN( cmsg64->cmsg_len );
        ptr32 += cmsg_align_32( cmsg32->cmsg_len );
    }

    control32->len = ptr32 - buf32;
    FIXME("-> %d\n", control32->len);
    return 1;
}

struct ip_hdr
{
    BYTE v_hl; /* version << 4 | hdr_len */
    BYTE tos;
    UINT16 tot_len;
    UINT16 id;
    UINT16 frag_off;
    BYTE ttl;
    BYTE protocol;
    UINT16 checksum;
    ULONG saddr;
    ULONG daddr;
};

struct ipv6_pseudo_header
{
    struct in6_addr src;
    struct in6_addr dst;
    UINT32 next_len; /* incapsulated packet length in network byte order */
    BYTE zero[3];
    BYTE next_header;
};

struct icmp_hdr
{
    BYTE type;
    BYTE code;
    UINT16 checksum;
    union
    {
        struct
        {
            UINT16 id;
            UINT16 sequence;
        } echo;
    } un;
};

static unsigned int chksum_add( BYTE *data, unsigned int count, unsigned int sum )
{
    unsigned int carry = 0;
    unsigned short s;

    assert( !(count % 2) );
    while (count > 1)
    {
        s = *(unsigned short *)data;
        data += 2;
        sum += carry;
        sum += s;
        carry = s > sum;
        count -= 2;
    }
    sum += carry; /* This won't produce another carry */
    return sum;
}

/* rfc 1071 checksum */
static unsigned short chksum( BYTE *data, unsigned int count, unsigned int sum )
{
    unsigned short check;

    sum = chksum_add( data, count & ~1u, sum );
    sum = (sum & 0xffff) + (sum >> 16);

    if (count % 2) sum += data[count - 1]; /* LE-only */

    sum = (sum & 0xffff) + (sum >> 16);
    /* fold in any carry */
    sum = (sum & 0xffff) + (sum >> 16);

    check = ~sum;
    return check;
}

static void set_ipv6_addr_from_pktinfo( struct msghdr *hdr, struct in6_addr *addr )
{
#ifdef IPV6_PKTINFO
    struct in6_pktinfo *info;
    struct cmsghdr *cmsg;

    for (cmsg = CMSG_FIRSTHDR( hdr ); cmsg; cmsg = CMSG_NXTHDR( hdr, cmsg ))
    {
        if (cmsg->cmsg_level != IPPROTO_IPV6) continue;
        if (cmsg->cmsg_type != IPV6_PKTINFO) continue;
        info = (struct in6_pktinfo *)CMSG_DATA( cmsg );
        *addr = info->ipi6_addr;
        return;
    }
#endif
}

static ssize_t fixup_icmpv6_over_dgram( struct msghdr *hdr, void *buf, union unix_sockaddr *unix_addr,
                                      HANDLE handle, ssize_t recv_len )
{
    struct ipv6_pseudo_header ip_h;
    struct icmp_hdr *icmp_h = buf;
    unsigned int fixup_status;
    unsigned int sum;

    if (recv_len < sizeof(*icmp_h)) return recv_len;

    SERVER_START_REQ( socket_get_icmp_id )
    {
        req->handle = wine_server_obj_handle( handle );
        req->icmp_seq = icmp_h->un.echo.sequence;
        if (!(fixup_status = wine_server_call( req )))
            icmp_h->un.echo.id = reply->icmp_id;
    }
    SERVER_END_REQ;

    if (fixup_status)
    {
        WARN( "socket_get_icmp_id returned %#x.\n", fixup_status );
        return recv_len;
    }

    memset( &ip_h, 0, sizeof(ip_h) );
    ip_h.src = unix_addr->in6.sin6_addr;
    set_ipv6_addr_from_pktinfo( hdr, &ip_h.dst );
    ip_h.next_len = htonl( recv_len );
    ip_h.next_header = IPPROTO_ICMPV6;
    sum = chksum_add( (BYTE *)&ip_h, sizeof(ip_h), 0 );
    icmp_h->checksum = 0;
    icmp_h->checksum = chksum( (BYTE *)icmp_h, recv_len, sum );

    return recv_len;
}

static ssize_t fixup_icmp_over_dgram( struct msghdr *hdr, union unix_sockaddr *unix_addr,
                                      HANDLE handle, ssize_t recv_len, NTSTATUS *status )
{
    unsigned int tot_len = sizeof(struct ip_hdr) + recv_len;
    struct icmp_hdr *icmp_h = NULL;
    unsigned int fixup_status;
    struct cmsghdr *cmsg;
    struct ip_hdr ip_h;
    size_t buf_len;
    char *buf;

    if (hdr->msg_iovlen != 1)
    {
        FIXME( "Buffer count %zu is not supported for ICMP fixup.\n", (size_t)hdr->msg_iovlen );
        return recv_len;
    }

    buf = hdr->msg_iov[0].iov_base;
    buf_len = hdr->msg_iov[0].iov_len;

    if (unix_addr->addr.sa_family == AF_INET6)
        return fixup_icmpv6_over_dgram( hdr, buf, unix_addr, handle, recv_len );

    if (recv_len + sizeof(ip_h) > buf_len)
        *status = STATUS_BUFFER_OVERFLOW;

    if (buf_len < sizeof(ip_h))
    {
        recv_len = buf_len;
    }
    else
    {
        recv_len = min( recv_len, buf_len - sizeof(ip_h) );
        memmove( buf + sizeof(ip_h), buf, recv_len );
        if (recv_len >= sizeof(struct icmp_hdr))
            icmp_h = (struct icmp_hdr *)(buf + sizeof(ip_h));
        recv_len += sizeof(ip_h);
    }
    memset( &ip_h, 0, sizeof(ip_h) );
    ip_h.v_hl = (4 << 4) | (sizeof(ip_h) >> 2);
    ip_h.tot_len = htons( tot_len );
    ip_h.protocol = 1;
    ip_h.saddr = unix_addr->in.sin_addr.s_addr;

    for (cmsg = CMSG_FIRSTHDR( hdr ); cmsg; cmsg = CMSG_NXTHDR( hdr, cmsg ))
    {
        if (cmsg->cmsg_level != IPPROTO_IP) continue;
        switch (cmsg->cmsg_type)
        {
#if defined(IP_TTL)
            case IP_TTL:
                ip_h.ttl = *(BYTE *)CMSG_DATA( cmsg );
                break;
#endif
#if defined(IP_TOS)
            case IP_TOS:
                ip_h.tos = *(BYTE *)CMSG_DATA( cmsg );
                break;
#endif
#if defined(IP_PKTINFO)
            case IP_PKTINFO:
            {
                struct in_pktinfo *info;

                info = (struct in_pktinfo *)CMSG_DATA( cmsg );
                ip_h.daddr = info->ipi_addr.s_addr;
                break;
            }
#endif
        }
    }
    if (icmp_h)
    {
        SERVER_START_REQ( socket_get_icmp_id )
        {
            req->handle = wine_server_obj_handle( handle );
            req->icmp_seq = icmp_h->un.echo.sequence;
            if (!(fixup_status = wine_server_call( req )))
                icmp_h->un.echo.id = reply->icmp_id;
            else
                WARN( "socket_get_fixup_data returned %#x.\n", fixup_status );
        }
        SERVER_END_REQ;

        if (!fixup_status)
        {
            icmp_h->checksum = 0;
            icmp_h->checksum = chksum( (BYTE *)icmp_h, recv_len - sizeof(ip_h), 0 );
        }
    }
    ip_h.checksum = chksum( (BYTE *)&ip_h, sizeof(ip_h), 0 );
    memcpy( buf, &ip_h, min( sizeof(ip_h), buf_len ));

    return recv_len;
}

#ifdef __APPLE__
/* iOS-Madeira ml464 [sock-big] (#78): steamui's login boot died on
 * "ChunkLoadError: missing steamloopback.host/libraries/libraries~....js" —
 * a 1.99MB file that EXISTS on disk, served by steam.exe's loopback HTTP
 * server, while a 678KB file served fine seconds earlier. Prime suspect is a
 * large-transfer failure somewhere in this layer. Trace every TCP socket's
 * cumulative send/recv bytes (milestone log at 128KB, then every 512KB, with
 * the peer port to identify the HTTP server's socket) plus every hard error.
 * A transfer that STOPS at a byte count without an error implicates the
 * file-read side of TransmitFile instead; an errno names the socket layer.
 * Racy counters are acceptable — fixed array, no pointers, probe-only. */
/* iOS-Madeira ml578: TRACE THE FIRST BYTES ON EXTERNAL TCP SOCKETS.
 *
 * State of the hunt: the Shenzhen network is EXONERATED — from the same phone,
 * Safari got 91 CM endpoints from the directory API, loaded /cmping/ on 443, and
 * got a real 403 from cmp1-tyo3:27019 (so TCP+TLS+HTTP all complete on the odd CM
 * ports too). Our own probe shows CM TCP connects genuinely complete
 * (getpeername succeeds). Yet every PingWebSocketCM fails.
 *
 * The poll-cache theory is dead (0 stale in 18.4M classifications), but that only
 * exonerated fd CLASSIFICATION — not readiness-mask translation, wake delivery,
 * or async completion. And the single [schannel-ios] gnutls handshake is NOT a
 * measure of Steam's TLS: steamclient64.dll carries Valve's own statically-linked
 * OpenSSL, so its CM handshakes never touch Wine's SChannel at all. Counting
 * record types on the wire is the only reliable way to see them. (Both points
 * from Sol; the gnutls misreading was mine.)
 *
 * Five bytes is all we take — enough to classify a TLS record, not enough to log
 * anything sensitive:
 *     16 03 xx = handshake    15 03 xx = alert    17 03 xx = application data
 *
 * Per-socket budget, not one global counter: a chatty local socket must not be
 * able to starve the CM sockets, which is the trap that has invalidated three
 * probes in this investigation already. Loopback is skipped so the steamloopback
 * traffic cannot drown the census. */
/* iOS-Madeira ml591: PER-SOCKET TLS TIMELINE — the timing half of the CM hunt.
 *
 * ml590 settled the PHASE question: on every CM socket we caught, the handshake ran
 * to completion (ClientHello -> server flight -> CCS+Finished -> encrypted
 * post-handshake records) and Steam then sent NOTHING — no WebSocket Upgrade. What
 * it could NOT answer is WHEN, because ios_sock_wire above has no clock. It also
 * cannot simply be extended: it calls getpeername() before EVERY send/recv and
 * dprintf()s inline, on a path whose entire CM ping budget is 1000 ms. Instrumenting
 * per event is how you manufacture the timeout you are trying to measure — which is
 * exactly why ml579 gated it off.
 *
 * So here every milestone is a STORE, never I/O, and getpeername() runs once per
 * connection rather than per call. One summary line is emitted only when the socket's
 * fate is already decided: fd reuse (abandoned), an Upgrade actually going out, or a
 * stale sweep so a socket that closes and is never reused still reports.
 *
 * Reading it: `flight->fin` is the milestone that matters. first-recv only marks when
 * ServerHello arrived; the flight->fin gap is where certificate verification and the
 * client's own crypto run, which is the work we suspect blows the budget. (Sol's
 * point, and the reason a first-send/first-recv-only probe would have proved nothing.)
 *   total well under 1000ms, no post  => healthy session Steam abandoned => client state
 *   total at/over 1000ms              => deadline expiry => hunt local crypto/JIT cost
 *
 * Caveat kept from ml590: TLS 1.3 puts EncryptedExtensions/Certificate/
 * CertificateVerify/Finished/NewSessionTicket ALL under record type 0x17, so the tail
 * read is "post-handshake", not provably application data. */
#define IOS_TL_SLOTS 128
struct ios_tl_ent
{
    int                fd;          /* <=0 = free slot */
    unsigned short     port;
    unsigned int       gen;
    unsigned long long t0, t_ch, t_flight, t_fin, t_tail, t_post, t_last;
    unsigned int       n_send, n_recv, alerts;
    unsigned long      b_send, b_recv;
    int                post_len;
    unsigned char      post5[5];
};
static struct ios_tl_ent ios_tl_tab[IOS_TL_SLOTS];
static unsigned int ios_tl_gen;

static unsigned long long ios_tl_now(void)
{
    struct timespec ts;
    clock_gettime( CLOCK_MONOTONIC, &ts );
    return (unsigned long long)ts.tv_sec * 1000000000ull + (unsigned long long)ts.tv_nsec;
}

/* milestone delta in ms, or -1 when either end never happened */
static double ios_tl_d( unsigned long long a, unsigned long long b )
{
    return (a && b && b >= a) ? (double)(b - a) / 1e6 : -1.0;
}

static void ios_tl_flush( struct ios_tl_ent *e, const char *fate )
{
    char post[32];

    if (e->fd <= 0) return;
    if (e->t_post)
        snprintf( post, sizeof(post), "%d:%02x %02x", e->post_len, e->post5[0], e->post5[1] );
    else
        strcpy( post, "NONE" );

    dprintf( 2, "[sock-tl] fd=%d gen=%u port=%u open->CH=%.1f CH->flight=%.1f "
                "flight->fin=%.1f fin->tail=%.1f tail->post=%.1f total=%.1fms "
                "tx=%u/%luB rx=%u/%luB alerts=%u post=%s fate=%s rev=ml591\n",
             e->fd, e->gen, e->port,
             ios_tl_d( e->t0, e->t_ch ), ios_tl_d( e->t_ch, e->t_flight ),
             ios_tl_d( e->t_flight, e->t_fin ), ios_tl_d( e->t_fin, e->t_tail ),
             ios_tl_d( e->t_tail, e->t_post ), ios_tl_d( e->t0, e->t_last ),
             e->n_send, e->b_send, e->n_recv, e->b_recv, e->alerts, post, fate );
    e->fd = -1;
}

static void ios_sock_tl( int fd, int is_send, const void *buf, long ret_bytes, int err )
{
    const unsigned char *b = (const unsigned char *)buf;
    unsigned char rec = (ret_bytes >= 3 && b) ? b[0] : 0;
    struct ios_tl_ent *e = NULL;
    unsigned long long now;
    int i, freeslot = -1;

    if (fd <= 0 || err || ret_bytes <= 0) return;   /* errors carry no wire bytes */
    now = ios_tl_now();

    for (i = 0; i < IOS_TL_SLOTS; i++)
    {
        if (ios_tl_tab[i].fd == fd) { e = &ios_tl_tab[i]; break; }
        if (ios_tl_tab[i].fd <= 0 && freeslot < 0) freeslot = i;
    }

    /* Retire the old timeline when the fd number has been recycled onto a new
     * connection. ml591 shipped this test as "a fresh ClientHello arrived", which
     * MISSED every reuse by a non-TLS protocol: fd 1628's CM entry silently
     * absorbed a later port-80 connection and reported rx=26/133465B for what
     * should have been one ~4KB handshake, making its timings worthless. (Caught
     * by Sol.) A recycled fd always involves a fresh connect, so any gap since the
     * last event is the cheap, protocol-agnostic place to re-check identity —
     * bursts within a single connection skip the syscall entirely. */
    if (e && (rec == 0x16 || now - e->t_last > 20000000ull))
    {
        struct sockaddr_storage pa2;
        socklen_t pl2 = sizeof(pa2);
        unsigned short now_port = 0;

        if (!getpeername( fd, (struct sockaddr *)&pa2, &pl2 ))
        {
            if (pa2.ss_family == AF_INET) now_port = ntohs( ((const struct sockaddr_in *)&pa2)->sin_port );
            else if (pa2.ss_family == AF_INET6) now_port = ntohs( ((const struct sockaddr_in6 *)&pa2)->sin6_port );
        }
        if (now_port != e->port || (is_send && rec == 0x16 && e->t_ch))
        {
            freeslot = (int)(e - ios_tl_tab);
            ios_tl_flush( e, "abandoned" );
            e = NULL;
        }
    }

    if (!e)
    {
        struct sockaddr_storage pa;
        socklen_t pl = sizeof(pa);
        unsigned short port = 0;

        if (getpeername( fd, (struct sockaddr *)&pa, &pl ) != 0) return;  /* not connected */
        if (pa.ss_family == AF_INET)
        {
            const struct sockaddr_in *s4 = (const struct sockaddr_in *)&pa;
            if ((ntohl( s4->sin_addr.s_addr ) >> 24) == 127) return;      /* loopback */
            port = ntohs( s4->sin_port );
        }
        else if (pa.ss_family == AF_INET6) port = ntohs( ((const struct sockaddr_in6 *)&pa)->sin6_port );
        else return;

        /* Sweep on creation instead of running a timer: a socket that is closed and
         * never reused would otherwise never report its timeline. */
        for (i = 0; i < IOS_TL_SLOTS; i++)
            if (ios_tl_tab[i].fd > 0 && now - ios_tl_tab[i].t_last > 5000000000ull)
            {
                ios_tl_flush( &ios_tl_tab[i], "idle" );
                if (freeslot < 0) freeslot = i;
            }
        if (freeslot < 0) return;                                        /* table full */
        e = &ios_tl_tab[freeslot];
        memset( e, 0, sizeof(*e) );
        e->fd = fd; e->port = port; e->gen = ++ios_tl_gen; e->t0 = now;
    }

    e->t_last = now;
    if (is_send) { e->n_send++; e->b_send += (unsigned long)ret_bytes; }
    else         { e->n_recv++; e->b_recv += (unsigned long)ret_bytes; }
    if (rec == 0x15) e->alerts++;

    if (is_send)
    {
        if (rec == 0x16 && !e->t_ch) e->t_ch = now;
        else if (rec == 0x14 && !e->t_fin) e->t_fin = now;
        else if (e->t_tail && !e->t_post)
        {
            /* ANY client send after the handshake tail is the thing we have never
             * seen: the WebSocket Upgrade. Fate decided — report immediately. */
            e->t_post = now;
            e->post_len = (int)ret_bytes;
            if (b && ret_bytes >= 5) memcpy( e->post5, b, 5 );
            ios_tl_flush( e, "upgrade-sent" );
        }
    }
    else
    {
        if (rec == 0x16 && !e->t_flight) e->t_flight = now;
        else if (rec == 0x17 && !e->t_tail) e->t_tail = now;
    }
}

static void ios_sock_wire( int fd, int is_send, const void *buf, long ret_bytes, int err )
{
    static struct { int fd; unsigned short port; int n; int wouldblock; } tab[64];
    static int used, announced;
    int i, slot = -1;
    struct sockaddr_storage pa;
    socklen_t pl = sizeof(pa);
    unsigned short port = 0;
    const unsigned char *b = (const unsigned char *)buf;

    /* ml579: OFF for the timing run. Each call costs a getpeername(), and this
     * fires on every send/recv — Steam's CM ping budget is 1000 ms total.
     *
     * Also note before re-enabling: the 0x17 classifier below is WRONG FOR TLS
     * 1.3. Everything after ServerHello — EncryptedExtensions, Certificate,
     * CertificateVerify, Finished, NewSessionTicket — uses record type 0x17, so
     * "TLS-APPDATA" cannot distinguish handshake from payload. That is what led
     * me to wrongly conclude Steam had received and rejected application data;
     * the 606-byte read was in fact 2 x (5 + 298) = two NewSessionTickets, and
     * Steam never sent its request at all. A useful version must track handshake
     * state, not record type. (Caught by Sol.) */
    { static int off = -1;
      if (off < 0) { const char *e = getenv( "MADEIRA_SOCK_WIRE" ); off = !(e && *e && *e != '0'); }
      if (off) return; }
    if (getpeername( fd, (struct sockaddr *)&pa, &pl ) != 0) return;   /* not connected */
    if (pa.ss_family == AF_INET)
    {
        const struct sockaddr_in *s4 = (const struct sockaddr_in *)&pa;
        if ((ntohl( s4->sin_addr.s_addr ) >> 24) == 127) return;        /* loopback */
        port = ntohs( s4->sin_port );
    }
    else if (pa.ss_family == AF_INET6) port = ntohs( ((const struct sockaddr_in6 *)&pa)->sin6_port );
    else return;                                                        /* not INET */

    for (i = 0; i < used; i++) if (tab[i].fd == fd && tab[i].port == port) { slot = i; break; }
    if (slot < 0)
    {
        if (used >= 64) return;
        slot = used++;
        tab[slot].fd = fd; tab[slot].port = port; tab[slot].n = 0; tab[slot].wouldblock = 0;
    }
    if (!announced++)
        dprintf( 2, "[sock-wire] rev=ml578 armed (external TCP only, 5-byte peek, 12/socket)\n" );

    if (err == EWOULDBLOCK || err == EAGAIN)
    {
        if (++tab[slot].wouldblock <= 3 || (tab[slot].wouldblock % 500) == 0)
            dprintf( 2, "[sock-wire] fd=%d dport=%u %s EWOULDBLOCK #%d rev=ml578\n",
                     fd, port, is_send ? "send" : "recv", tab[slot].wouldblock );
        return;
    }
    if (tab[slot].n >= 12) return;
    tab[slot].n++;
    {
        const char *kind = "-";
        if (ret_bytes >= 3 && b)
        {
            if (b[0] == 0x16) kind = "TLS-HANDSHAKE";
            else if (b[0] == 0x15) kind = "TLS-ALERT";
            else if (b[0] == 0x17) kind = "TLS-APPDATA";
            else if (b[0] == 0x14) kind = "TLS-CCS";
            else if (b[0] == 'H' || b[0] == 'G' || b[0] == 'P') kind = "HTTP-ish";
        }
        dprintf( 2, "[sock-wire] fd=%d dport=%u %s ret=%ld errno=%d first5=%02x %02x %02x %02x %02x %s rev=ml578\n",
                 fd, port, is_send ? "SEND" : "RECV", ret_bytes, err,
                 (ret_bytes > 0 && b) ? b[0] : 0, (ret_bytes > 1 && b) ? b[1] : 0,
                 (ret_bytes > 2 && b) ? b[2] : 0, (ret_bytes > 3 && b) ? b[3] : 0,
                 (ret_bytes > 4 && b) ? b[4] : 0, kind );
    }
}

static void ios_sock_big_note( int fd, int is_send, long ret_bytes, int err )
{
    static struct { int fd; unsigned long long tot[2]; unsigned long long next[2]; } tab[64];
    static int err_logs;
    int i, slot = -1;

    if (err)
    {
        if (err != EWOULDBLOCK && err != EAGAIN && err != EINTR && err_logs < 64)
        {
            err_logs++;
            dprintf( 2, "[sock-big] %s ERROR fd=%d errno=%d rev=ml464\n", is_send ? "send" : "recv", fd, err );
        }
        return;
    }
    if (ret_bytes <= 0) return;
    for (i = 0; i < 64; i++)
    {
        if (tab[i].fd == fd) { slot = i; break; }
        if (slot < 0 && !tab[i].fd) slot = i;
    }
    if (slot < 0) return;
    if (tab[slot].fd != fd)
    {
        tab[slot].fd = fd;
        tab[slot].tot[0] = tab[slot].tot[1] = 0;
        tab[slot].next[0] = tab[slot].next[1] = 0x20000;
    }
    tab[slot].tot[is_send] += (unsigned long long)ret_bytes;
    if (tab[slot].tot[is_send] >= tab[slot].next[is_send])
    {
        union unix_sockaddr peer;
        socklen_t plen = sizeof(peer);
        int pport = -1;
        if (!getpeername( fd, &peer.addr, &plen ) && peer.addr.sa_family == AF_INET)
            pport = ntohs( peer.in.sin_port );
        dprintf( 2, "[sock-big] %s fd=%d total=%lluKB peer_port=%d rev=ml464\n",
                 is_send ? "send" : "recv", fd, tab[slot].tot[is_send] >> 10, pport );
        tab[slot].next[is_send] = tab[slot].tot[is_send] + 0x80000;
    }
}
/* iOS-Madeira ml469 (wall #79 transport): the ml468 run showed steamwebhelper
 * re-dialing ws://localhost:6252x/transportsocket/ every ~5s forever, with the
 * only connect evidence being IPv6 EHOSTUNREACH + IPv4 EINPROGRESS and no
 * completion, while steam.exe's own connectivity test reported NoLAN.  Nothing
 * on record proves TCP loopback works AT ALL under this port, so measure it
 * directly, below wine: bind a listener on 127.0.0.1:0, non-blocking connect
 * to it, poll for writability, read SO_ERROR, accept, and pass one byte each
 * way.  Whatever step fails names the layer.  IPv6 ::1 is probed too, since
 * the guest's first choice is what returned EHOSTUNREACH. */
#include <poll.h>
#include <fcntl.h>
#include <arpa/inet.h>
void ios_loopback_selftest(void)
{
    struct sockaddr_in a4 = { 0 };
    socklen_t len = sizeof(a4);
    int ls = -1, cs = -1, as = -1, err = 0, flags, port = 0;
    socklen_t elen = sizeof(err);
    struct pollfd pfd;
    char tx = 0x5a, rx = 0;
    ssize_t n;

    if ((ls = socket( AF_INET, SOCK_STREAM, 0 )) < 0)
    { dprintf( 2, "[loopback] FAIL socket errno=%d rev=ml469\n", errno ); return; }
    a4.sin_family = AF_INET;
    a4.sin_addr.s_addr = htonl( INADDR_LOOPBACK );
    a4.sin_port = 0;
    if (bind( ls, (struct sockaddr *)&a4, sizeof(a4) ) < 0)
    { dprintf( 2, "[loopback] FAIL bind errno=%d rev=ml469\n", errno ); goto done; }
    if (listen( ls, 1 ) < 0)
    { dprintf( 2, "[loopback] FAIL listen errno=%d rev=ml469\n", errno ); goto done; }
    if (getsockname( ls, (struct sockaddr *)&a4, &len ) < 0)
    { dprintf( 2, "[loopback] FAIL getsockname errno=%d rev=ml469\n", errno ); goto done; }
    port = ntohs( a4.sin_port );

    if ((cs = socket( AF_INET, SOCK_STREAM, 0 )) < 0)
    { dprintf( 2, "[loopback] FAIL socket2 errno=%d rev=ml469\n", errno ); goto done; }
    flags = fcntl( cs, F_GETFL, 0 );
    fcntl( cs, F_SETFL, flags | O_NONBLOCK );
    if (connect( cs, (struct sockaddr *)&a4, sizeof(a4) ) < 0 && errno != EINPROGRESS)
    { dprintf( 2, "[loopback] FAIL connect port=%d errno=%d rev=ml469\n", port, errno ); goto done; }

    pfd.fd = cs; pfd.events = POLLOUT; pfd.revents = 0;
    n = poll( &pfd, 1, 2000 );
    if (n <= 0)
    { dprintf( 2, "[loopback] FAIL connect-poll port=%d ret=%d errno=%d (never writable in 2s) rev=ml469\n",
               port, (int)n, errno ); goto done; }
    if (getsockopt( cs, SOL_SOCKET, SO_ERROR, &err, &elen ) < 0 || err)
    { dprintf( 2, "[loopback] FAIL connect-so_error port=%d so_error=%d revents=0x%x rev=ml469\n",
               port, err, pfd.revents ); goto done; }

    if ((as = accept( ls, NULL, NULL )) < 0)
    { dprintf( 2, "[loopback] FAIL accept port=%d errno=%d rev=ml469\n", port, errno ); goto done; }
    if ((n = send( cs, &tx, 1, 0 )) != 1)
    { dprintf( 2, "[loopback] FAIL send port=%d ret=%d errno=%d rev=ml469\n", port, (int)n, errno ); goto done; }
    pfd.fd = as; pfd.events = POLLIN; pfd.revents = 0;
    if (poll( &pfd, 1, 2000 ) <= 0)
    { dprintf( 2, "[loopback] FAIL recv-poll port=%d (byte never arrived in 2s) rev=ml469\n", port ); goto done; }
    if ((n = recv( as, &rx, 1, 0 )) != 1 || rx != tx)
    { dprintf( 2, "[loopback] FAIL recv port=%d ret=%d byte=0x%02x errno=%d rev=ml469\n",
               port, (int)n, rx, errno ); goto done; }
    dprintf( 2, "[loopback] OK ipv4 127.0.0.1:%d connect+accept+1-byte roundtrip rev=ml469\n", port );

done:
    if (as >= 0) close( as );
    if (cs >= 0) close( cs );
    if (ls >= 0) close( ls );

#ifdef AF_INET6
    {
        struct sockaddr_in6 a6 = { 0 };
        int l6 = -1, c6 = -1;
        socklen_t l6len = sizeof(a6);
        a6.sin6_family = AF_INET6;
        a6.sin6_addr = in6addr_loopback;
        if ((l6 = socket( AF_INET6, SOCK_STREAM, 0 )) < 0)
        { dprintf( 2, "[loopback] ipv6 no socket errno=%d rev=ml469\n", errno ); return; }
        if (bind( l6, (struct sockaddr *)&a6, sizeof(a6) ) < 0 || listen( l6, 1 ) < 0 ||
            getsockname( l6, (struct sockaddr *)&a6, &l6len ) < 0)
        { dprintf( 2, "[loopback] ipv6 bind/listen FAIL errno=%d rev=ml469\n", errno ); close( l6 ); return; }
        if ((c6 = socket( AF_INET6, SOCK_STREAM, 0 )) >= 0)
        {
            /* non-blocking like the v4 leg: a blackholed SYN must cost 2s,
             * not the platform connect timeout, on the monitor thread */
            int f6 = fcntl( c6, F_GETFL, 0 );
            int r, e6 = 0;
            socklen_t e6len = sizeof(e6);
            fcntl( c6, F_SETFL, f6 | O_NONBLOCK );
            r = connect( c6, (struct sockaddr *)&a6, sizeof(a6) );
            if (r < 0 && errno == EINPROGRESS)
            {
                struct pollfd p6;
                p6.fd = c6; p6.events = POLLOUT; p6.revents = 0;
                if (poll( &p6, 1, 2000 ) <= 0) e6 = ETIMEDOUT;
                else if (getsockopt( c6, SOL_SOCKET, SO_ERROR, &e6, &e6len ) < 0) e6 = errno;
                r = e6 ? -1 : 0;
            }
            else if (r < 0) e6 = errno;
            dprintf( 2, "[loopback] ipv6 [::1]:%d connect ret=%d errno=%d rev=ml469\n",
                     ntohs( a6.sin6_port ), r, e6 );
            close( c6 );
        }
        close( l6 );
    }
#endif
}

#else
#define ios_sock_big_note( fd, is_send, ret_bytes, err ) do { } while (0)
#define ios_sock_wire( fd, is_send, buf, ret_bytes, err ) do { } while (0)
#define ios_sock_tl( fd, is_send, buf, ret_bytes, err ) do { } while (0)
#endif

static NTSTATUS try_recv( int fd, struct async_recv_ioctl *async, ULONG_PTR *size )
{
    char control_buffer[512];
    union unix_sockaddr unix_addr;
    struct msghdr hdr;
    NTSTATUS status;
    ssize_t ret;

    memset( &hdr, 0, sizeof(hdr) );
    if (async->addr || async->icmp_over_dgram)
    {
        hdr.msg_name = &unix_addr.addr;
        hdr.msg_namelen = sizeof(unix_addr);
    }
    hdr.msg_iov = async->iov;
    hdr.msg_iovlen = async->count;
    hdr.msg_control = control_buffer;
    hdr.msg_controllen = sizeof(control_buffer);

    while ((ret = virtual_locked_recvmsg( fd, &hdr, async->unix_flags )) < 0 && errno == EINTR);

    if (ret < 0)
    {
        /* Unix-like systems return EINVAL when attempting to read OOB data from
         * an empty socket buffer; Windows returns WSAEWOULDBLOCK. */
        if ((async->unix_flags & MSG_OOB) && errno == EINVAL)
            errno = EWOULDBLOCK;

        if (errno != EWOULDBLOCK) WARN( "recvmsg: %s\n", strerror( errno ) );
        ios_sock_big_note( fd, 0, 0, errno );
        ios_sock_wire( fd, 0, NULL, 0, errno );
        ios_sock_tl( fd, 0, NULL, 0, errno );
        return sock_errno_to_status( errno );
    }
    ios_sock_big_note( fd, 0, ret, 0 );
    ios_sock_wire( fd, 0, (async->count && async->iov) ? async->iov[0].iov_base : NULL, ret, 0 );
    ios_sock_tl( fd, 0, (async->count && async->iov) ? async->iov[0].iov_base : NULL, ret, 0 );

    status = (hdr.msg_flags & MSG_TRUNC) ? STATUS_BUFFER_OVERFLOW : STATUS_SUCCESS;
    if (async->icmp_over_dgram)
        ret = fixup_icmp_over_dgram( &hdr, &unix_addr, async->io.handle, ret, &status );

    if (async->control)
    {
        if (async->icmp_over_dgram)
            FIXME( "May return extra control headers.\n" );

        if (in_wow64_call())
        {
            char control_buffer64[512];
            WSABUF wsabuf;

            wsabuf.len = sizeof(control_buffer64);
            wsabuf.buf = control_buffer64;
            if (convert_control_headers( &hdr, &wsabuf ))
            {
                if (!wow64_translate_control( &wsabuf, async->control ))
                {
                    WARN( "Application passed insufficient room for control headers.\n" );
                    *async->ret_flags |= WS_MSG_CTRUNC;
                    status = STATUS_BUFFER_OVERFLOW;
                }
            }
            else
            {
                FIXME( "control buffer is too small\n" );
                *async->ret_flags |= WS_MSG_CTRUNC;
                status = STATUS_BUFFER_OVERFLOW;
            }
        }
        else
        {
            if (!convert_control_headers( &hdr, async->control ))
            {
                WARN( "Application passed insufficient room for control headers.\n" );
                *async->ret_flags |= WS_MSG_CTRUNC;
                status = STATUS_BUFFER_OVERFLOW;
            }
        }
    }

    /* If this socket is connected, Linux doesn't give us msg_name and
     * msg_namelen from recvmsg, but it does set msg_namelen to zero.
     *
     * MSDN says that the address is ignored for connection-oriented sockets, so
     * don't try to translate it.
     */
    if (async->addr && hdr.msg_namelen)
        *async->addr_len = sockaddr_from_unix( &unix_addr, async->addr, *async->addr_len );

    *size = ret;
    return status;
}

static BOOL async_recv_proc( void *user, ULONG_PTR *info, unsigned int *status )
{
    struct async_recv_ioctl *async = user;
    int fd, needs_close;

    TRACE( "%#x\n", *status );

    if (*status == STATUS_ALERTED)
    {
        if ((*status = server_get_unix_fd( async->io.handle, 0, &fd, &needs_close, NULL, NULL )))
            return TRUE;

        *status = try_recv( fd, async, info );
        TRACE( "got status %#x, %#lx bytes read\n", *status, *info );
        if (needs_close) close( fd );

        if (*status == STATUS_DEVICE_NOT_READY)
            return FALSE;
    }
    release_fileio( &async->io );
    return TRUE;
}

static BOOL is_icmp_over_dgram( int fd )
{
#ifdef linux
    socklen_t len;
    int val;

    len = sizeof(val);
    if (getsockopt( fd, SOL_SOCKET, SO_PROTOCOL, (char *)&val, &len ) || (val != IPPROTO_ICMP && val != IPPROTO_ICMPV6))
        return FALSE;

    len = sizeof(val);
    return !getsockopt( fd, SOL_SOCKET, SO_TYPE, (char *)&val, &len ) && val == SOCK_DGRAM;
#else
    return FALSE;
#endif
}

static NTSTATUS sock_recv( HANDLE handle, HANDLE event, PIO_APC_ROUTINE apc, void *apc_user, IO_STATUS_BLOCK *io,
                           int fd, struct async_recv_ioctl *async, int force_async )
{
    HANDLE wait_handle;
    BOOL nonblocking;
    unsigned int i, status;
    ULONG options;

    for (i = 0; i < async->count; ++i)
    {
        if (!virtual_check_buffer_for_write( async->iov[i].iov_base, async->iov[i].iov_len ))
        {
            release_fileio( &async->io );
            return STATUS_ACCESS_VIOLATION;
        }
    }

    SERVER_START_REQ( recv_socket )
    {
        req->force_async = force_async;
        req->async  = server_async( handle, &async->io, event, apc, apc_user, iosb_client_ptr(io) );
        req->oob    = !!(async->unix_flags & MSG_OOB);
        status = wine_server_call( req );
        wait_handle = wine_server_ptr_handle( reply->wait );
        options     = reply->options;
        nonblocking = reply->nonblocking;
    }
    SERVER_END_REQ;

    /* the server currently will never succeed immediately */
    assert(status == STATUS_ALERTED || status == STATUS_PENDING || NT_ERROR(status));

    if (status == STATUS_ALERTED)
    {
        ULONG_PTR information;

        status = try_recv( fd, async, &information );
        if (status == STATUS_DEVICE_NOT_READY && (force_async || !nonblocking))
            status = STATUS_PENDING;
        set_async_direct_result( &wait_handle, options, io, status, information, FALSE );
    }

    if (status != STATUS_PENDING)
        release_fileio( &async->io );

    if (wait_handle) status = wait_async( wait_handle, options & FILE_SYNCHRONOUS_IO_ALERT );
    return status;
}


static NTSTATUS sock_ioctl_recv( HANDLE handle, HANDLE event, PIO_APC_ROUTINE apc, void *apc_user, IO_STATUS_BLOCK *io,
                                 int fd, const void *buffers_ptr, unsigned int count, WSABUF *control,
                                 struct WS_sockaddr *addr, int *addr_len, unsigned int *ret_flags, int unix_flags, int force_async )
{
    struct async_recv_ioctl *async;
    DWORD async_size;
    unsigned int i;

    if (unix_flags & MSG_OOB)
    {
        int oobinline;
        socklen_t len = sizeof(oobinline);
        if (!getsockopt( fd, SOL_SOCKET, SO_OOBINLINE, (char *)&oobinline, &len ) && oobinline)
            return STATUS_INVALID_PARAMETER;
    }

    async_size = offsetof( struct async_recv_ioctl, iov[count] );

    if (!(async = (struct async_recv_ioctl *)alloc_fileio( async_size, async_recv_proc, handle )))
        return STATUS_NO_MEMORY;

    async->count = count;
    if (in_wow64_call())
    {
        const struct afd_wsabuf_32 *buffers = buffers_ptr;

        for (i = 0; i < count; ++i)
        {
            async->iov[i].iov_base = ULongToPtr( buffers[i].buf );
            async->iov[i].iov_len = buffers[i].len;
        }
    }
    else
    {
        const WSABUF *buffers = buffers_ptr;

        for (i = 0; i < count; ++i)
        {
            async->iov[i].iov_base = buffers[i].buf;
            async->iov[i].iov_len = buffers[i].len;
        }
    }
    async->unix_flags = unix_flags;
    async->control = control;
    async->addr = addr;
    async->addr_len = addr_len;
    async->ret_flags = ret_flags;
    async->icmp_over_dgram = is_icmp_over_dgram( fd );

    return sock_recv( handle, event, apc, apc_user, io, fd, async, force_async );
}


NTSTATUS sock_read( HANDLE handle, int fd, HANDLE event, PIO_APC_ROUTINE apc,
                    void *apc_user, IO_STATUS_BLOCK *io, void *buffer, ULONG length )
{
    static const DWORD async_size = offsetof( struct async_recv_ioctl, iov[1] );
    struct async_recv_ioctl *async;

    if (!(async = (struct async_recv_ioctl *)alloc_fileio( async_size, async_recv_proc, handle )))
        return STATUS_NO_MEMORY;

    async->count = 1;
    async->iov[0].iov_base = buffer;
    async->iov[0].iov_len = length;
    async->unix_flags = 0;
    async->control = NULL;
    async->addr = NULL;
    async->addr_len = NULL;
    async->ret_flags = NULL;
    async->icmp_over_dgram = is_icmp_over_dgram( fd );

    return sock_recv( handle, event, apc, apc_user, io, fd, async, 1 );
}


static NTSTATUS try_send( int fd, struct async_send_ioctl *async )
{
    union unix_sockaddr unix_addr;
    struct msghdr hdr;
    int attempt = 0;
    int sock_type;
    socklen_t len = sizeof(sock_type);
    ssize_t ret;

    getsockopt(fd, SOL_SOCKET, SO_TYPE, &sock_type, &len);

    memset( &hdr, 0, sizeof(hdr) );
    if (async->addr && sock_type != SOCK_STREAM)
    {
        hdr.msg_name = &unix_addr;
        hdr.msg_namelen = sockaddr_to_unix( async->addr, async->addr_len, &unix_addr );
        if (!hdr.msg_namelen)
        {
            ERR( "failed to convert address\n" );
            return STATUS_ACCESS_VIOLATION;
        }
        if (sock_type == SOCK_DGRAM && ((unix_addr.addr.sa_family == AF_INET && !unix_addr.in.sin_port)
            || (unix_addr.addr.sa_family == AF_INET6 && !unix_addr.in6.sin6_port)))
        {
            /* Sending to port 0 succeeds on Windows. Use 'discard' service instead so sendmsg() works on Unix
             * while still goes through other parameters validation. */
            WARN( "Trying to use destination port 0, substituing 9.\n" );
            unix_addr.in.sin_port = htons( 9 );
        }

#if defined(HAS_IPX) && defined(SOL_IPX)
        if (async->addr->sa_family == WS_AF_IPX)
        {
            int type;
            socklen_t len = sizeof(type);

            /* The packet type is stored at the IPX socket level. At least the
             * linux kernel seems to do something with it in case hdr.msg_name
             * is NULL. Nonetheless we can use it to store the packet type, and
             * then we can retrieve it using getsockopt. After that we can set
             * the IPX type in the sockaddr_ipx structure with the stored value.
             */
            if (getsockopt(fd, SOL_IPX, IPX_TYPE, &type, &len) >= 0)
                unix_addr.ipx.sipx_type = type;
        }
#endif
    }

    hdr.msg_iov = async->iov + async->iov_cursor;
    hdr.msg_iovlen = async->count - async->iov_cursor;

    while ((ret = sendmsg( fd, &hdr, async->unix_flags )) == -1)
    {
        if (errno == EISCONN)
        {
            hdr.msg_name = NULL;
            hdr.msg_namelen = 0;
        }
        else if (errno != EINTR)
        {
            if (errno != EWOULDBLOCK) WARN( "sendmsg: %s\n", strerror( errno ) );

            /* ECONNREFUSED may be returned if this is connected datagram socket and the system received
             * ICMP "destination port unreachable" message from the peer. That is ignored
             * on Windows. The first sendmsg() will clear the error in this case and the next
             * call should succeed. */
            if (!attempt && errno == ECONNREFUSED)
            {
                ++attempt;
                continue;
            }

            ios_sock_big_note( fd, 1, 0, errno );
            ios_sock_wire( fd, 1, NULL, 0, errno );
            ios_sock_tl( fd, 1, NULL, 0, errno );
            return sock_errno_to_status( errno );
        }
    }

    async->sent_len += ret;
    ios_sock_big_note( fd, 1, ret, 0 );
    ios_sock_wire( fd, 1, (async->count && async->iov) ? async->iov[0].iov_base : NULL, ret, 0 );
    ios_sock_tl( fd, 1, (async->count && async->iov) ? async->iov[0].iov_base : NULL, ret, 0 );

    while (async->iov_cursor < async->count && ret >= async->iov[async->iov_cursor].iov_len)
        ret -= async->iov[async->iov_cursor++].iov_len;
    if (async->iov_cursor < async->count)
    {
        async->iov[async->iov_cursor].iov_base = (char *)async->iov[async->iov_cursor].iov_base + ret;
        async->iov[async->iov_cursor].iov_len -= ret;
        return STATUS_DEVICE_NOT_READY;
    }
    return STATUS_SUCCESS;
}

static BOOL async_send_proc( void *user, ULONG_PTR *info, unsigned int *status )
{
    struct async_send_ioctl *async = user;
    int fd, needs_close;

    TRACE( "%#x\n", *status );

    if (*status == STATUS_ALERTED)
    {
        needs_close = FALSE;
        if ((fd = async->fd) == -1 && (*status = server_get_unix_fd( async->io.handle, 0, &fd, &needs_close, NULL, NULL )))
            return TRUE;

        *status = try_send( fd, async );
        TRACE( "got status %#x\n", *status );

        if (needs_close) close( fd );

        if (*status == STATUS_DEVICE_NOT_READY)
            return FALSE;
    }
    *info = async->sent_len;
    if (async->fd != -1) close( async->fd );
    release_fileio( &async->io );
    return TRUE;
}

static void sock_save_icmp_id( struct async_send_ioctl *async )
{
    unsigned short id, seq;
    struct icmp_hdr *h;

    if (async->count != 1 || async->iov[0].iov_len < sizeof(*h))
    {
        FIXME( "ICMP over DGRAM fixup is not supported for count %u, len %zu.\n", async->count, async->iov[0].iov_len );
        return;
    }

    h = async->iov[0].iov_base;
    id = h->un.echo.id;
    seq = h->un.echo.sequence;
    SERVER_START_REQ( socket_send_icmp_id )
    {
        req->handle = wine_server_obj_handle( async->io.handle );
        req->icmp_id = id;
        req->icmp_seq = seq;
        if (wine_server_call( req ))
            WARN( "socket_fixup_send_data failed.\n" );
    }
    SERVER_END_REQ;
}

static NTSTATUS sock_send( HANDLE handle, HANDLE event, PIO_APC_ROUTINE apc, void *apc_user,
                           IO_STATUS_BLOCK *io, int fd, struct async_send_ioctl *async, unsigned int server_flags )
{
    HANDLE wait_handle;
    BOOL nonblocking;
    unsigned int status;
    ULONG options;

    SERVER_START_REQ( send_socket )
    {
        req->flags = server_flags;
        req->async  = server_async( handle, &async->io, event, apc, apc_user, iosb_client_ptr(io) );
        status = wine_server_call( req );
        wait_handle = wine_server_ptr_handle( reply->wait );
        options     = reply->options;
        nonblocking = reply->nonblocking;
    }
    SERVER_END_REQ;

    /* the server currently will never succeed immediately */
    assert(status == STATUS_ALERTED || status == STATUS_PENDING || NT_ERROR(status));

    if (!NT_ERROR(status) && is_icmp_over_dgram( fd ))
        sock_save_icmp_id( async );

    if (status == STATUS_ALERTED)
    {
        status = try_send( fd, async );
        if (status == STATUS_DEVICE_NOT_READY && ((server_flags & SERVER_SOCKET_IO_FORCE_ASYNC) || !nonblocking))
            status = STATUS_PENDING;

        /* If we had a short write and the socket is nonblocking (and we are
         * not trying to force the operation to be asynchronous), return
         * success, pretened we've written everything to the socket and queue writing
         * remaining data. Windows never reports partial write in this case and queues
         * virtually unlimited amount of data for background write in this case. */
        if (status == STATUS_DEVICE_NOT_READY && async->sent_len && async->iov_cursor < async->count)
        {
            struct iovec *iov = async->iov + async->iov_cursor;
            SIZE_T data_size, async_size, addr_size;
            struct async_send_ioctl *rem_async;
            unsigned int i, iov_count;
            IO_STATUS_BLOCK *rem_io;
            char *p;

            TRACE( "Short write, queueing remaining data.\n" );
            data_size = 0;
            iov_count = async->count - async->iov_cursor;
            for (i = 0; i < iov_count; ++i)
                data_size += iov[i].iov_len;

            addr_size = max( 0, async->addr_len );
            async_size = offsetof( struct async_send_ioctl, iov[1] ) + data_size + addr_size
                         + sizeof(IO_STATUS_BLOCK) + sizeof(IO_STATUS_BLOCK32);
            if (!(rem_async = (struct async_send_ioctl *)alloc_fileio( async_size, async_send_proc, handle )))
            {
                status = STATUS_NO_MEMORY;
            }
            else
            {
                /* Use a local copy of socket fd so the async send works after socket handle is closed. */
                rem_async->fd = dup( fd );
                rem_async->count = 1;
                p = (char *)rem_async + offsetof( struct async_send_ioctl, iov[1] );
                rem_async->iov[0].iov_base = p;
                rem_async->iov[0].iov_len = data_size;
                for (i = 0; i < iov_count; ++i)
                {
                    memcpy( p, iov[i].iov_base, iov[i].iov_len );
                    p += iov[i].iov_len;
                }
                rem_async->unix_flags = async->unix_flags;
                memcpy( p, async->addr, addr_size );
                rem_async->addr = (const struct WS_sockaddr *)p;
                p += addr_size;
                rem_async->addr_len = async->addr_len;
                rem_async->iov_cursor = 0;
                rem_async->sent_len = 0;
                rem_io = (IO_STATUS_BLOCK *)p;
                p += sizeof(IO_STATUS_BLOCK);
                rem_io->Pointer = p;
                p += sizeof(IO_STATUS_BLOCK32);
                status = sock_send( handle, NULL, NULL, NULL, rem_io, fd, rem_async,
                                    SERVER_SOCKET_IO_FORCE_ASYNC | SERVER_SOCKET_IO_SYSTEM );
                if (status == STATUS_PENDING) status = STATUS_SUCCESS;
                if (!status)
                {
                    async->sent_len += data_size;
                    async->iov_cursor = async->count;
                }
                else ERR( "Remaining write queue failed, status %#x.\n", status );
            }
        }

        set_async_direct_result( &wait_handle, options, io, status, async->sent_len, FALSE );
    }

    if (status != STATUS_PENDING)
    {
        if (async->fd != -1) close( async->fd );
        release_fileio( &async->io );
    }

    if (wait_handle) status = wait_async( wait_handle, options & FILE_SYNCHRONOUS_IO_ALERT );
    return status;
}

static NTSTATUS sock_ioctl_send( HANDLE handle, HANDLE event, PIO_APC_ROUTINE apc, void *apc_user,
                                 IO_STATUS_BLOCK *io, int fd, const void *buffers_ptr, unsigned int count,
                                 const struct WS_sockaddr *addr, unsigned int addr_len, int unix_flags, int force_async )
{
    struct async_send_ioctl *async;
    DWORD async_size;
    unsigned int i;

    async_size = offsetof( struct async_send_ioctl, iov[count] );

    if (!(async = (struct async_send_ioctl *)alloc_fileio( async_size, async_send_proc, handle )))
        return STATUS_NO_MEMORY;

    async->count = count;
    if (in_wow64_call())
    {
        const struct afd_wsabuf_32 *buffers = buffers_ptr;

        for (i = 0; i < count; ++i)
        {
            async->iov[i].iov_base = ULongToPtr( buffers[i].buf );
            async->iov[i].iov_len = buffers[i].len;
        }
    }
    else
    {
        const WSABUF *buffers = buffers_ptr;

        for (i = 0; i < count; ++i)
        {
            async->iov[i].iov_base = buffers[i].buf;
            async->iov[i].iov_len = buffers[i].len;
        }
    }
    async->fd = -1;
    async->unix_flags = unix_flags;
    async->addr = addr;
    async->addr_len = addr_len;
    async->iov_cursor = 0;
    async->sent_len = 0;

    return sock_send( handle, event, apc, apc_user, io, fd, async, force_async ? SERVER_SOCKET_IO_FORCE_ASYNC : 0 );
}


NTSTATUS sock_write( HANDLE handle, int fd, HANDLE event, PIO_APC_ROUTINE apc,
                     void *apc_user, IO_STATUS_BLOCK *io, const void *buffer, ULONG length )
{
    static const DWORD async_size = offsetof( struct async_send_ioctl, iov[1] );
    struct async_send_ioctl *async;

    if (!(async = (struct async_send_ioctl *)alloc_fileio( async_size, async_send_proc, handle )))
        return STATUS_NO_MEMORY;

    async->fd = -1;
    async->count = 1;
    async->iov[0].iov_base = (void *)buffer;
    async->iov[0].iov_len = length;
    async->unix_flags = 0;
    async->addr = NULL;
    async->addr_len = 0;
    async->iov_cursor = 0;
    async->sent_len = 0;

    return sock_send( handle, event, apc, apc_user, io, fd, async, SERVER_SOCKET_IO_FORCE_ASYNC );
}


static ssize_t do_send( int fd, const void *buffer, size_t len, int flags )
{
    ssize_t ret;
    while ((ret = send( fd, buffer, len, flags )) < 0 && errno == EINTR);
    if (ret < 0 && errno != EWOULDBLOCK) WARN( "send: %s\n", strerror( errno ) );
    /* ml464: this is the TransmitFile data path — steam's HTTP server serving
     * static steamui files lands here. */
    ios_sock_big_note( fd, 1, ret < 0 ? 0 : ret, ret < 0 ? errno : 0 );
    return ret;
}

static NTSTATUS try_transmit( int sock_fd, int file_fd, struct async_transmit_ioctl *async )
{
    ssize_t ret;

    while (async->head_cursor < async->head_len)
    {
        TRACE( "sending %u bytes of header data\n", async->head_len - async->head_cursor );
        ret = do_send( sock_fd, async->head + async->head_cursor,
                       async->head_len - async->head_cursor, 0 );
        if (ret < 0) return sock_errno_to_status( errno );
        TRACE( "send returned %zd\n", ret );
        async->head_cursor += ret;
    }

    while (async->buffer_cursor < async->read_len)
    {
        TRACE( "sending %u bytes of file data\n", async->read_len - async->buffer_cursor );
        ret = do_send( sock_fd, async->buffer + async->buffer_cursor,
                       async->read_len - async->buffer_cursor, 0 );
        if (ret < 0) return sock_errno_to_status( errno );
        TRACE( "send returned %zd\n", ret );
        async->buffer_cursor += ret;
        async->file_cursor += ret;
    }

    if (async->file && async->buffer_cursor == async->read_len)
    {
        unsigned int read_size = async->buffer_size;

        if (async->file_len)
            read_size = min( read_size, async->file_len - async->file_cursor );

        TRACE( "reading %u bytes of file data\n", read_size );
        do
        {
            if (async->offset.QuadPart == FILE_USE_FILE_POINTER_POSITION)
                ret = read( file_fd, async->buffer, read_size );
            else
                ret = pread( file_fd, async->buffer, read_size, async->offset.QuadPart );
        } while (ret < 0 && errno == EINTR);
#ifdef __APPLE__
        /* ml464 (#78): a TransmitFile whose SOCKET sends look clean but whose
         * transfer stops implicates this read — name it. */
        if (ret < 0)
        {
            static int xmit_read_logs;
            if (xmit_read_logs < 16)
            {
                xmit_read_logs++;
                dprintf( 2, "[sock-big] transmit FILE-READ ERROR file_fd=%d errno=%d read_size=%u file_cursor=%u rev=ml464\n",
                         file_fd, errno, read_size, (unsigned)async->file_cursor );
            }
        }
#endif
        if (ret < 0) return errno_to_status( errno );
        TRACE( "read returned %zd\n", ret );

        async->read_len = ret;
        async->buffer_cursor = 0;
        if (async->offset.QuadPart != FILE_USE_FILE_POINTER_POSITION)
            async->offset.QuadPart += ret;

        if (ret < read_size || (async->file_len && async->file_cursor == async->file_len))
            async->file = NULL;
        return STATUS_DEVICE_NOT_READY; /* still more data to send */
    }

    while (async->tail_cursor < async->tail_len)
    {
        TRACE( "sending %u bytes of tail data\n", async->tail_len - async->tail_cursor );
        ret = do_send( sock_fd, async->tail + async->tail_cursor,
                       async->tail_len - async->tail_cursor, 0 );
        if (ret < 0) return sock_errno_to_status( errno );
        TRACE( "send returned %zd\n", ret );
        async->tail_cursor += ret;
    }

    return STATUS_SUCCESS;
}

static BOOL async_transmit_proc( void *user, ULONG_PTR *info, unsigned int *status )
{
    int sock_fd, file_fd = -1, sock_needs_close = FALSE, file_needs_close = FALSE;
    struct async_transmit_ioctl *async = user;

    TRACE( "%#x\n", *status );

    if (*status == STATUS_ALERTED)
    {
        if ((*status = server_get_unix_fd( async->io.handle, 0, &sock_fd, &sock_needs_close, NULL, NULL )))
            return TRUE;

        if (async->file && (*status = server_get_unix_fd( async->file, 0, &file_fd, &file_needs_close, NULL, NULL )))
        {
            if (sock_needs_close) close( sock_fd );
            return TRUE;
        }

        *status = try_transmit( sock_fd, file_fd, async );
        TRACE( "got status %#x\n", *status );

        if (sock_needs_close) close( sock_fd );
        if (file_needs_close) close( file_fd );

        if (*status == STATUS_DEVICE_NOT_READY)
            return FALSE;
    }
    *info = async->head_cursor + async->file_cursor + async->tail_cursor;
    release_fileio( &async->io );
    return TRUE;
}

static NTSTATUS sock_transmit( HANDLE handle, HANDLE event, PIO_APC_ROUTINE apc, void *apc_user,
                               IO_STATUS_BLOCK *io, int fd, const struct afd_transmit_params *params )
{
    int file_fd, file_needs_close = FALSE;
    struct async_transmit_ioctl *async;
    enum server_fd_type file_type;
    union unix_sockaddr addr;
    socklen_t addr_len;
    HANDLE wait_handle;
    unsigned int status;
    ULONG options;

    addr_len = sizeof(addr);
    if (getpeername( fd, &addr.addr, &addr_len ) != 0)
        return STATUS_INVALID_CONNECTION;

    if (params->file)
    {
        if ((status = server_get_unix_fd( ULongToHandle( params->file ), 0, &file_fd, &file_needs_close, &file_type, NULL )))
            return status;
        if (file_needs_close) close( file_fd );

        if (file_type != FD_TYPE_FILE)
        {
            FIXME( "unsupported file type %#x\n", file_type );
            return STATUS_NOT_IMPLEMENTED;
        }
    }

    if (!(async = (struct async_transmit_ioctl *)alloc_fileio( sizeof(*async), async_transmit_proc, handle )))
        return STATUS_NO_MEMORY;

    async->file = ULongToHandle( params->file );
    async->buffer_size = params->buffer_size ? params->buffer_size : 65536;
    if (!(async->buffer = malloc( async->buffer_size )))
    {
        release_fileio( &async->io );
        return STATUS_NO_MEMORY;
    }
    async->read_len = 0;
    async->head_cursor = 0;
    async->file_cursor = 0;
    async->buffer_cursor = 0;
    async->tail_cursor = 0;
    async->file_len = params->file_len;
    async->flags = params->flags;
    async->head = u64_to_user_ptr(params->head_ptr);
    async->head_len = params->head_len;
    async->tail = u64_to_user_ptr(params->tail_ptr);
    async->tail_len = params->tail_len;
    async->offset = params->offset;

    SERVER_START_REQ( send_socket )
    {
        req->flags = SERVER_SOCKET_IO_FORCE_ASYNC;
        req->async  = server_async( handle, &async->io, event, apc, apc_user, iosb_client_ptr(io) );
        status = wine_server_call( req );
        wait_handle = wine_server_ptr_handle( reply->wait );
        options     = reply->options;
    }
    SERVER_END_REQ;

    /* the server currently will never succeed immediately */
    assert(status == STATUS_ALERTED || status == STATUS_PENDING || NT_ERROR(status));

    if (status == STATUS_ALERTED)
    {
        ULONG_PTR information;

        status = try_transmit( fd, file_fd, async );
        if (status == STATUS_DEVICE_NOT_READY)
            status = STATUS_PENDING;

        information = async->head_cursor + async->file_cursor + async->tail_cursor;
        set_async_direct_result( &wait_handle, options, io, status, information, TRUE );
    }

    if (status != STATUS_PENDING)
        release_fileio( &async->io );

    if (!status && !(options & (FILE_SYNCHRONOUS_IO_ALERT | FILE_SYNCHRONOUS_IO_NONALERT)))
    {
        /* Pretend we always do async I/O.  The client can always retrieve
         * the actual I/O status via the IO_STATUS_BLOCK.
         */
        status = STATUS_PENDING;
    }

    if (wait_handle) status = wait_async( wait_handle, options & FILE_SYNCHRONOUS_IO_ALERT );
    return status;
}


static NTSTATUS do_getsockopt( HANDLE handle, IO_STATUS_BLOCK *io, int level,
                               int option, void *out_buffer, ULONG out_size )
{
    int fd, needs_close = FALSE;
    socklen_t len = out_size;
    NTSTATUS status;
    int ret;

    if ((status = server_get_unix_fd( handle, 0, &fd, &needs_close, NULL, NULL )))
        return status;

    ret = getsockopt( fd, level, option, out_buffer, &len );
    if (needs_close) close( fd );
    if (ret) return sock_errno_to_status( errno );
    if (io)
    {
        io->Status = STATUS_SUCCESS;
        io->Information = len;
    }
    return STATUS_SUCCESS;
}


static NTSTATUS do_setsockopt( HANDLE handle, IO_STATUS_BLOCK *io, int level,
                               int option, const void *optval, socklen_t optlen )
{
    int fd, needs_close = FALSE;
    NTSTATUS status;
    int ret;

    if ((status = server_get_unix_fd( handle, 0, &fd, &needs_close, NULL, NULL )))
        return status;

    ret = setsockopt( fd, level, option, optval, optlen );
    if (needs_close) close( fd );
    if (ret) return sock_errno_to_status( errno );
    if (io) io->Status = STATUS_SUCCESS;
    return STATUS_SUCCESS;
}


static int get_sock_type( HANDLE handle )
{
    int sock_type;
    if (do_getsockopt( handle, NULL, SOL_SOCKET, SO_TYPE, &sock_type, sizeof(sock_type) ) != STATUS_SUCCESS)
        return -1;
    return sock_type;
}


NTSTATUS sock_ioctl( HANDLE handle, HANDLE event, PIO_APC_ROUTINE apc, void *apc_user, IO_STATUS_BLOCK *io,
                     UINT code, void *in_buffer, UINT in_size, void *out_buffer, UINT out_size )
{
    int fd, needs_close = FALSE;
    unsigned int options;
    NTSTATUS status;

    TRACE( "handle %p, code %#x, in_buffer %p, in_size %u, out_buffer %p, out_size %u\n",
           handle, code, in_buffer, in_size, out_buffer, out_size );

    /* many of the below internal codes return success but don't completely
     * fill the iosb or signal completion; such sockopts are only called
     * synchronously by ws2_32 */

    switch (code)
    {
        case IOCTL_AFD_BIND:
        {
            const struct afd_bind_params *params = in_buffer;

            if (params->unknown) FIXME( "bind: got unknown %#x\n", params->unknown );

            status = STATUS_BAD_DEVICE_TYPE;
            break;
        }

        case IOCTL_AFD_GETSOCKNAME:
            if (in_size) FIXME( "unexpected input size %u\n", in_size );

            status = STATUS_BAD_DEVICE_TYPE;
            break;

        case IOCTL_AFD_LISTEN:
        {
            const struct afd_listen_params *params = in_buffer;

            TRACE( "backlog %u\n", params->backlog );
            if (out_size) FIXME( "unexpected output size %u\n", out_size );
            if (params->unknown1) FIXME( "listen: got unknown1 %#x\n", params->unknown1 );
            if (params->unknown2) FIXME( "listen: got unknown2 %#x\n", params->unknown2 );

            status = STATUS_BAD_DEVICE_TYPE;
            break;
        }

        case IOCTL_AFD_EVENT_SELECT:
        {
            const struct afd_event_select_params *params = in_buffer;

            TRACE( "event %p, mask %#x\n", params->event, params->mask );
            if (out_size) FIXME( "unexpected output size %u\n", out_size );

            status = STATUS_BAD_DEVICE_TYPE;
            break;
        }

        case IOCTL_AFD_GET_EVENTS:
        {
            struct afd_get_events_params *params = out_buffer;
            HANDLE reset_event = in_buffer; /* sic */

            TRACE( "reset_event %p\n", reset_event );
            if (in_size) FIXME( "unexpected input size %u\n", in_size );

            if (out_size < sizeof(*params))
            {
                status = STATUS_INVALID_PARAMETER;
                break;
            }

            if ((status = server_get_unix_fd( handle, 0, &fd, &needs_close, NULL, &options )))
                return status;
            if (needs_close) close( fd );

            SERVER_START_REQ( socket_get_events )
            {
                req->handle = wine_server_obj_handle( handle );
                req->event = wine_server_obj_handle( reset_event );
                wine_server_set_reply( req, params->status, sizeof(params->status) );
                if (!(status = wine_server_call( req )))
                    params->flags = reply->flags;
            }
            SERVER_END_REQ;

            file_complete_async( handle, options, event, apc, apc_user, io, status, 0 );
            return status;
        }

        case IOCTL_AFD_POLL:
            status = STATUS_BAD_DEVICE_TYPE;
            break;

        case IOCTL_AFD_RECV:
        {
            struct afd_recv_params params;
            int unix_flags = 0;

            if ((status = server_get_unix_fd( handle, 0, &fd, &needs_close, NULL, NULL )))
                return status;

            if (out_size) FIXME( "unexpected output size %u\n", out_size );

            if (in_wow64_call())
            {
                const struct afd_recv_params_32 *params32 = in_buffer;

                if (in_size < sizeof(struct afd_recv_params_32))
                {
                    status = STATUS_INVALID_PARAMETER;
                    break;
                }

                params.recv_flags = params32->recv_flags;
                params.msg_flags = params32->msg_flags;
                params.buffers = ULongToPtr( params32->buffers );
                params.count = params32->count;
            }
            else
            {
                if (in_size < sizeof(struct afd_recv_params))
                {
                    status = STATUS_INVALID_PARAMETER;
                    break;
                }

                memcpy( &params, in_buffer, sizeof(params) );
            }

            if ((params.msg_flags & (AFD_MSG_NOT_OOB | AFD_MSG_OOB)) == 0 ||
                (params.msg_flags & (AFD_MSG_NOT_OOB | AFD_MSG_OOB)) == (AFD_MSG_NOT_OOB | AFD_MSG_OOB))
            {
                status = STATUS_INVALID_PARAMETER;
                break;
            }

            if (params.msg_flags & ~(AFD_MSG_NOT_OOB | AFD_MSG_OOB | AFD_MSG_PEEK | AFD_MSG_WAITALL))
                FIXME( "unknown msg_flags %#x\n", params.msg_flags );
            if (params.recv_flags & ~AFD_RECV_FORCE_ASYNC)
                FIXME( "unknown recv_flags %#x\n", params.recv_flags );

            if (params.msg_flags & AFD_MSG_OOB)
                unix_flags |= MSG_OOB;
            if (params.msg_flags & AFD_MSG_PEEK)
                unix_flags |= MSG_PEEK;
            if (params.msg_flags & AFD_MSG_WAITALL)
                FIXME( "MSG_WAITALL is not supported\n" );
            status = sock_ioctl_recv( handle, event, apc, apc_user, io, fd, params.buffers, params.count, NULL,
                                      NULL, NULL, NULL, unix_flags, !!(params.recv_flags & AFD_RECV_FORCE_ASYNC) );
            if (needs_close) close( fd );
            return status;
        }

        case IOCTL_AFD_WINE_RECVMSG:
        {
            struct afd_recvmsg_params *params = in_buffer;
            unsigned int *ws_flags = u64_to_user_ptr(params->ws_flags_ptr);
            int unix_flags = 0;

            if ((status = server_get_unix_fd( handle, 0, &fd, &needs_close, NULL, NULL )))
                return status;

            if (in_size < sizeof(*params))
            {
                status = STATUS_BUFFER_TOO_SMALL;
                break;
            }

            if (*ws_flags & WS_MSG_OOB)
                unix_flags |= MSG_OOB;
            if (*ws_flags & WS_MSG_PEEK)
                unix_flags |= MSG_PEEK;
            if (*ws_flags & WS_MSG_WAITALL)
                FIXME( "MSG_WAITALL is not supported\n" );
            status = sock_ioctl_recv( handle, event, apc, apc_user, io, fd, u64_to_user_ptr(params->buffers_ptr),
                                      params->count, u64_to_user_ptr(params->control_ptr),
                                      u64_to_user_ptr(params->addr_ptr), u64_to_user_ptr(params->addr_len_ptr),
                                      ws_flags, unix_flags, params->force_async );
            if (needs_close) close( fd );
            return status;
        }

        case IOCTL_AFD_WINE_SENDMSG:
        {
            const struct afd_sendmsg_params *params = in_buffer;
            int unix_flags = 0;

            if ((status = server_get_unix_fd( handle, 0, &fd, &needs_close, NULL, NULL )))
                return status;

            if (in_size < sizeof(*params))
            {
                status = STATUS_BUFFER_TOO_SMALL;
                break;
            }

            if (params->ws_flags & WS_MSG_OOB)
                unix_flags |= MSG_OOB;
            if (params->ws_flags & WS_MSG_PARTIAL)
                WARN( "ignoring MSG_PARTIAL\n" );
            if (params->ws_flags & ~(WS_MSG_OOB | WS_MSG_PARTIAL))
                FIXME( "unknown flags %#x\n", params->ws_flags );
            status = sock_ioctl_send( handle, event, apc, apc_user, io, fd, u64_to_user_ptr( params->buffers_ptr ),
                                      params->count, u64_to_user_ptr( params->addr_ptr ), params->addr_len,
                                      unix_flags, params->force_async );
            if (needs_close) close( fd );
            return status;
        }

        case IOCTL_AFD_WINE_TRANSMIT:
        {
            const struct afd_transmit_params *params = in_buffer;

            if ((status = server_get_unix_fd( handle, 0, &fd, &needs_close, NULL, NULL )))
                return status;

            if (in_size < sizeof(*params))
            {
                status = STATUS_BUFFER_TOO_SMALL;
                break;
            }
            status = sock_transmit( handle, event, apc, apc_user, io, fd, params );
            if (needs_close) close( fd );
            return status;
        }

        case IOCTL_AFD_WINE_COMPLETE_ASYNC:
        {
            enum server_fd_type type;

            if (in_size != sizeof(NTSTATUS))
                return STATUS_BUFFER_TOO_SMALL;

            if ((status = server_get_unix_fd( handle, 0, &fd, &needs_close, &type, &options )))
                return status;
            if (needs_close) close( fd );
            if (type != FD_TYPE_SOCKET)
                return STATUS_INVALID_DEVICE_REQUEST;

            status = *(NTSTATUS *)in_buffer;
            file_complete_async( handle, options, event, apc, apc_user, io, status, 0 );
            return status;
        }

        case IOCTL_AFD_WINE_FIONREAD:
        {
            int value;

            if (out_size < sizeof(int))
            {
                status = STATUS_BUFFER_TOO_SMALL;
                break;
            }

            if ((status = server_get_unix_fd( handle, 0, &fd, &needs_close, NULL, &options )))
                return status;

#ifdef linux
            {
                socklen_t len = sizeof(value);

                /* FIONREAD on a listening socket always fails (see tcp(7)). */
                if (!getsockopt( fd, SOL_SOCKET, SO_ACCEPTCONN, &value, &len ) && value)
                {
                    *(int *)out_buffer = 0;
                    if (needs_close) close( fd );
                    file_complete_async( handle, options, event, apc, apc_user, io, STATUS_SUCCESS, 0 );
                    return STATUS_SUCCESS;
                }
            }
#endif

            if (ioctl( fd, FIONREAD, &value ) < 0)
            {
                status = sock_errno_to_status( errno );
                break;
            }
            *(int *)out_buffer = value;
            if (needs_close) close( fd );
            file_complete_async( handle, options, event, apc, apc_user, io, STATUS_SUCCESS, 0 );
            return STATUS_SUCCESS;
        }

        case IOCTL_AFD_WINE_SIOCATMARK:
        {
            int value
                ;
            socklen_t len = sizeof(value);

            if ((status = server_get_unix_fd( handle, 0, &fd, &needs_close, NULL, &options )))
                return status;

            if (out_size < sizeof(int))
            {
                status = STATUS_BUFFER_TOO_SMALL;
                break;
            }

            if (getsockopt( fd, SOL_SOCKET, SO_OOBINLINE, &value, &len ) < 0)
            {
                status = sock_errno_to_status( errno );
                break;
            }

            if (value)
            {
                *(int *)out_buffer = TRUE;
            }
            else
            {
                if (ioctl( fd, SIOCATMARK, &value ) < 0)
                {
                    status = sock_errno_to_status( errno );
                    break;
                }
                /* windows is reversed with respect to unix */
                *(int *)out_buffer = !value;
            }
            if (needs_close) close( fd );
            file_complete_async( handle, options, event, apc, apc_user, io, STATUS_SUCCESS, 0 );
            return STATUS_SUCCESS;
        }

        case IOCTL_AFD_WINE_GET_INTERFACE_LIST:
        {
#ifdef HAVE_GETIFADDRS
            INTERFACE_INFO *info = out_buffer;
            struct ifaddrs *ifaddrs, *ifaddr;
            unsigned int count = 0;
            ULONG ret_size;

            if ((status = server_get_unix_fd( handle, 0, &fd, &needs_close, NULL, &options )))
                return status;
            if (needs_close) close( fd );

            if (getifaddrs( &ifaddrs ) < 0)
            {
                return sock_errno_to_status( errno );
            }

            for (ifaddr = ifaddrs; ifaddr != NULL; ifaddr = ifaddr->ifa_next)
            {
                if (ifaddr->ifa_addr && ifaddr->ifa_addr->sa_family == AF_INET) ++count;
            }

            ret_size = count * sizeof(*info);
            if (out_size < ret_size)
            {
                freeifaddrs( ifaddrs );
                file_complete_async( handle, options, event, apc, apc_user, io, STATUS_BUFFER_TOO_SMALL, 0 );
                return STATUS_PENDING;
            }

            memset( out_buffer, 0, ret_size );

            count = 0;
            for (ifaddr = ifaddrs; ifaddr != NULL; ifaddr = ifaddr->ifa_next)
            {
                in_addr_t addr, mask;

                if (!ifaddr->ifa_addr || ifaddr->ifa_addr->sa_family != AF_INET)
                    continue;

                addr = ((const struct sockaddr_in *)ifaddr->ifa_addr)->sin_addr.s_addr;
                mask = ((const struct sockaddr_in *)ifaddr->ifa_netmask)->sin_addr.s_addr;

                info[count].iiFlags = 0;
                if (ifaddr->ifa_flags & IFF_BROADCAST)
                    info[count].iiFlags |= WS_IFF_BROADCAST;
                if (ifaddr->ifa_flags & IFF_LOOPBACK)
                    info[count].iiFlags |= WS_IFF_LOOPBACK;
                if (ifaddr->ifa_flags & IFF_MULTICAST)
                    info[count].iiFlags |= WS_IFF_MULTICAST;
#ifdef IFF_POINTTOPOINT
                if (ifaddr->ifa_flags & IFF_POINTTOPOINT)
                    info[count].iiFlags |= WS_IFF_POINTTOPOINT;
#endif
                if (ifaddr->ifa_flags & IFF_UP)
                    info[count].iiFlags |= WS_IFF_UP;

                info[count].iiAddress.AddressIn.sin_family = WS_AF_INET;
                info[count].iiAddress.AddressIn.sin_port = 0;
                info[count].iiAddress.AddressIn.sin_addr.WS_s_addr = addr;

                info[count].iiNetmask.AddressIn.sin_family = WS_AF_INET;
                info[count].iiNetmask.AddressIn.sin_port = 0;
                info[count].iiNetmask.AddressIn.sin_addr.WS_s_addr = mask;

                if (ifaddr->ifa_flags & IFF_BROADCAST)
                {
                    info[count].iiBroadcastAddress.AddressIn.sin_family = WS_AF_INET;
                    info[count].iiBroadcastAddress.AddressIn.sin_port = 0;
                    info[count].iiBroadcastAddress.AddressIn.sin_addr.WS_s_addr = addr | ~mask;
                }

                ++count;
            }

            freeifaddrs( ifaddrs );
            file_complete_async( handle, options, event, apc, apc_user, io, STATUS_SUCCESS, ret_size );
            return STATUS_PENDING;
#else
            FIXME( "Interface list queries are currently not supported on this platform.\n" );
            status = STATUS_NOT_SUPPORTED;
#endif
            break;
        }

        case IOCTL_AFD_WINE_KEEPALIVE_VALS:
        {
            struct tcp_keepalive *k = in_buffer;
            int keepalive;

            if (!in_buffer || in_size < sizeof(struct tcp_keepalive))
                return STATUS_BUFFER_TOO_SMALL;
            keepalive = !!k->onoff;

            if ((status = server_get_unix_fd( handle, 0, &fd, &needs_close, NULL, &options )))
                return status;

            if (setsockopt( fd, SOL_SOCKET, SO_KEEPALIVE, &keepalive, sizeof(int) ) < 0)
            {
                status = STATUS_INVALID_PARAMETER;
                break;
            }

            if (keepalive)
            {
#ifdef TCP_KEEPIDLE
                int idle = max( 1, (k->keepalivetime + 500) / 1000 );

                if (setsockopt( fd, IPPROTO_TCP, TCP_KEEPIDLE, &idle, sizeof(int) ) < 0)
                {
                    status = STATUS_INVALID_PARAMETER;
                    break;
                }
#else
                FIXME("ignoring keepalive timeout\n");
#endif
            }

            if (keepalive)
            {
#ifdef TCP_KEEPINTVL
                int interval = max( 1, (k->keepaliveinterval + 500) / 1000 );

                if (setsockopt( fd, IPPROTO_TCP, TCP_KEEPINTVL, &interval, sizeof(int) ) < 0)
                    status = STATUS_INVALID_PARAMETER;
#else
                FIXME("ignoring keepalive interval\n");
#endif
            }

            if (needs_close) close( fd );
            file_complete_async( handle, options, event, apc, apc_user, io, STATUS_SUCCESS, 0 );
            return STATUS_SUCCESS;
        }

        case IOCTL_AFD_WINE_GETPEERNAME:
            if (in_size) FIXME( "unexpected input size %u\n", in_size );

            status = STATUS_BAD_DEVICE_TYPE;
            break;

        case IOCTL_AFD_WINE_GET_SO_BROADCAST:
            return do_getsockopt( handle, io, SOL_SOCKET, SO_BROADCAST, out_buffer, out_size );

        case IOCTL_AFD_WINE_SET_SO_BROADCAST:
            return do_setsockopt( handle, io, SOL_SOCKET, SO_BROADCAST, in_buffer, in_size );

        case IOCTL_AFD_WINE_GET_SO_KEEPALIVE:
            return do_getsockopt( handle, io, SOL_SOCKET, SO_KEEPALIVE, out_buffer, out_size );

        case IOCTL_AFD_WINE_SET_SO_KEEPALIVE:
            return do_setsockopt( handle, io, SOL_SOCKET, SO_KEEPALIVE, in_buffer, in_size );

        case IOCTL_AFD_WINE_GET_SO_LINGER:
        {
            struct WS_linger *ws_linger = out_buffer;
            struct linger unix_linger;
            socklen_t len = sizeof(unix_linger);
            int ret;

            if ((status = server_get_unix_fd( handle, 0, &fd, &needs_close, NULL, NULL )))
                return status;

            ret = getsockopt( fd, SOL_SOCKET, SO_LINGER, &unix_linger, &len );
            if (!ret)
            {
                ws_linger->l_onoff = unix_linger.l_onoff;
                ws_linger->l_linger = unix_linger.l_linger;
                io->Status = STATUS_SUCCESS;
                io->Information = sizeof(*ws_linger);
            }

            status = ret ? sock_errno_to_status( errno ) : STATUS_SUCCESS;
            break;
        }

        case IOCTL_AFD_WINE_SET_SO_LINGER:
        {
            const struct WS_linger *ws_linger = in_buffer;
            struct linger unix_linger;

            unix_linger.l_onoff = ws_linger->l_onoff;
            unix_linger.l_linger = ws_linger->l_linger;

            return do_setsockopt( handle, io, SOL_SOCKET, SO_LINGER, &unix_linger, sizeof(unix_linger) );
        }

        case IOCTL_AFD_WINE_GET_SO_OOBINLINE:
            return do_getsockopt( handle, io, SOL_SOCKET, SO_OOBINLINE, out_buffer, out_size );

        case IOCTL_AFD_WINE_SET_SO_OOBINLINE:
            return do_setsockopt( handle, io, SOL_SOCKET, SO_OOBINLINE, in_buffer, in_size );

        case IOCTL_AFD_WINE_SET_IP_ADD_MEMBERSHIP:
            return do_setsockopt( handle, io, IPPROTO_IP, IP_ADD_MEMBERSHIP, in_buffer, in_size );

#ifdef IP_ADD_SOURCE_MEMBERSHIP
        case IOCTL_AFD_WINE_SET_IP_ADD_SOURCE_MEMBERSHIP:
            return do_setsockopt( handle, io, IPPROTO_IP, IP_ADD_SOURCE_MEMBERSHIP, in_buffer, in_size );
#endif

#ifdef IP_BLOCK_SOURCE
        case IOCTL_AFD_WINE_SET_IP_BLOCK_SOURCE:
            return do_setsockopt( handle, io, IPPROTO_IP, IP_BLOCK_SOURCE, in_buffer, in_size );
#endif

        case IOCTL_AFD_WINE_GET_IP_DONTFRAGMENT:
        {
            socklen_t len = out_size;
            int ret;

            if ((status = server_get_unix_fd( handle, 0, &fd, &needs_close, NULL, NULL )))
                return status;

#ifdef IP_DONTFRAG
            ret = getsockopt( fd, IPPROTO_IP, IP_DONTFRAG, out_buffer, &len );
#elif defined(IP_MTU_DISCOVER) && defined(IP_PMTUDISC_DONT)
            {
                int value;

                len = sizeof(value);
                ret = getsockopt( fd, IPPROTO_IP, IP_MTU_DISCOVER, &value, &len );
                if (!ret) *(DWORD *)out_buffer = (value != IP_PMTUDISC_DONT);
            }
#else
            {
                static int once;

                if (!once++)
                    FIXME( "IP_DONTFRAGMENT is not supported on this platform\n" );
                ret = 0; /* fake success */
            }
#endif
            if (ret)
            {
                status = sock_errno_to_status( errno );
            }
            else
            {
                io->Information = len;
                io->Status = status = STATUS_SUCCESS;
            }
            break;
        }

        case IOCTL_AFD_WINE_SET_IP_DONTFRAGMENT:
#ifdef IP_DONTFRAG
            return do_setsockopt( handle, io, IPPROTO_IP, IP_DONTFRAG, in_buffer, in_size );
#elif defined(IP_MTU_DISCOVER) && defined(IP_PMTUDISC_DO) && defined(IP_PMTUDISC_DONT)
        {
            int value = *(DWORD *)in_buffer ? IP_PMTUDISC_DO : IP_PMTUDISC_DONT;

            return do_setsockopt( handle, io, IPPROTO_IP, IP_MTU_DISCOVER, &value, sizeof(value) );
        }
#else
        {
            static int once;

            if (!once++)
                FIXME( "IP_DONTFRAGMENT is not supported on this platform\n" );
            status = STATUS_SUCCESS; /* fake success */
            break;
        }
#endif

        case IOCTL_AFD_WINE_SET_IP_DROP_MEMBERSHIP:
            return do_setsockopt( handle, io, IPPROTO_IP, IP_DROP_MEMBERSHIP, in_buffer, in_size );

#ifdef IP_ADD_SOURCE_MEMBERSHIP
        case IOCTL_AFD_WINE_SET_IP_DROP_SOURCE_MEMBERSHIP:
            return do_setsockopt( handle, io, IPPROTO_IP, IP_DROP_SOURCE_MEMBERSHIP, in_buffer, in_size );
#endif

#ifdef IP_HDRINCL
        case IOCTL_AFD_WINE_GET_IP_HDRINCL:
            if (get_sock_type( handle ) != SOCK_RAW) return STATUS_INVALID_PARAMETER;
            return do_getsockopt( handle, io, IPPROTO_IP, IP_HDRINCL, out_buffer, out_size );

        case IOCTL_AFD_WINE_SET_IP_HDRINCL:
            if (get_sock_type( handle ) != SOCK_RAW) return STATUS_INVALID_PARAMETER;
            return do_setsockopt( handle, io, IPPROTO_IP, IP_HDRINCL, in_buffer, in_size );
#endif

        case IOCTL_AFD_WINE_GET_IP_MULTICAST_IF:
        {
            int sock_type = get_sock_type( handle );
            if (sock_type != SOCK_DGRAM && sock_type != SOCK_RAW) return STATUS_INVALID_PARAMETER;
            return do_getsockopt( handle, io, IPPROTO_IP, IP_MULTICAST_IF, out_buffer, out_size );
        }

        case IOCTL_AFD_WINE_SET_IP_MULTICAST_IF:
        {
            int sock_type = get_sock_type( handle );
            if (sock_type != SOCK_DGRAM && sock_type != SOCK_RAW) return STATUS_INVALID_PARAMETER;
            return do_setsockopt( handle, io, IPPROTO_IP, IP_MULTICAST_IF, in_buffer, in_size );
        }

        case IOCTL_AFD_WINE_GET_IP_MULTICAST_LOOP:
        {
            int sock_type = get_sock_type( handle );
            if (sock_type != SOCK_DGRAM && sock_type != SOCK_RAW) return STATUS_INVALID_PARAMETER;
            return do_getsockopt( handle, io, IPPROTO_IP, IP_MULTICAST_LOOP, out_buffer, out_size );
        }

        case IOCTL_AFD_WINE_SET_IP_MULTICAST_LOOP:
        {
            int sock_type = get_sock_type( handle );
            if (sock_type != SOCK_DGRAM && sock_type != SOCK_RAW) return STATUS_INVALID_PARAMETER;
            return do_setsockopt( handle, io, IPPROTO_IP, IP_MULTICAST_LOOP, in_buffer, in_size );
        }

        case IOCTL_AFD_WINE_GET_IP_MULTICAST_TTL:
        {
            int sock_type = get_sock_type( handle );
            if (sock_type != SOCK_DGRAM && sock_type != SOCK_RAW) return STATUS_INVALID_PARAMETER;
            return do_getsockopt( handle, io, IPPROTO_IP, IP_MULTICAST_TTL, out_buffer, out_size );
        }

        case IOCTL_AFD_WINE_SET_IP_MULTICAST_TTL:
        {
            int sock_type = get_sock_type( handle );
            if (sock_type != SOCK_DGRAM && sock_type != SOCK_RAW) return STATUS_INVALID_PARAMETER;
            return do_setsockopt( handle, io, IPPROTO_IP, IP_MULTICAST_TTL, in_buffer, in_size );
        }

        case IOCTL_AFD_WINE_GET_IP_OPTIONS:
            return do_getsockopt( handle, io, IPPROTO_IP, IP_OPTIONS, out_buffer, out_size );

        case IOCTL_AFD_WINE_SET_IP_OPTIONS:
            return do_setsockopt( handle, io, IPPROTO_IP, IP_OPTIONS, in_buffer, in_size );

#ifdef IP_PKTINFO
        case IOCTL_AFD_WINE_GET_IP_PKTINFO:
        {
            int sock_type = get_sock_type( handle );
            if (sock_type != SOCK_DGRAM && sock_type != SOCK_RAW) return STATUS_INVALID_PARAMETER;
            return do_getsockopt( handle, io, IPPROTO_IP, IP_PKTINFO, out_buffer, out_size );
        }

        case IOCTL_AFD_WINE_SET_IP_PKTINFO:
        {
            int sock_type = get_sock_type( handle );
            if (sock_type != SOCK_DGRAM && sock_type != SOCK_RAW) return STATUS_INVALID_PARAMETER;
            return do_setsockopt( handle, io, IPPROTO_IP, IP_PKTINFO, in_buffer, in_size );
        }
#elif defined(IP_RECVDSTADDR)
        case IOCTL_AFD_WINE_GET_IP_PKTINFO:
        {
            int sock_type = get_sock_type( handle );
            if (sock_type != SOCK_DGRAM && sock_type != SOCK_RAW) return STATUS_INVALID_PARAMETER;
            return do_getsockopt( handle, io, IPPROTO_IP, IP_RECVDSTADDR, out_buffer, out_size );
        }

        case IOCTL_AFD_WINE_SET_IP_PKTINFO:
        {
            int sock_type = get_sock_type( handle );
            if (sock_type != SOCK_DGRAM && sock_type != SOCK_RAW) return STATUS_INVALID_PARAMETER;
            return do_setsockopt( handle, io, IPPROTO_IP, IP_RECVDSTADDR, in_buffer, in_size );
        }
#endif

#ifdef IP_RECVTOS
        case IOCTL_AFD_WINE_GET_IP_RECVTOS:
        {
            int sock_type = get_sock_type( handle );
            if (sock_type != SOCK_DGRAM && sock_type != SOCK_RAW) return STATUS_INVALID_PARAMETER;
            return do_getsockopt( handle, io, IPPROTO_IP, IP_RECVTOS, out_buffer, out_size );
        }

        case IOCTL_AFD_WINE_SET_IP_RECVTOS:
        {
            int sock_type = get_sock_type( handle );
            if (sock_type != SOCK_DGRAM && sock_type != SOCK_RAW) return STATUS_INVALID_PARAMETER;
            return do_setsockopt( handle, io, IPPROTO_IP, IP_RECVTOS, in_buffer, in_size );
        }
#endif

#ifdef IP_RECVTTL
        case IOCTL_AFD_WINE_GET_IP_RECVTTL:
        {
            int sock_type = get_sock_type( handle );
            if (sock_type != SOCK_DGRAM && sock_type != SOCK_RAW) return STATUS_INVALID_PARAMETER;
            return do_getsockopt( handle, io, IPPROTO_IP, IP_RECVTTL, out_buffer, out_size );
        }

        case IOCTL_AFD_WINE_SET_IP_RECVTTL:
        {
            int sock_type = get_sock_type( handle );
            if (sock_type != SOCK_DGRAM && sock_type != SOCK_RAW) return STATUS_INVALID_PARAMETER;
            return do_setsockopt( handle, io, IPPROTO_IP, IP_RECVTTL, in_buffer, in_size );
        }
#endif

        case IOCTL_AFD_WINE_GET_IP_TOS:
            return do_getsockopt( handle, io, IPPROTO_IP, IP_TOS, out_buffer, out_size );

        case IOCTL_AFD_WINE_SET_IP_TOS:
            return do_setsockopt( handle, io, IPPROTO_IP, IP_TOS, in_buffer, in_size );

        case IOCTL_AFD_WINE_GET_IP_TTL:
            return do_getsockopt( handle, io, IPPROTO_IP, IP_TTL, out_buffer, out_size );

        case IOCTL_AFD_WINE_SET_IP_TTL:
            return do_setsockopt( handle, io, IPPROTO_IP, IP_TTL, in_buffer, in_size );

#ifdef IP_UNBLOCK_SOURCE
        case IOCTL_AFD_WINE_SET_IP_UNBLOCK_SOURCE:
            return do_setsockopt( handle, io, IPPROTO_IP, IP_UNBLOCK_SOURCE, in_buffer, in_size );
#endif

#ifdef IP_UNICAST_IF
        case IOCTL_AFD_WINE_GET_IP_UNICAST_IF:
            return do_getsockopt( handle, io, IPPROTO_IP, IP_UNICAST_IF, out_buffer, out_size );

        case IOCTL_AFD_WINE_SET_IP_UNICAST_IF:
            return do_setsockopt( handle, io, IPPROTO_IP, IP_UNICAST_IF, in_buffer, in_size );
#endif

#ifdef IPV6_ADD_MEMBERSHIP
        case IOCTL_AFD_WINE_SET_IPV6_ADD_MEMBERSHIP:
            return do_setsockopt( handle, io, IPPROTO_IPV6, IPV6_ADD_MEMBERSHIP, in_buffer, in_size );
#endif

        case IOCTL_AFD_WINE_GET_IPV6_DONTFRAG:
        {
            socklen_t len = out_size;
            int ret;

            if ((status = server_get_unix_fd( handle, 0, &fd, &needs_close, NULL, NULL )))
                return status;

#ifdef IPV6_DONTFRAG
            ret = getsockopt( fd, IPPROTO_IPV6, IPV6_DONTFRAG, out_buffer, &len );
#elif defined(IPV6_MTU_DISCOVER) && defined(IPV6_PMTUDISC_DONT)
            {
                int value;

                len = sizeof(value);
                ret = getsockopt( fd, IPPROTO_IPV6, IPV6_MTU_DISCOVER, &value, &len );
                if (!ret) *(DWORD *)out_buffer = (value != IPV6_PMTUDISC_DONT);
            }
#else
            {
                static int once;

                if (!once++)
                    FIXME( "IPV6_DONTFRAGMENT is not supported on this platform\n" );
                ret = 0; /* fake success */
            }
#endif
            if (ret)
            {
                status = sock_errno_to_status( errno );
            }
            else
            {
                io->Information = len;
                io->Status = status = STATUS_SUCCESS;
            }
            break;
        }

        case IOCTL_AFD_WINE_SET_IPV6_DONTFRAG:
#ifdef IPV6_DONTFRAG
            return do_setsockopt( handle, io, IPPROTO_IPV6, IPV6_DONTFRAG, in_buffer, in_size );
#elif defined(IPV6_MTU_DISCOVER) && defined(IPV6_PMTUDISC_DO) && defined(IPV6_PMTUDISC_DONT)
        {
            int value = *(DWORD *)in_buffer ? IPV6_PMTUDISC_DO : IPV6_PMTUDISC_DONT;

            return do_setsockopt( handle, io, IPPROTO_IP, IPV6_MTU_DISCOVER, &value, sizeof(value) );
        }
#else
        {
            static int once;

            if (!once++)
                FIXME( "IPV6_DONTFRAGMENT is not supported on this platform\n" );
            return STATUS_SUCCESS; /* fake success */
        }
#endif

#ifdef IPV6_DROP_MEMBERSHIP
        case IOCTL_AFD_WINE_SET_IPV6_DROP_MEMBERSHIP:
            return do_setsockopt( handle, io, IPPROTO_IPV6, IPV6_DROP_MEMBERSHIP, in_buffer, in_size );
#endif

        case IOCTL_AFD_WINE_GET_IPV6_MULTICAST_HOPS:
        {
            int sock_type = get_sock_type( handle );
            if (sock_type != SOCK_DGRAM && sock_type != SOCK_RAW) return STATUS_INVALID_PARAMETER;
            return do_getsockopt( handle, io, IPPROTO_IPV6, IPV6_MULTICAST_HOPS, out_buffer, out_size );
        }

        case IOCTL_AFD_WINE_SET_IPV6_MULTICAST_HOPS:
        {
            int sock_type = get_sock_type( handle );
            if (sock_type != SOCK_DGRAM && sock_type != SOCK_RAW) return STATUS_INVALID_PARAMETER;
            return do_setsockopt( handle, io, IPPROTO_IPV6, IPV6_MULTICAST_HOPS, in_buffer, in_size );
        }

        case IOCTL_AFD_WINE_GET_IPV6_MULTICAST_IF:
        {
            int sock_type = get_sock_type( handle );
            if (sock_type != SOCK_DGRAM && sock_type != SOCK_RAW) return STATUS_INVALID_PARAMETER;
            return do_getsockopt( handle, io, IPPROTO_IPV6, IPV6_MULTICAST_IF, out_buffer, out_size );
        }

        case IOCTL_AFD_WINE_SET_IPV6_MULTICAST_IF:
        {
            int sock_type = get_sock_type( handle );
            if (sock_type != SOCK_DGRAM && sock_type != SOCK_RAW) return STATUS_INVALID_PARAMETER;
            return do_setsockopt( handle, io, IPPROTO_IPV6, IPV6_MULTICAST_IF, in_buffer, in_size );
        }

        case IOCTL_AFD_WINE_GET_IPV6_MULTICAST_LOOP:
        {
            int sock_type = get_sock_type( handle );
            if (sock_type != SOCK_DGRAM && sock_type != SOCK_RAW) return STATUS_INVALID_PARAMETER;
            return do_getsockopt( handle, io, IPPROTO_IPV6, IPV6_MULTICAST_LOOP, out_buffer, out_size );
        }

        case IOCTL_AFD_WINE_SET_IPV6_MULTICAST_LOOP:
        {
            int sock_type = get_sock_type( handle );
            if (sock_type != SOCK_DGRAM && sock_type != SOCK_RAW) return STATUS_INVALID_PARAMETER;
            return do_setsockopt( handle, io, IPPROTO_IPV6, IPV6_MULTICAST_LOOP, in_buffer, in_size );
        }

#ifdef IPV6_RECVHOPLIMIT
        case IOCTL_AFD_WINE_GET_IPV6_RECVHOPLIMIT:
        {
            int sock_type = get_sock_type( handle );
            if (sock_type != SOCK_DGRAM && sock_type != SOCK_RAW) return STATUS_INVALID_PARAMETER;
            return do_getsockopt( handle, io, IPPROTO_IPV6, IPV6_RECVHOPLIMIT, out_buffer, out_size );
        }

        case IOCTL_AFD_WINE_SET_IPV6_RECVHOPLIMIT:
        {
            int sock_type = get_sock_type( handle );
            if (sock_type != SOCK_DGRAM && sock_type != SOCK_RAW) return STATUS_INVALID_PARAMETER;
            return do_setsockopt( handle, io, IPPROTO_IPV6, IPV6_RECVHOPLIMIT, in_buffer, in_size );
        }
#endif

#ifdef IPV6_RECVPKTINFO
        case IOCTL_AFD_WINE_GET_IPV6_RECVPKTINFO:
        {
            int sock_type = get_sock_type( handle );
            if (sock_type != SOCK_DGRAM && sock_type != SOCK_RAW) return STATUS_INVALID_PARAMETER;
            return do_getsockopt( handle, io, IPPROTO_IPV6, IPV6_RECVPKTINFO, out_buffer, out_size );
        }

        case IOCTL_AFD_WINE_SET_IPV6_RECVPKTINFO:
        {
            int sock_type = get_sock_type( handle );
            if (sock_type != SOCK_DGRAM && sock_type != SOCK_RAW) return STATUS_INVALID_PARAMETER;
            return do_setsockopt( handle, io, IPPROTO_IPV6, IPV6_RECVPKTINFO, in_buffer, in_size );
        }
#endif

#ifdef IPV6_RECVTCLASS
        case IOCTL_AFD_WINE_GET_IPV6_RECVTCLASS:
        {
            int sock_type = get_sock_type( handle );
            if (sock_type != SOCK_DGRAM && sock_type != SOCK_RAW) return STATUS_INVALID_PARAMETER;
            return do_getsockopt( handle, io, IPPROTO_IPV6, IPV6_RECVTCLASS, out_buffer, out_size );
        }

        case IOCTL_AFD_WINE_SET_IPV6_RECVTCLASS:
        {
            int sock_type = get_sock_type( handle );
            if (sock_type != SOCK_DGRAM && sock_type != SOCK_RAW) return STATUS_INVALID_PARAMETER;
            return do_setsockopt( handle, io, IPPROTO_IPV6, IPV6_RECVTCLASS, in_buffer, in_size );
        }
#endif

        case IOCTL_AFD_WINE_GET_IPV6_UNICAST_HOPS:
            return do_getsockopt( handle, io, IPPROTO_IPV6, IPV6_UNICAST_HOPS, out_buffer, out_size );

        case IOCTL_AFD_WINE_SET_IPV6_UNICAST_HOPS:
            return do_setsockopt( handle, io, IPPROTO_IPV6, IPV6_UNICAST_HOPS, in_buffer, in_size );

#ifdef IPV6_UNICAST_IF
        case IOCTL_AFD_WINE_GET_IPV6_UNICAST_IF:
            return do_getsockopt( handle, io, IPPROTO_IPV6, IPV6_UNICAST_IF, out_buffer, out_size );

        case IOCTL_AFD_WINE_SET_IPV6_UNICAST_IF:
            return do_setsockopt( handle, io, IPPROTO_IPV6, IPV6_UNICAST_IF, in_buffer, in_size );
#endif

        case IOCTL_AFD_WINE_GET_IPV6_V6ONLY:
            return do_getsockopt( handle, io, IPPROTO_IPV6, IPV6_V6ONLY, out_buffer, out_size );

        case IOCTL_AFD_WINE_SET_IPV6_V6ONLY:
        {
            union unix_sockaddr addr;
            socklen_t len = sizeof(addr);
            int ret;

            if ((status = server_get_unix_fd( handle, 0, &fd, &needs_close, NULL, NULL )))
                return status;

            if (!getsockname( fd, &addr.addr, &len ) && addr.addr.sa_family == AF_INET && !addr.in.sin_port)
            {
                /* changing IPV6_V6ONLY succeeds on an unbound IPv4 socket */
                WARN( "ignoring IPV6_V6ONLY on an unbound IPv4 socket\n" );
                status = STATUS_SUCCESS;
                break;
            }

            ret = setsockopt( fd, IPPROTO_IPV6, IPV6_V6ONLY, in_buffer, in_size );
            status = ret ? sock_errno_to_status( errno ) : STATUS_SUCCESS;
            break;
        }

#ifdef HAS_IPX
#ifdef SOL_IPX
        case IOCTL_AFD_WINE_GET_IPX_PTYPE:
            return do_getsockopt( handle, io, SOL_IPX, IPX_TYPE, out_buffer, out_size );

        case IOCTL_AFD_WINE_SET_IPX_PTYPE:
            return do_setsockopt( handle, io, SOL_IPX, IPX_TYPE, in_buffer, in_size );
#elif defined(SO_DEFAULT_HEADERS)
        case IOCTL_AFD_WINE_GET_IPX_PTYPE:
        {
            struct ipx value;
            socklen_t len = sizeof(value);
            int ret;

            if ((status = server_get_unix_fd( handle, 0, &fd, &needs_close, NULL, NULL )))
                return status;

            ret = getsockopt( fd, 0, SO_DEFAULT_HEADERS, &value, &len );
            if (ret)
            {
                status = sock_errno_to_status( errno );
            }
            else
            {
                *(DWORD *)out_buffer = value.ipx_pt;
                status = STATUS_SUCCESS;
            }
            break;
        }

        case IOCTL_AFD_WINE_SET_IPX_PTYPE:
        {
            struct ipx value = {0};

            /* FIXME: should we retrieve SO_DEFAULT_HEADERS first and modify it? */
            value.ipx_pt = *(DWORD *)in_buffer;
            return do_setsockopt( handle, io, 0, SO_DEFAULT_HEADERS, &value, sizeof(value) );
        }
#endif
#endif

#ifdef HAS_IRDA
#define MAX_IRDA_DEVICES 10
        case IOCTL_AFD_WINE_GET_IRLMP_ENUMDEVICES:
        {
            char buffer[offsetof( struct irda_device_list, dev[MAX_IRDA_DEVICES] )];
            struct irda_device_list *unix_list = (struct irda_device_list *)buffer;
            socklen_t len = sizeof(buffer);
            DEVICELIST *ws_list = out_buffer;
            int fd, needs_close = FALSE;
            unsigned int i;
            int ret;

            if ((status = server_get_unix_fd( handle, 0, &fd, &needs_close, NULL, NULL )))
                return status;

            ret = getsockopt( fd, SOL_IRLMP, IRLMP_ENUMDEVICES, buffer, &len );
            if (needs_close) close( fd );
            if (ret) return sock_errno_to_status( errno );

            io->Information = offsetof( DEVICELIST, Device[unix_list->len] );
            if (out_size < io->Information)
                return STATUS_BUFFER_TOO_SMALL;

            TRACE( "IRLMP_ENUMDEVICES: got %u devices:\n", unix_list->len );
            ws_list->numDevice = unix_list->len;
            for (i = 0; i < unix_list->len; ++i)
            {
                const struct irda_device_info *unix_dev = &unix_list->dev[i];
                IRDA_DEVICE_INFO *ws_dev = &ws_list->Device[i];

                TRACE( "saddr %#08x, daddr %#08x, info %s, hints 0x%02x%02x\n",
                       unix_dev->saddr, unix_dev->daddr, unix_dev->info, unix_dev->hints[0], unix_dev->hints[1] );
                memcpy( ws_dev->irdaDeviceID, &unix_dev->daddr, sizeof(unix_dev->daddr) );
                memcpy( ws_dev->irdaDeviceName, unix_dev->info, sizeof(unix_dev->info) );
                ws_dev->irdaDeviceHints1 = unix_dev->hints[0];
                ws_dev->irdaDeviceHints2 = unix_dev->hints[1];
                ws_dev->irdaCharSet = unix_dev->charset;
            }
            io->Status = status = STATUS_SUCCESS;
            break;
        }
#endif

        case IOCTL_AFD_WINE_GET_TCP_NODELAY:
            return do_getsockopt( handle, io, IPPROTO_TCP, TCP_NODELAY, out_buffer, out_size );

        case IOCTL_AFD_WINE_SET_TCP_NODELAY:
            return do_setsockopt( handle, io, IPPROTO_TCP, TCP_NODELAY, in_buffer, in_size );

#if defined(TCP_KEEPIDLE)
        /* TCP_KEEPALIVE on Windows is often called TCP_KEEPIDLE on Unix */
        case IOCTL_AFD_WINE_GET_TCP_KEEPALIVE:
            return do_getsockopt( handle, io, IPPROTO_TCP, TCP_KEEPIDLE, out_buffer, out_size );

        case IOCTL_AFD_WINE_SET_TCP_KEEPALIVE:
            return do_setsockopt( handle, io, IPPROTO_TCP, TCP_KEEPIDLE, in_buffer, in_size );
#elif defined(TCP_KEEPALIVE)
        /* Mac */
        case IOCTL_AFD_WINE_GET_TCP_KEEPALIVE:
            return do_getsockopt( handle, io, IPPROTO_TCP, TCP_KEEPALIVE, out_buffer, out_size );

        case IOCTL_AFD_WINE_SET_TCP_KEEPALIVE:
            return do_setsockopt( handle, io, IPPROTO_TCP, TCP_KEEPALIVE, in_buffer, in_size );
#endif

        case IOCTL_AFD_WINE_GET_TCP_KEEPINTVL:
            return do_getsockopt( handle, io, IPPROTO_TCP, TCP_KEEPINTVL, out_buffer, out_size );

        case IOCTL_AFD_WINE_SET_TCP_KEEPINTVL:
            return do_setsockopt( handle, io, IPPROTO_TCP, TCP_KEEPINTVL, in_buffer, in_size );

        case IOCTL_AFD_WINE_GET_TCP_KEEPCNT:
            return do_getsockopt( handle, io, IPPROTO_TCP, TCP_KEEPCNT, out_buffer, out_size );

        case IOCTL_AFD_WINE_SET_TCP_KEEPCNT:
            return do_setsockopt( handle, io, IPPROTO_TCP, TCP_KEEPCNT, in_buffer, in_size );

        default:
        {
            if ((code >> 16) == FILE_DEVICE_NETWORK)
            {
                /* Wine-internal ioctl */
                status = STATUS_BAD_DEVICE_TYPE;
            }
            else
            {
                FIXME( "Unknown ioctl %#x (device %#x, access %#x, function %#x, method %#x)\n",
                       code, code >> 16, (code >> 14) & 3, (code >> 2) & 0xfff, code & 3 );
                status = STATUS_INVALID_DEVICE_REQUEST;
            }
            break;
        }
    }

    if (needs_close) close( fd );

    return status;
}
