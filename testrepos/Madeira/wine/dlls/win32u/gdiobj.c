/*
 * GDI functions
 *
 * Copyright 1993 Alexandre Julliard
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

#if 0
#pragma makedep unix
#endif

#include <assert.h>
#include <stdlib.h>
#include <stdarg.h>
#include <stdio.h>
#include <pthread.h>

#include "windef.h"
#include "winbase.h"
#include "wingdi.h"
#include "winreg.h"
#include "winnls.h"
#include "winerror.h"
#include "winternl.h"

#include "ntgdi_private.h"
#include "wine/debug.h"
#include "wine/unixlib.h"

WINE_DEFAULT_DEBUG_CHANNEL(gdi);

#define FIRST_GDI_HANDLE 32

static GDI_SHARED_MEMORY *gdi_shared;
static GDI_HANDLE_ENTRY *next_free;
static GDI_HANDLE_ENTRY *next_unused;
static LONG debug_count;

#ifdef WINE_IOS
extern int dprintf( int fd, const char *fmt, ... );

/* iOS-Madeira: one win32u instance serves every pseudo-process, so there is
 * exactly ONE handle table and ONE handle namespace for the session (the DCE
 * cache in dce.c, the class list in class.c and sysparams' display DC all hand
 * GDI handles across pseudo-process boundaries already, and sysparams_ios.c's
 * `display_dc` is not ours to split).  What is NOT shareable is the ADDRESS:
 * 32-bit gdi32 reads peb64->GdiSharedHandleTable through a 32-bit UINT_PTR
 * cast (wine/dlls/gdi32/objects.c:70-79), so the pointer it sees must be a
 * guest address -- i.e. the table must be reachable inside that process's
 * guest window [B, B+4G), where the low 32 bits of a host address ARE the
 * guest address.
 *
 * So: back the table with a SECTION, keep the master view at a plain host
 * address for the life of the session (a guest window is replaced with
 * PROT_NONE when its 32-bit pseudo-process exits, so session-wide state may
 * never live in one), and map a SECOND VIEW of the same section inside the
 * window of each 32-bit pseudo-process.  Both views are the same memory, so
 * there is still exactly one table; only the address published in each
 * process's PEB differs.  A window address is also a valid host address, so
 * 64-bit code inside a WoW process reading the same PEB field still works.
 *
 * The section must be a NAMED object.  wineserver handle tables are PER
 * pseudo-process here, so the HANDLE returned by NtCreateSection is only
 * meaningful inside the pseudo-process that happened to initialise win32u
 * first (the 64-bit desktop): in any other one the same numeric handle names a
 * different object, and NtMapViewOfSection fails with
 * STATUS_OBJECT_TYPE_MISMATCH (0xc0000024) — which is exactly what a 32-bit
 * CHILD process saw, leaving it with the truncated host address again.  The
 * object NAMESPACE, unlike the handle tables, is session-wide, so each
 * pseudo-process opens the section by name for itself. */
static const WCHAR gdi_shared_nameW[] =
    {'\\','K','e','r','n','e','l','O','b','j','e','c','t','s','\\',
     '_','_','w','i','n','e','_','i','o','s','_','g','d','i','_','s','h','a','r','e','d',0};
/* fallback if \KernelObjects is not available in this prefix */
static const WCHAR gdi_shared_name_bnoW[] =
    {'\\','B','a','s','e','N','a','m','e','d','O','b','j','e','c','t','s','\\',
     '_','_','w','i','n','e','_','i','o','s','_','g','d','i','_','s','h','a','r','e','d',0};

/* valid only in the pseudo-process that created it; everyone else opens by name */
static HANDLE gdi_shared_section;
static void *win32u_gdi_creator_peb;
static const WCHAR *gdi_shared_section_name;

struct gdi_shared_view
{
    DWORD pid;
    void *peb;
    void *view;
};

/* Only 32-bit pseudo-processes need an entry, and only a few of those can be
 * alive at a time (one 4 GB guest window each), so this is a small rotating
 * cache: a dead process's entry describes a view that died with its window
 * and is safe to overwrite. */
#define GDI_SHARED_MAX_VIEWS 8
static struct gdi_shared_view gdi_shared_views[GDI_SHARED_MAX_VIEWS];
static int gdi_shared_view_count;
static int gdi_shared_view_next;
static pthread_mutex_t gdi_shared_view_lock = PTHREAD_MUTEX_INITIALIZER;

__thread void *win32u_gdi_published_peb;
BOOL win32u_wow_session;

/* Madeira iOS layer: TRUE once the session is going to run 32-bit code (a
 * 32-bit main image, or a 32-bit child being created).  Weak: absent = FALSE. */
extern int ios_wow_session_armed(void) __attribute__((weak));

/* Should the session's GDI table be section-backed?  Only then can a 32-bit
 * process get a second view of it inside its guest window.  Default: only when
 * the session is armed for 32-bit code when win32u initialises, so a 64-bit
 * session keeps upstream's anonymous allocation.  MADEIRA_GDI_SHARED_SECTION=1
 * forces it (a 64-bit launcher that will start 32-bit children), =0 never. */
static BOOL gdi_shared_use_section(void)
{
    const char *env = getenv( "MADEIRA_GDI_SHARED_SECTION" );

    if (env && env[0]) return env[0] != '0';
    return ios_wow_session_armed && ios_wow_session_armed();
}

/***********************************************************************
 *           open_gdi_shared_section
 *
 * Open the session's GDI table section IN THE CALLING pseudo-process's handle
 * table.  Returns 0 when the table is not section-backed (or the name is gone),
 * in which case the caller keeps the master host address and says so.
 */
static HANDLE open_gdi_shared_section(void)
{
    UNICODE_STRING name;
    OBJECT_ATTRIBUTES attr;
    HANDLE handle = 0;

    if (!gdi_shared_section_name) return 0;
    RtlInitUnicodeString( &name, gdi_shared_section_name );
    InitializeObjectAttributes( &attr, &name, OBJ_CASE_INSENSITIVE, NULL, NULL );
    if (NtOpenSection( &handle, SECTION_MAP_READ | SECTION_MAP_WRITE, &attr )) return 0;
    return handle;
}
#endif

static inline HGDIOBJ entry_to_handle( GDI_HANDLE_ENTRY *entry )
{
    unsigned int idx = entry - gdi_shared->Handles;
    return ULongToHandle( idx | (entry->Unique << NTGDI_HANDLE_TYPE_SHIFT) );
}

static inline GDI_HANDLE_ENTRY *handle_entry( HGDIOBJ handle )
{
    unsigned int idx = LOWORD(handle);

    if (idx < GDI_MAX_HANDLE_COUNT && gdi_shared->Handles[idx].Type)
    {
        if (!HIWORD( handle ) || HIWORD( handle ) == gdi_shared->Handles[idx].Unique)
            return &gdi_shared->Handles[idx];
    }
    if (handle) WARN( "invalid handle %p\n", handle );
    return NULL;
}

