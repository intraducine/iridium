#include "wine/iridium.h"

#include <stdio.h>

static int require_valid( unsigned long long base, unsigned long long size, int expected )
{
    int actual = iridium_guest_image_range_is_valid( base, size );
    if (!!actual == !!expected) return 0;
    fprintf( stderr, "range %#llx+%#llx validity=%d expected=%d\n",
             base, size, actual, expected );
    return 1;
}

int main(void)
{
    int failed = 0;

    failed |= require_valid( IRIDIUM_GUEST_IMAGE_ARENA_ADDRESS, 0x1000, 1 );
    failed |= require_valid( IRIDIUM_GUEST_IMAGE_ARENA_END - 0x1000, 0x1000, 1 );
    failed |= require_valid( IRIDIUM_GUEST_IMAGE_ARENA_ADDRESS - 0x1000, 0x1000, 0 );
    failed |= require_valid( IRIDIUM_GUEST_IMAGE_ARENA_END, 0x1000, 0 );
    failed |= require_valid( IRIDIUM_GUEST_IMAGE_ARENA_ADDRESS, 0, 0 );
    failed |= require_valid( IRIDIUM_GUEST_IMAGE_ARENA_ADDRESS,
                             IRIDIUM_GUEST_IMAGE_ARENA_SIZE + 1, 0 );

    /* Exact impossible kernelbase.dll base observed on physical build 56. */
    failed |= require_valid( 0x1005800000000ULL, 0x2a7000ULL, 0 );
    failed |= require_valid( ~0ULL - 0x1000, 0x4000, 0 );

    return failed;
}
