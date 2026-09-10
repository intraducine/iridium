/* Iridium-specific Wine runtime constants. */

#ifndef __WINE_IRIDIUM_H
#define __WINE_IRIDIUM_H

/* Keep the relocated KUSER_SHARED_DATA page and the syscall-dispatch pointer
 * synchronized across Wine modules. The address is 16 KiB aligned for iOS. */
#define IRIDIUM_USER_SHARED_DATA_ADDRESS 0x7000000000ULL
#define IRIDIUM_USER_SHARED_DATA_SYSCALL_ADDRESS_ASM "0x7000001000"
#define IRIDIUM_USER_SHARED_DATA_PREFIX_SIZE 0x10000ULL
#define IRIDIUM_TEB_ARENA_SIZE 0x02000000ULL
#define IRIDIUM_USER_SHARED_DATA_RESERVE_SIZE 0x04010000ULL

/* iOS reserves the host range immediately below 0x7000000000 and Wine cannot
 * create arbitrary fixed mappings there. Reserve relocatable PE image space
 * above the shared-data and TEB range before FEX starts, so DLL mappings
 * replace an existing guest-owned placeholder. Keep this synchronized with
 * iridium-fex-ios. */
#define IRIDIUM_GUEST_IMAGE_ARENA_SIZE 0x80000000ULL
#define IRIDIUM_GUEST_HIGH_ARENA_ADDRESS IRIDIUM_USER_SHARED_DATA_ADDRESS
#define IRIDIUM_GUEST_IMAGE_ARENA_ADDRESS \
    (IRIDIUM_USER_SHARED_DATA_ADDRESS + IRIDIUM_USER_SHARED_DATA_RESERVE_SIZE)
#define IRIDIUM_GUEST_IMAGE_ARENA_END \
    (IRIDIUM_GUEST_IMAGE_ARENA_ADDRESS + IRIDIUM_GUEST_IMAGE_ARENA_SIZE)
#define IRIDIUM_GUEST_HIGH_ARENA_RESERVE_SIZE \
    (IRIDIUM_GUEST_IMAGE_ARENA_SIZE + IRIDIUM_USER_SHARED_DATA_RESERVE_SIZE)

/* Validate cached/server-selected PE ranges before ntdll attempts a fixed
 * mapping. In the embedded iOS process a stale Darwin/FEX address can be a
 * syntactically valid 64-bit pointer while still sitting outside the only
 * guest range the host reserved for PE images. Keep the overflow check in the
 * shared contract so the Wine client and embedded server cannot disagree. */
static inline int iridium_guest_image_range_is_valid( unsigned long long base,
                                                       unsigned long long size )
{
    return size && base >= IRIDIUM_GUEST_IMAGE_ARENA_ADDRESS &&
           size <= IRIDIUM_GUEST_IMAGE_ARENA_SIZE &&
           base <= IRIDIUM_GUEST_IMAGE_ARENA_END - size;
}

#endif /* __WINE_IRIDIUM_H */