static inline struct gdi_obj_header *entry_obj( GDI_HANDLE_ENTRY *entry )
{
    return (struct gdi_obj_header *)(ULONG_PTR)entry->Object;
}

/***********************************************************************
 *          GDI stock objects
 */

static const LOGBRUSH WhiteBrush = { BS_SOLID, RGB(255,255,255), 0 };
static const LOGBRUSH BlackBrush = { BS_SOLID, RGB(0,0,0), 0 };
static const LOGBRUSH NullBrush  = { BS_NULL, 0, 0 };

static const LOGBRUSH LtGrayBrush = { BS_SOLID, RGB(192,192,192), 0 };
static const LOGBRUSH GrayBrush   = { BS_SOLID, RGB(128,128,128), 0 };
static const LOGBRUSH DkGrayBrush = { BS_SOLID, RGB(64,64,64), 0 };

static const LOGBRUSH DCBrush = { BS_SOLID, RGB(255,255,255), 0 };

static pthread_mutex_t gdi_lock;


/****************************************************************************
 *
 *	language-independent stock fonts
 *
 */

static const LOGFONTW OEMFixedFont =
{ 12, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, OEM_CHARSET,
  0, 0, DEFAULT_QUALITY, FIXED_PITCH | FF_MODERN };

static const LOGFONTW AnsiFixedFont =
{ 12, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, ANSI_CHARSET,
  0, 0, DEFAULT_QUALITY, FIXED_PITCH | FF_MODERN,
  {'C','o','u','r','i','e','r'} };

static const LOGFONTW AnsiVarFont =
{ 12, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, ANSI_CHARSET,
  0, 0, DEFAULT_QUALITY, VARIABLE_PITCH | FF_SWISS,
  {'M','S',' ','S','a','n','s',' ','S','e','r','i','f'} };

/******************************************************************************
 *
 *      language-dependent stock fonts
 *
 *      'ANSI' charset and 'DEFAULT' charset is not same.
 *      The chars in CP_ACP should be drawn with 'DEFAULT' charset.
 *      'ANSI' charset seems to be identical with ISO-8859-1.
 *      'DEFAULT' charset is a language-dependent charset.
 *
 *      'System' font seems to be an alias for language-dependent font.
 */

/*
 * language-dependent stock fonts for all known charsets
 * please see TranslateCharsetInfo (dlls/gdi/font.c) and
 * CharsetBindingInfo (dlls/x11drv/xfont.c),
 * and modify entries for your language if needed.
 */
struct DefaultFontInfo
{
        UINT            charset;
        LOGFONTW        SystemFont;
        LOGFONTW        DeviceDefaultFont;
        LOGFONTW        SystemFixedFont;
        LOGFONTW        DefaultGuiFont;
};

