// SPDX-License-Identifier: AGPL-3.0-only
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include <atomic>

static std::atomic<void *> metal_layer{nullptr};

extern "C" bool ir_phase3_core_set_metal_surface(void *surface) {
    if (surface) {
        CAMetalLayer *layer = (__bridge CAMetalLayer *)surface;
        layer.device = MTLCreateSystemDefaultDevice();
        if (!layer.device) return false;
        layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        layer.framebufferOnly = NO;
        // Match the selected native 400x480 layout. The layer scales it to the view.
        layer.drawableSize = CGSizeMake(400, 480);
    }
    metal_layer.store(surface);
    return true;
}

extern "C" void *ir_azahar_metal_layer() {
    return metal_layer.load();
}

namespace AppleUtils {
float GetRefreshRate() {
    // The libretro contract paces this surface at 60 Hz.
    return 60;
}
int IsLowPowerModeEnabled() {
    return NSProcessInfo.processInfo.lowPowerModeEnabled;
}
}