static const struct DefaultFontInfo default_fonts[] =
{
    {   ANSI_CHARSET,
        { /* System */
          16, 7, 0, 0, FW_BOLD, FALSE, FALSE, FALSE, ANSI_CHARSET,
           0, 0, DEFAULT_QUALITY, VARIABLE_PITCH | FF_SWISS,
           {'S','y','s','t','e','m'}
        },
        { /* Device Default */
          16, 0, 0, 0, FW_BOLD, FALSE, FALSE, FALSE, ANSI_CHARSET,
           0, 0, DEFAULT_QUALITY, VARIABLE_PITCH | FF_SWISS,
           {'S','y','s','t','e','m'}
        },
        { /* System Fixed */
          16, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, ANSI_CHARSET,
           0, 0, DEFAULT_QUALITY, FIXED_PITCH | FF_MODERN,
           {'C','o','u','r','i','e','r'}
        },
        { /* DefaultGuiFont */
          -11, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, ANSI_CHARSET,
           0, 0, DEFAULT_QUALITY, VARIABLE_PITCH | FF_SWISS,
           {'M','S',' ','S','h','e','l','l',' ','D','l','g'}
        },
    },
    {   EASTEUROPE_CHARSET,
        { /* System */
          16, 7, 0, 0, FW_BOLD, FALSE, FALSE, FALSE, EASTEUROPE_CHARSET,
           0, 0, DEFAULT_QUALITY, VARIABLE_PITCH | FF_SWISS,
           {'S','y','s','t','e','m'}
        },
        { /* Device Default */
          16, 0, 0, 0, FW_BOLD, FALSE, FALSE, FALSE, EASTEUROPE_CHARSET,
           0, 0, DEFAULT_QUALITY, VARIABLE_PITCH | FF_SWISS,
           {'S','y','s','t','e','m'}
        },
        { /* System Fixed */
          16, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, EASTEUROPE_CHARSET,
           0, 0, DEFAULT_QUALITY, FIXED_PITCH | FF_MODERN,
           {'C','o','u','r','i','e','r'}
        },
        { /* DefaultGuiFont */
          -11, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, EASTEUROPE_CHARSET,
           0, 0, DEFAULT_QUALITY, VARIABLE_PITCH | FF_SWISS,
           {'M','S',' ','S','h','e','l','l',' ','D','l','g'}
        },
    },
    {   RUSSIAN_CHARSET,
        { /* System */
          16, 7, 0, 0, FW_BOLD, FALSE, FALSE, FALSE, RUSSIAN_CHARSET,
           0, 0, DEFAULT_QUALITY, VARIABLE_PITCH | FF_SWISS,
           {'S','y','s','t','e','m'}
        },
        { /* Device Default */
          16, 0, 0, 0, FW_BOLD, FALSE, FALSE, FALSE, RUSSIAN_CHARSET,
           0, 0, DEFAULT_QUALITY, VARIABLE_PITCH | FF_SWISS,
           {'S','y','s','t','e','m'}
        },
        { /* System Fixed */
          16, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, RUSSIAN_CHARSET,
           0, 0, DEFAULT_QUALITY, FIXED_PITCH | FF_MODERN,
           {'C','o','u','r','i','e','r'}
        },
        { /* DefaultGuiFont */
          -11, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, RUSSIAN_CHARSET,
           0, 0, DEFAULT_QUALITY, VARIABLE_PITCH | FF_SWISS,
           {'M','S',' ','S','h','e','l','l',' ','D','l','g'}
        },
    },
    {   GREEK_CHARSET,
        { /* System */
          16, 7, 0, 0, FW_BOLD, FALSE, FALSE, FALSE, GREEK_CHARSET,
           0, 0, DEFAULT_QUALITY, VARIABLE_PITCH | FF_SWISS,
           {'S','y','s','t','e','m'}
        },
        { /* Device Default */
          16, 0, 0, 0, FW_BOLD, FALSE, FALSE, FALSE, GREEK_CHARSET,
           0, 0, DEFAULT_QUALITY, VARIABLE_PITCH | FF_SWISS,
           {'S','y','s','t','e','m'}
        },
        { /* System Fixed */
          16, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, GREEK_CHARSET,
           0, 0, DEFAULT_QUALITY, FIXED_PITCH | FF_MODERN,
           {'C','o','u','r','i','e','r'}
        },
        { /* DefaultGuiFont */
          -11, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, GREEK_CHARSET,
           0, 0, DEFAULT_QUALITY, VARIABLE_PITCH | FF_SWISS,
           {'M','S',' ','S','h','e','l','l',' ','D','l','g'}
        },
    },
    {   TURKISH_CHARSET,
        { /* System */
          16, 7, 0, 0, FW_BOLD, FALSE, FALSE, FALSE, TURKISH_CHARSET,
           0, 0, DEFAULT_QUALITY, VARIABLE_PITCH | FF_SWISS,
           {'S','y','s','t','e','m'}
        },
        { /* Device Default */
          16, 0, 0, 0, FW_BOLD, FALSE, FALSE, FALSE, TURKISH_CHARSET,
           0, 0, DEFAULT_QUALITY, VARIABLE_PITCH | FF_SWISS,
           {'S','y','s','t','e','m'}
        },
        { /* System Fixed */
          16, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, TURKISH_CHARSET,
           0, 0, DEFAULT_QUALITY, FIXED_PITCH | FF_MODERN,
           {'C','o','u','r','i','e','r'}
        },
        { /* DefaultGuiFont */
          -11, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, TURKISH_CHARSET,
           0, 0, DEFAULT_QUALITY, VARIABLE_PITCH | FF_SWISS,
           {'M','S',' ','S','h','e','l','l',' ','D','l','g'}
        },
    },
    {   HEBREW_CHARSET,
        { /* System */
          16, 7, 0, 0, FW_BOLD, FALSE, FALSE, FALSE, HEBREW_CHARSET,
           0, 0, DEFAULT_QUALITY, VARIABLE_PITCH | FF_SWISS,
           {'S','y','s','t','e','m'}
        },
        { /* Device Default */
          16, 0, 0, 0, FW_BOLD, FALSE, FALSE, FALSE, HEBREW_CHARSET,
           0, 0, DEFAULT_QUALITY, VARIABLE_PITCH | FF_SWISS,
           {'S','y','s','t','e','m'}
        },
        { /* System Fixed */
          16, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, HEBREW_CHARSET,
           0, 0, DEFAULT_QUALITY, FIXED_PITCH | FF_MODERN,
           {'C','o','u','r','i','e','r'}
        },
        { /* DefaultGuiFont */
          -11, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, HEBREW_CHARSET,
           0, 0, DEFAULT_QUALITY, VARIABLE_PITCH | FF_SWISS,
           {'M','S',' ','S','h','e','l','l',' ','D','l','g'}
        },
    },
    {   ARABIC_CHARSET,
        { /* System */
          16, 7, 0, 0, FW_BOLD, FALSE, FALSE, FALSE, ARABIC_CHARSET,
           0, 0, DEFAULT_QUALITY, VARIABLE_PITCH | FF_SWISS,
           {'S','y','s','t','e','m'}
        },
        { /* Device Default */
          16, 0, 0, 0, FW_BOLD, FALSE, FALSE, FALSE, ARABIC_CHARSET,
           0, 0, DEFAULT_QUALITY, VARIABLE_PITCH | FF_SWISS,
           {'S','y','s','t','e','m'}
        },
        { /* System Fixed */
          16, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, ARABIC_CHARSET,
           0, 0, DEFAULT_QUALITY, FIXED_PITCH | FF_MODERN,
           {'C','o','u','r','i','e','r'}
        },
        { /* DefaultGuiFont */
          -11, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, ARABIC_CHARSET,
           0, 0, DEFAULT_QUALITY, VARIABLE_PITCH | FF_SWISS,
           {'M','S',' ','S','h','e','l','l',' ','D','l','g'}
        },
    },
    {   BALTIC_CHARSET,
        { /* System */
          16, 7, 0, 0, FW_BOLD, FALSE, FALSE, FALSE, BALTIC_CHARSET,
           0, 0, DEFAULT_QUALITY, VARIABLE_PITCH | FF_SWISS,
           {'S','y','s','t','e','m'}
        },
        { /* Device Default */
          16, 0, 0, 0, FW_BOLD, FALSE, FALSE, FALSE, BALTIC_CHARSET,
           0, 0, DEFAULT_QUALITY, VARIABLE_PITCH | FF_SWISS,
           {'S','y','s','t','e','m'}
        },
        { /* System Fixed */
          16, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, BALTIC_CHARSET,
           0, 0, DEFAULT_QUALITY, FIXED_PITCH | FF_MODERN,
           {'C','o','u','r','i','e','r'}
        },
        { /* DefaultGuiFont */
          -11, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, BALTIC_CHARSET,
           0, 0, DEFAULT_QUALITY, VARIABLE_PITCH | FF_SWISS,
           {'M','S',' ','S','h','e','l','l',' ','D','l','g'}
        },
    },
    {   THAI_CHARSET,
        { /* System */
          16, 7, 0, 0, FW_BOLD, FALSE, FALSE, FALSE, THAI_CHARSET,
           0, 0, DEFAULT_QUALITY, VARIABLE_PITCH | FF_SWISS,
           {'S','y','s','t','e','m'}
        },
        { /* Device Default */
          16, 0, 0, 0, FW_BOLD, FALSE, FALSE, FALSE, THAI_CHARSET,
           0, 0, DEFAULT_QUALITY, VARIABLE_PITCH | FF_SWISS,
           {'S','y','s','t','e','m'}
        },
        { /* System Fixed */
          16, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, THAI_CHARSET,
           0, 0, DEFAULT_QUALITY, FIXED_PITCH | FF_MODERN,
           {'C','o','u','r','i','e','r'}
        },
        { /* DefaultGuiFont */
          -11, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, THAI_CHARSET,
           0, 0, DEFAULT_QUALITY, VARIABLE_PITCH | FF_SWISS,
           {'M','S',' ','S','h','e','l','l',' ','D','l','g'}
        },
    },
    {   SHIFTJIS_CHARSET,
        { /* System */
          18, 8, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, SHIFTJIS_CHARSET,
           0, 0, DEFAULT_QUALITY, VARIABLE_PITCH | FF_SWISS,
           {'S','y','s','t','e','m'}
        },
        { /* Device Default */
          18, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, SHIFTJIS_CHARSET,
           0, 0, DEFAULT_QUALITY, VARIABLE_PITCH | FF_SWISS,
           {'S','y','s','t','e','m'}
        },
        { /* System Fixed */
          16, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, SHIFTJIS_CHARSET,
           0, 0, DEFAULT_QUALITY, FIXED_PITCH | FF_MODERN,
           {'C','o','u','r','i','e','r'}
        },
        { /* DefaultGuiFont */
          -12, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, SHIFTJIS_CHARSET,
           0, 0, DEFAULT_QUALITY, VARIABLE_PITCH | FF_SWISS,
           {'M','S',' ','S','h','e','l','l',' ','D','l','g'}
        },
    },
    {   GB2312_CHARSET,
        { /* System */
          16, 7, 0, 0, FW_BOLD, FALSE, FALSE, FALSE, GB2312_CHARSET,
           0, 0, DEFAULT_QUALITY, VARIABLE_PITCH | FF_SWISS,
           {'S','y','s','t','e','m'}
        },
        { /* Device Default */
          16, 0, 0, 0, FW_BOLD, FALSE, FALSE, FALSE, GB2312_CHARSET,
           0, 0, DEFAULT_QUALITY, VARIABLE_PITCH | FF_SWISS,
           {'S','y','s','t','e','m'}
        },
        { /* System Fixed */
          16, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, GB2312_CHARSET,
           0, 0, DEFAULT_QUALITY, FIXED_PITCH | FF_MODERN,
           {'C','o','u','r','i','e','r'}
        },
        { /* DefaultGuiFont */
          -12, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, GB2312_CHARSET,
           0, 0, DEFAULT_QUALITY, VARIABLE_PITCH | FF_SWISS,
           {'M','S',' ','S','h','e','l','l',' ','D','l','g'}
        },
    },
    {   HANGEUL_CHARSET,
        { /* System */
          16, 8, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, HANGEUL_CHARSET,
           0, 0, DEFAULT_QUALITY, VARIABLE_PITCH | FF_SWISS,
           {'S','y','s','t','e','m'}
        },
        { /* Device Default */
          16, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, HANGEUL_CHARSET,
           0, 0, DEFAULT_QUALITY, VARIABLE_PITCH | FF_SWISS,
           {'S','y','s','t','e','m'}
        },
        { /* System Fixed */
          16, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, HANGEUL_CHARSET,
           0, 0, DEFAULT_QUALITY, FIXED_PITCH | FF_MODERN,
           {'C','o','u','r','i','e','r'}
        },
        { /* DefaultGuiFont */
          -12, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, HANGEUL_CHARSET,
           0, 0, DEFAULT_QUALITY, VARIABLE_PITCH | FF_SWISS,
           {'M','S',' ','S','h','e','l','l',' ','D','l','g'}
        },
    },
    {   CHINESEBIG5_CHARSET,
        { /* System */
          16, 7, 0, 0, FW_BOLD, FALSE, FALSE, FALSE, CHINESEBIG5_CHARSET,
           0, 0, DEFAULT_QUALITY, VARIABLE_PITCH | FF_SWISS,
           {'S','y','s','t','e','m'}
        },
        { /* Device Default */
          16, 0, 0, 0, FW_BOLD, FALSE, FALSE, FALSE, CHINESEBIG5_CHARSET,
           0, 0, DEFAULT_QUALITY, VARIABLE_PITCH | FF_SWISS,
           {'S','y','s','t','e','m'}
        },
        { /* System Fixed */
          16, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, CHINESEBIG5_CHARSET,
           0, 0, DEFAULT_QUALITY, FIXED_PITCH | FF_MODERN,
           {'C','o','u','r','i','e','r'}
        },
        { /* DefaultGuiFont */
          -12, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, CHINESEBIG5_CHARSET,
           0, 0, DEFAULT_QUALITY, VARIABLE_PITCH | FF_SWISS,
           {'M','S',' ','S','h','e','l','l',' ','D','l','g'}
        },
    },
    {   JOHAB_CHARSET,
        { /* System */
          16, 7, 0, 0, FW_BOLD, FALSE, FALSE, FALSE, JOHAB_CHARSET,
           0, 0, DEFAULT_QUALITY, VARIABLE_PITCH | FF_SWISS,
           {'S','y','s','t','e','m'}
        },
        { /* Device Default */
          16, 0, 0, 0, FW_BOLD, FALSE, FALSE, FALSE, JOHAB_CHARSET,
           0, 0, DEFAULT_QUALITY, VARIABLE_PITCH | FF_SWISS,
           {'S','y','s','t','e','m'}
        },
        { /* System Fixed */
          16, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, JOHAB_CHARSET,
           0, 0, DEFAULT_QUALITY, FIXED_PITCH | FF_MODERN,
           {'C','o','u','r','i','e','r'}
        },
        { /* DefaultGuiFont */
          -12, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, JOHAB_CHARSET,
           0, 0, DEFAULT_QUALITY, VARIABLE_PITCH | FF_SWISS,
           {'M','S',' ','S','h','e','l','l',' ','D','l','g'}
        },
    },
};

void make_gdi_object_system( HGDIOBJ handle, BOOL set)
{
    GDI_HANDLE_ENTRY *entry;

    pthread_mutex_lock( &gdi_lock );
    if ((entry = handle_entry( handle ))) entry_obj( entry )->system = !!set;
    pthread_mutex_unlock( &gdi_lock );
}

/******************************************************************************
 *      get_default_fonts
 */
static const struct DefaultFontInfo* get_default_fonts(void)
{
    unsigned int n;
    CHARSETINFO csi;

    if (ansi_cp.CodePage == CP_UTF8) return &default_fonts[0];

    csi.ciCharset = ANSI_CHARSET;
    translate_charset_info( ULongToPtr(ansi_cp.CodePage), &csi, TCI_SRCCODEPAGE );

    for(n = 0; n < ARRAY_SIZE( default_fonts ); n++)
        if ( default_fonts[n].charset == csi.ciCharset )
            return &default_fonts[n];

    FIXME( "unhandled charset 0x%08x - use ANSI_CHARSET for default stock objects\n", csi.ciCharset );
    return &default_fonts[0];
}


/***********************************************************************
 *           GDI_get_ref_count
 *
 * Retrieve the reference count of a GDI object.
 * Note: the object must be locked otherwise the count is meaningless.
 */
UINT GDI_get_ref_count( HGDIOBJ handle )
{
    GDI_HANDLE_ENTRY *entry;
    UINT ret = 0;

    pthread_mutex_lock( &gdi_lock );
    if ((entry = handle_entry( handle ))) ret = entry_obj( entry )->selcount;
    pthread_mutex_unlock( &gdi_lock );
    return ret;
}


/***********************************************************************
 *           GDI_inc_ref_count
 *
 * Increment the reference count of a GDI object.
 */
HGDIOBJ GDI_inc_ref_count( HGDIOBJ handle )
{
    GDI_HANDLE_ENTRY *entry;

    pthread_mutex_lock( &gdi_lock );
    if ((entry = handle_entry( handle ))) entry_obj( entry )->selcount++;
    else handle = 0;
    pthread_mutex_unlock( &gdi_lock );
    return handle;
}


/***********************************************************************
 *           GDI_dec_ref_count
 *
 * Decrement the reference count of a GDI object.
 */
BOOL GDI_dec_ref_count( HGDIOBJ handle )
{
    GDI_HANDLE_ENTRY *entry;

    pthread_mutex_lock( &gdi_lock );
    if ((entry = handle_entry( handle )))
    {
        assert( entry_obj( entry )->selcount );
        if (!--entry_obj( entry )->selcount && entry_obj( entry )->deleted)
        {
            /* handle delayed DeleteObject*/
            entry_obj( entry )->deleted = 0;
            pthread_mutex_unlock( &gdi_lock );
            TRACE( "executing delayed DeleteObject for %p\n", handle );
            NtGdiDeleteObjectApp( handle );
            return TRUE;
        }
    }
    pthread_mutex_unlock( &gdi_lock );
    return entry != NULL;
}


static HFONT create_font( const LOGFONTW *deffont )
{
    ENUMLOGFONTEXDVW lf;

    memset( &lf, 0, sizeof(lf) );
    lf.elfEnumLogfontEx.elfLogFont = *deffont;
    return NtGdiHfontCreate( &lf, sizeof(lf), 0, 0, NULL );
}

static HFONT create_scaled_font( const LOGFONTW *deffont, unsigned int dpi )
{
    LOGFONTW lf;

    lf = *deffont;
    lf.lfHeight = muldiv( lf.lfHeight, dpi, 96 );
    return create_font( &lf );
}

#ifdef WINE_IOS
/***********************************************************************
 *           win32u_gdi_publish_shared
 *
 * iOS-Madeira: publish the session's GDI shared handle table into the CALLING
 * pseudo-process's PEB, mapping a second view of it inside that process's
 * guest window first when the process is 32-bit.  See the comment next to
 * gdi_shared_section above.  Cheap to call: win32u_gdi_check_publish() filters
 * on a per-thread flag and only the first call of each pseudo-process gets
 * here.
 */
void win32u_gdi_publish_shared(void)
{
    void *peb = NtCurrentTeb()->Peb;
    void *view = gdi_shared;
    DWORD pid;
    int i;

    if (!gdi_shared) return;   /* gdi_init() has not run yet; it publishes too */

    if (!NtCurrentTeb()->WowTebOffset)
    {
        /* 64-bit pseudo-process: the master host address is already what it
         * needs, and there is nothing to remember. */
        NtCurrentTeb()->Peb->GdiSharedHandleTable = view;
        win32u_gdi_published_peb = peb;
        return;
    }

    pid = HandleToULong( NtCurrentTeb()->ClientId.UniqueProcess );

    pthread_mutex_lock( &gdi_shared_view_lock );
    for (i = 0; i < gdi_shared_view_count; i++)
        if (gdi_shared_views[i].peb == peb && gdi_shared_views[i].pid == pid) break;

    if (i < gdi_shared_view_count) view = gdi_shared_views[i].view;
    else
    {
        /* Per-pseudo-process handle tables: re-open the section by NAME here.
         * gdi_shared_section itself only names the right object in the
         * pseudo-process that created it. */
        HANDLE section = open_gdi_shared_section();

        if (!section && gdi_shared_section &&
            NtCurrentTeb()->Peb == win32u_gdi_creator_peb) section = gdi_shared_section;

        if (section)
        {
            void *guest_view = NULL;
            SIZE_T view_size = 0;
            LARGE_INTEGER offset = { .QuadPart = 0 };
            NTSTATUS status;

            /* caller_zero_bits() is a GUEST ceiling; the Madeira iOS ntdll
             * translates it into this process's window, and
             * NtMapViewOfSection funnels through the same chokepoint as
             * NtAllocateVirtualMemory. */
            status = NtMapViewOfSection( section, GetCurrentProcess(), &guest_view,
                                         caller_zero_bits(), 0, &offset, &view_size,
                                         ViewShare, 0, PAGE_READWRITE );
            if (!status) view = guest_view;
            else
                ERR( "[gdi-shared] peb=%p pid=%04x: no guest-window view (%#x) — 32-bit gdi32 "
                     "will truncate the host table pointer\n", peb, (int)pid, (int)status );
            if (section != gdi_shared_section) NtClose( section );
        }
        else
            ERR( "[gdi-shared] peb=%p pid=%04x: cannot open the session table section %s — "
                 "32-bit gdi32 will truncate the host table pointer\n", peb, (int)pid,
                 debugstr_w( gdi_shared_section_name ) );

        i = gdi_shared_view_next;
        gdi_shared_views[i].pid  = pid;
        gdi_shared_views[i].peb  = peb;
        gdi_shared_views[i].view = view;
        gdi_shared_view_next = (i + 1) % GDI_SHARED_MAX_VIEWS;
        if (gdi_shared_view_count < GDI_SHARED_MAX_VIEWS) gdi_shared_view_count++;

        dprintf( 2, "[gdi-shared] peb=%p pid=%04x wow=1 master=%p guest-view=%p slot=%d\n",
                 peb, (int)pid, gdi_shared, view, i );
    }
    pthread_mutex_unlock( &gdi_shared_view_lock );

    /* A window address is a host address too, so 64-bit consumers inside this
     * WoW pseudo-process keep working while 32-bit gdi32's truncation of the
     * same field yields exactly the guest address. */
    NtCurrentTeb()->Peb->GdiSharedHandleTable = view;
    win32u_gdi_published_peb = peb;
}
#endif  /* WINE_IOS */

static void init_gdi_shared(void)
{
    SIZE_T size = sizeof(*gdi_shared);

#ifdef WINE_IOS
    if (!gdi_shared_use_section())
    {
        /* upstream: anonymous table, published once below */
        if (NtAllocateVirtualMemory( GetCurrentProcess(), (void **)&gdi_shared, zero_bits,
                                     &size, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE ))
            return;
    }
    else
    {
        OBJECT_ATTRIBUTES attr;
        UNICODE_STRING name;
        LARGE_INTEGER sec_size;
        SIZE_T view_size = 0;
        NTSTATUS status;

        /* NAMED (see gdi_shared_section above): every later pseudo-process has
         * its own handle table and can only find this object by name.
         * OBJ_OPENIF so a re-entry can never create a second table, and
         * OBJ_PERMANENT so the name outlives whichever pseudo-process happened
         * to initialise win32u first (wineserver marks its own session objects
         * the same way — server/directory.c). */
        gdi_shared_section_name = gdi_shared_nameW;
        RtlInitUnicodeString( &name, gdi_shared_section_name );
        InitializeObjectAttributes( &attr, &name, OBJ_CASE_INSENSITIVE | OBJ_OPENIF | OBJ_PERMANENT,
                                    NULL, NULL );
        sec_size.QuadPart = size;
        status = NtCreateSection( &gdi_shared_section, SECTION_ALL_ACCESS, &attr, &sec_size,
                                  PAGE_READWRITE, SEC_COMMIT, NULL );
        if (status < 0)   /* e.g. \KernelObjects missing in this prefix */
        {
            gdi_shared_section_name = gdi_shared_name_bnoW;
            RtlInitUnicodeString( &name, gdi_shared_section_name );
            status = NtCreateSection( &gdi_shared_section, SECTION_ALL_ACCESS, &attr, &sec_size,
                                      PAGE_READWRITE, SEC_COMMIT, NULL );
        }
        /* OBJ_OPENIF reports STATUS_OBJECT_NAME_EXISTS (a success code) when it
         * opened an existing object instead of creating one. */
        if (status >= 0)
        {
            win32u_gdi_creator_peb = NtCurrentTeb()->Peb;
            /* master view: ALWAYS a plain host address (zero_bits 0), even when
             * the pseudo-process that happens to initialise win32u first is
             * 32-bit — this is session-wide state and a guest window does not
             * survive its owner. */
            status = NtMapViewOfSection( gdi_shared_section, GetCurrentProcess(),
                                         (void **)&gdi_shared, 0, 0, NULL, &view_size,
                                         ViewShare, 0, PAGE_READWRITE );
            if (status)
            {
                NtClose( gdi_shared_section );
                gdi_shared_section = 0;
                gdi_shared = NULL;
            }
        }
        else gdi_shared_section = 0;

        if (!gdi_shared)
        {
            gdi_shared_section_name = NULL;
            ERR( "[gdi-shared] no section-backed table (%#x) — falling back to a private "
                 "allocation; 32-bit pseudo-processes will not be able to address it\n",
                 (int)status );
        }
        else
        {
            win32u_wow_session = TRUE;
            dprintf( 2, "[gdi-shared] session table %p (%lu bytes, section-backed, name=%s)\n",
                     gdi_shared, (unsigned long)size, debugstr_w( gdi_shared_section_name ) );
        }
    }
    if (!gdi_shared &&
        NtAllocateVirtualMemory( GetCurrentProcess(), (void **)&gdi_shared, 0,
                                 &size, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE ))
        return;
#else
    if (NtAllocateVirtualMemory( GetCurrentProcess(), (void **)&gdi_shared, zero_bits,
                                 &size, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE ))
        return;
#endif
    next_unused = gdi_shared->Handles + FIRST_GDI_HANDLE;

#ifdef WINE_IOS
    if (NtCurrentTeb()->WowTebOffset)
    {
        win32u_gdi_publish_shared();
        return;
    }
#endif

#ifndef _WIN64
    if (NtCurrentTeb()->GdiBatchCount)
    {
        TEB64 *teb64 = (TEB64 *)(UINT_PTR)NtCurrentTeb()->GdiBatchCount;
        PEB64 *peb64 = (PEB64 *)(UINT_PTR)teb64->Peb;
        peb64->GdiSharedHandleTable = (UINT_PTR)gdi_shared;
        return;
    }
#endif
    /* NOTE: Windows uses 32-bit for 32-bit kernel */
    NtCurrentTeb()->Peb->GdiSharedHandleTable = gdi_shared;
}

/***********************************************************************
 *           GetStockObject    (win32u.so)
 */
HGDIOBJ WINAPI GetStockObject( INT obj )
{
    assert( obj >= 0 && obj <= STOCK_LAST + 1 && obj != 9 );

    win32u_gdi_check_publish();

    switch (obj)
    {
    case OEM_FIXED_FONT:
        if (get_system_dpi() != 96) obj = 9;
        break;
    case SYSTEM_FONT:
        if (get_system_dpi() != 96) obj = STOCK_LAST + 2;
        break;
    case SYSTEM_FIXED_FONT:
        if (get_system_dpi() != 96) obj = STOCK_LAST + 3;
        break;
    case DEFAULT_GUI_FONT:
        if (get_system_dpi() != 96) obj = STOCK_LAST + 4;
        break;
    }

    return entry_to_handle( handle_entry( ULongToHandle( obj + FIRST_GDI_HANDLE )));
}

static void init_stock_objects( unsigned int dpi )
{
    const struct DefaultFontInfo *deffonts;
    unsigned int i;
    HGDIOBJ obj;

    /* Create stock objects in order matching stock object macros,
     * so that they use predictable handle slots. Our GetStockObject
     * depends on it. */
    create_brush( &WhiteBrush );
    create_brush( &LtGrayBrush );
    create_brush( &GrayBrush );
    create_brush( &DkGrayBrush );
    create_brush( &BlackBrush );
    create_brush( &NullBrush );

    create_pen( PS_SOLID, 0, RGB(255,255,255) );
    create_pen( PS_SOLID, 0, RGB(0,0,0) );
    create_pen( PS_NULL,  0, RGB(0,0,0) );

    /* slot 9 is not used for non-scaled stock objects */
    create_scaled_font( &OEMFixedFont, dpi );

    /* language-independent stock fonts */
    create_font( &OEMFixedFont );
    create_font( &AnsiFixedFont );
    create_font( &AnsiVarFont );

    /* language-dependent stock fonts */
    deffonts = get_default_fonts();
    create_font( &deffonts->SystemFont );
    create_font( &deffonts->DeviceDefaultFont );

    PALETTE_Init();

    create_font( &deffonts->SystemFixedFont );
    create_font( &deffonts->DefaultGuiFont );

    create_brush( &DCBrush );
    NtGdiCreatePen( PS_SOLID, 0, RGB(0,0,0), NULL );

    obj = NtGdiCreateBitmap( 1, 1, 1, 1, NULL );

    assert( (HandleToULong( obj ) & 0xffff) == FIRST_GDI_HANDLE + DEFAULT_BITMAP );

    create_scaled_font( &deffonts->SystemFont, dpi );
    create_scaled_font( &deffonts->SystemFixedFont, dpi );
    create_scaled_font( &deffonts->DefaultGuiFont, dpi );

    /* clear the NOSYSTEM bit on all stock objects*/
    for (i = 0; i < STOCK_LAST + 5; i++)
    {
        GDI_HANDLE_ENTRY *entry = &gdi_shared->Handles[FIRST_GDI_HANDLE + i];
        entry_obj( entry )->system = TRUE;
        entry->StockFlag = 1;
    }
}


static const char *gdi_obj_type( unsigned type )
{
    switch ( type )
    {
        case NTGDI_OBJ_PEN: return "NTGDI_OBJ_PEN";
        case NTGDI_OBJ_BRUSH: return "NTGDI_OBJ_BRUSH";
        case NTGDI_OBJ_DC: return "NTGDI_OBJ_DC";
        case NTGDI_OBJ_METADC: return "NTGDI_OBJ_METADC";
        case NTGDI_OBJ_PAL: return "NTGDI_OBJ_PAL";
        case NTGDI_OBJ_FONT: return "NTGDI_OBJ_FONT";
        case NTGDI_OBJ_BITMAP: return "NTGDI_OBJ_BITMAP";
        case NTGDI_OBJ_REGION: return "NTGDI_OBJ_REGION";
        case NTGDI_OBJ_METAFILE: return "NTGDI_OBJ_METAFILE";
        case NTGDI_OBJ_MEMDC: return "NTGDI_OBJ_MEMDC";
        case NTGDI_OBJ_EXTPEN: return "NTGDI_OBJ_EXTPEN";
        case NTGDI_OBJ_ENHMETADC: return "NTGDI_OBJ_ENHMETADC";
        case NTGDI_OBJ_ENHMETAFILE: return "NTGDI_OBJ_ENHMETAFILE";
        default: return "UNKNOWN";
    }
}

static void dump_gdi_objects( void )
{
    GDI_HANDLE_ENTRY *entry;

    TRACE( "%u objects:\n", GDI_MAX_HANDLE_COUNT );

    pthread_mutex_lock( &gdi_lock );
    for (entry = gdi_shared->Handles; entry < next_unused; entry++)
    {
        if (!entry->Type)
            TRACE( "handle %p FREE\n", entry_to_handle( entry ));
        else
            TRACE( "handle %p obj %s type %s selcount %u deleted %u\n",
                   entry_to_handle( entry ), wine_dbgstr_longlong( entry->Object ),
                   gdi_obj_type( entry->ExtType << NTGDI_HANDLE_TYPE_SHIFT ),
                   entry_obj( entry )->selcount, entry_obj( entry )->deleted );
    }
    pthread_mutex_unlock( &gdi_lock );
}

/***********************************************************************
 *           alloc_gdi_handle
 *
 * Allocate a GDI handle for an object, which must have been allocated on the process heap.
 */
HGDIOBJ alloc_gdi_handle( struct gdi_obj_header *obj, DWORD type, const struct gdi_obj_funcs *funcs )
{
    GDI_HANDLE_ENTRY *entry;
    HGDIOBJ ret;

    assert( type );  /* type 0 is reserved to mark free entries */

    win32u_gdi_check_publish();

    pthread_mutex_lock( &gdi_lock );

    entry = next_free;
    if (entry)
        next_free = (GDI_HANDLE_ENTRY *)(UINT_PTR)entry->Object;
    else if (next_unused < gdi_shared->Handles + GDI_MAX_HANDLE_COUNT)
        entry = next_unused++;
    else
    {
        pthread_mutex_unlock( &gdi_lock );
        ERR( "out of GDI object handles, expect a crash\n" );
        if (TRACE_ON(gdi)) dump_gdi_objects();
        return 0;
    }
    obj->funcs    = funcs;
    obj->selcount = 0;
    obj->system   = 0;
    obj->deleted  = 0;
    entry->Object  = (UINT_PTR)obj;
    entry->ExtType = type >> NTGDI_HANDLE_TYPE_SHIFT;
    entry->Type    = entry->ExtType & 0x1f;
    if (++entry->Generation == 0x80) entry->Generation = 1;
    ret = entry_to_handle( entry );
    pthread_mutex_unlock( &gdi_lock );
    TRACE( "allocated %s %p %u/%u\n", gdi_obj_type(type), ret,
           InterlockedIncrement( &debug_count ), GDI_MAX_HANDLE_COUNT );
    return ret;
}


/***********************************************************************
 *           free_gdi_handle
 *
 * Free a GDI handle and return a pointer to the object.
 */
void *free_gdi_handle( HGDIOBJ handle )
{
    void *object = NULL;
    GDI_HANDLE_ENTRY *entry;

    pthread_mutex_lock( &gdi_lock );
    if ((entry = handle_entry( handle )))
    {
        TRACE( "freed %s %p %u/%u\n", gdi_obj_type( entry->ExtType << NTGDI_HANDLE_TYPE_SHIFT ),
               handle, InterlockedDecrement( &debug_count ) + 1, GDI_MAX_HANDLE_COUNT );
        object = entry_obj( entry );
        entry->Type = 0;
        entry->Object = (UINT_PTR)next_free;
        next_free = entry;
    }
    pthread_mutex_unlock( &gdi_lock );
    return object;
}

DWORD get_gdi_object_type( HGDIOBJ obj )
{
    GDI_HANDLE_ENTRY *entry;
    win32u_gdi_check_publish();
    entry = handle_entry( obj );
    return entry ? entry->ExtType << NTGDI_HANDLE_TYPE_SHIFT : 0;
}

void set_gdi_client_ptr( HGDIOBJ obj, void *ptr )
{
    GDI_HANDLE_ENTRY *entry;
    win32u_gdi_check_publish();
    entry = handle_entry( obj );
    if (entry) entry->UserPointer = (UINT_PTR)ptr;
}

/***********************************************************************
 *           get_any_obj_ptr
 *
 * Return a pointer to, and the type of, the GDI object
 * associated with the handle.
 * The object must be released with GDI_ReleaseObj.
 */
void *get_any_obj_ptr( HGDIOBJ handle, DWORD *type )
{
    void *ptr = NULL;
    GDI_HANDLE_ENTRY *entry;

    win32u_gdi_check_publish();

    pthread_mutex_lock( &gdi_lock );

    if ((entry = handle_entry( handle )))
    {
        ptr = entry_obj( entry );
        *type = entry->ExtType << NTGDI_HANDLE_TYPE_SHIFT;
    }

    if (!ptr) pthread_mutex_unlock( &gdi_lock );
    return ptr;
}

/***********************************************************************
 *           GDI_GetObjPtr
 *
 * Return a pointer to the GDI object associated with the handle.
 * Return NULL if the object has the wrong type.
 * The object must be released with GDI_ReleaseObj.
 */
void *GDI_GetObjPtr( HGDIOBJ handle, DWORD type )
{
    DWORD ret_type;
    void *ptr = get_any_obj_ptr( handle, &ret_type );
    if (ptr && ret_type != type)
    {
        GDI_ReleaseObj( handle );
        ptr = NULL;
    }
    return ptr;
}

/***********************************************************************
 *           GDI_ReleaseObj
 *
 */
void GDI_ReleaseObj( HGDIOBJ handle )
{
    pthread_mutex_unlock( &gdi_lock );
}


/***********************************************************************
 *           NtGdiDeleteObjectApp    (win32u.@)
 *
 * Delete a Gdi object.
 *
 * PARAMS
 *  obj [I] Gdi object to delete
 *
 * RETURNS
 *  Success: TRUE. If obj was not returned from GetStockObject(), any resources
 *           it consumed are released.
 *  Failure: FALSE, if obj is not a valid Gdi object, or is currently selected
 *           into a DC.
 */
BOOL WINAPI NtGdiDeleteObjectApp( HGDIOBJ obj )
{
    GDI_HANDLE_ENTRY *entry;
    const struct gdi_obj_funcs *funcs = NULL;
    struct gdi_obj_header *header;

    win32u_gdi_check_publish();

    pthread_mutex_lock( &gdi_lock );
    if (!(entry = handle_entry( obj )))
    {
        pthread_mutex_unlock( &gdi_lock );
        return FALSE;
    }

    header = entry_obj( entry );
    if (header->system)
    {
	TRACE("Preserving system object %p\n", obj);
        pthread_mutex_unlock( &gdi_lock );
	return TRUE;
    }

    obj = entry_to_handle( entry );  /* make it a full handle */

    if (header->selcount)
    {
        TRACE("delayed for %p because object in use, count %u\n", obj, header->selcount );
        header->deleted = 1;  /* mark for delete */
    }
    else funcs = header->funcs;

    pthread_mutex_unlock( &gdi_lock );

    TRACE("%p\n", obj );

    if (funcs && funcs->pDeleteObject) return funcs->pDeleteObject( obj );
    return TRUE;
}

/***********************************************************************
 *           NtGdiCreateClientObj    (win32u.@)
 */
HANDLE WINAPI NtGdiCreateClientObj( ULONG type )
{
    struct gdi_obj_header *obj;
    HGDIOBJ handle;

    if (!(obj = malloc( sizeof(*obj) )))
        return 0;

    handle = alloc_gdi_handle( obj, type, NULL );
    if (!handle) free( obj );
    return handle;
}

/***********************************************************************
 *           NtGdiDeleteClientObj    (win32u.@)
 */
BOOL WINAPI NtGdiDeleteClientObj( HGDIOBJ handle )
{
    void *obj;
    if (!(obj = free_gdi_handle( handle ))) return FALSE;
    free( obj );
    return TRUE;
}


/***********************************************************************
 *           NtGdiExtGetObjectW    (win32u.@)
 */
INT WINAPI NtGdiExtGetObjectW( HGDIOBJ handle, INT count, void *buffer )
{
    GDI_HANDLE_ENTRY *entry;
    const struct gdi_obj_funcs *funcs = NULL;
    INT result = 0;

    TRACE("%p %d %p\n", handle, count, buffer );

    pthread_mutex_lock( &gdi_lock );
    if ((entry = handle_entry( handle )))
    {
        funcs = entry_obj( entry )->funcs;
        handle = entry_to_handle( entry );  /* make it a full handle */
    }
    pthread_mutex_unlock( &gdi_lock );

    if (funcs && funcs->pGetObjectW)
    {
        if (buffer && ((ULONG_PTR)buffer >> 16) == 0) /* catch apps getting argument order wrong */
            RtlSetLastWin32Error( ERROR_NOACCESS );
        else
            result = funcs->pGetObjectW( handle, count, buffer );
    }
    return result;
}

/***********************************************************************
 *           NtGdiGetDCObject    (win32u.@)
 *
 * Get the currently selected object of a given type in a device context.
 */
HANDLE WINAPI NtGdiGetDCObject( HDC hdc, UINT type )
{
    HGDIOBJ ret = 0;
    DC *dc;

    if (!(dc = get_dc_ptr( hdc ))) return 0;

    switch (type)
    {
    case NTGDI_OBJ_EXTPEN: /* fall through */
    case NTGDI_OBJ_PEN:    ret = dc->hPen; break;
    case NTGDI_OBJ_BRUSH:  ret = dc->hBrush; break;
    case NTGDI_OBJ_PAL:    ret = dc->hPalette; break;
    case NTGDI_OBJ_FONT:   ret = dc->hFont; break;
    case NTGDI_OBJ_SURF:
        /* Update bitmap for display device contexts */
        if (dc->is_display) dc->hBitmap = get_display_bitmap();
        ret = dc->hBitmap; break;
    default:
        FIXME( "(%p, %d): unknown type.\n", hdc, type );
        break;
    }
    release_dc_ptr( dc );
    return ret;
}


/***********************************************************************
 *           NtGdiUnrealizeObject    (win32u.@)
 */
BOOL WINAPI NtGdiUnrealizeObject( HGDIOBJ obj )
{
    const struct gdi_obj_funcs *funcs = NULL;
    GDI_HANDLE_ENTRY *entry;

    pthread_mutex_lock( &gdi_lock );
    if ((entry = handle_entry( obj )))
    {
        funcs = entry_obj( entry )->funcs;
        obj = entry_to_handle( entry );  /* make it a full handle */
    }
    pthread_mutex_unlock( &gdi_lock );

    if (funcs && funcs->pUnrealizeObject) return funcs->pUnrealizeObject( obj );
    return funcs != NULL;
}


/***********************************************************************
 *           NtGdiFlush    (win32u.@)
 */
BOOL WINAPI NtGdiFlush(void)
{
    return TRUE;  /* FIXME */
}


/*******************************************************************
 *           NtGdiGetColorAdjustment    (win32u.@)
 */
BOOL WINAPI NtGdiGetColorAdjustment( HDC hdc, COLORADJUSTMENT *ca )
{
    FIXME( "stub\n" );
    return FALSE;
}

/*******************************************************************
 *           NtGdiSetColorAdjustment    (win32u.@)
 */
BOOL WINAPI NtGdiSetColorAdjustment( HDC hdc, const COLORADJUSTMENT *ca )
{
    FIXME( "stub\n" );
    return FALSE;
}

void gdi_init(void)
{
    pthread_mutexattr_t attr;
    unsigned int dpi;

    pthread_mutexattr_init( &attr );
    pthread_mutexattr_settype( &attr, PTHREAD_MUTEX_RECURSIVE );
    pthread_mutex_init( &gdi_lock, &attr );
    pthread_mutexattr_destroy( &attr );

    init_gdi_shared();
    if (!gdi_shared) return;

    dpi = font_init();
    init_stock_objects( dpi );
}
