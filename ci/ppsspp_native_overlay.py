"""Embed the pinned upstream iOS frontend without changing emulator internals."""
from pathlib import Path

REVISION = 'fa50bb1976065c4f8b1b47af227d367fe9771555'


def replace(text, old, new):
    if text.count(old) != 1:
        raise ValueError('PPSSPP embedding hook changed: ' + old[:90])
    return text.replace(old, new)


def apply(name, text):
    if name == 'CMakeLists.txt':
        text = replace(text, 'set(CMAKE_OSX_DEPLOYMENT_TARGET "12.0")',
                       'if(NOT CMAKE_OSX_DEPLOYMENT_TARGET)\n\t\t\tset(CMAKE_OSX_DEPLOYMENT_TARGET "12.0")\n\t\tendif()')
        text = replace(text, 'XCODE_ATTRIBUTE_DEVELOPMENT_TEAM ${DEVELOPMENT_TEAM_ID}',
                       'XCODE_ATTRIBUTE_DEVELOPMENT_TEAM "${DEVELOPMENT_TEAM_ID}"')
    if name == 'UI/NativeApp.cpp':
        text = replace(text,
            '#elif PPSSPP_PLATFORM(IOS)\n\tg_Config.defaultCurrentDirectory = g_Config.internalDataDirectory;\n\tg_Config.memStickDirectory = DarwinFileSystemServices::appropriateMemoryStickDirectoryToUse();',
            '#elif PPSSPP_PLATFORM(IOS)\n\tg_Config.defaultCurrentDirectory = g_Config.internalDataDirectory;\n\tg_Config.memStickDirectory = Path(savegame_dir);')
    if name == 'ios/main.mm':
        text = '#include "IRPPSSPPNative.h"\n' + text
        start = text.index('int main(int argc, char *argv[]) {')
        text = text[:start] + '''void ir_native_psp_platform_init() {
    version = [[[UIDevice currentDevice] systemVersion] UTF8String];
    if (sscanf(version.c_str(), "%d", &g_iosVersionMajor) != 1) g_iosVersionMajor = 0;
}
'''
        text = replace(text, 'return g_jitAvailable;', 'return ir_native_psp_jit_available();')
        text = replace(text, '#elif PPSSPP_PLATFORM(IOS_APP_STORE)\n\t\t\t// Check the IAP status.',
                       '#elif PPSSPP_PLATFORM(IOS_APP_STORE) && defined(USE_IAP)\n\t\t\t// Check the IAP status.')
        start = text.index('\tcase SystemRequestType::RESTART_APP:')
        end = text.index('\tcase SystemRequestType::BROWSE_FOR_FILE:', start)
        text = text[:start] + '''    case SystemRequestType::RESTART_APP:
        ir_native_psp_restart();
        return true;
    case SystemRequestType::EXIT_APP:
        ir_native_psp_stop();
        return true;
''' + text[end:]
        start = text.index('void System_Vibrate(int mode) {')
        end = text.index('AudioBackend *System_CreateAudioBackend()', start)
        text = text[:start] + '''void System_Vibrate(int mode) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UISelectionFeedbackGenerator *feedback = [[UISelectionFeedbackGenerator alloc] init];
        [feedback selectionChanged];
    });
}

''' + text[end:]
    if name in ('ios/ViewController.mm', 'ios/ViewControllerMetal.mm'):
        text = '#include "IRPPSSPPNative.h"\n' + text
        text = replace(text, 'static std::atomic<bool> renderLoopRunning;',
                       'static std::atomic<bool> renderLoopRunning;\nstatic std::atomic<bool> iridiumLoopStarted;')
        text = replace(text, '\trenderLoopRunning = true;',
                       '\trenderLoopRunning = true;\n\tiridiumLoopStarted = true;')
        text = replace(text, '\tg_renderLoopThread = std::thread(',
                       '\tiridiumLoopStarted = false;\n\tg_renderLoopThread = std::thread(')
        text = replace(text, '\t\tNativeFrame(graphicsContext);',
                       '\t\tNativeFrame(graphicsContext);\n\t\tir_native_psp_frame();')
        if name.endswith('/ViewController.mm'):
            text = replace(text, '\tNativeInitGraphics(graphicsContext);',
                           '\tif (!NativeInitGraphics(graphicsContext)) { ir_native_psp_renderer_failed(); exitRenderLoop = true; }\n\telse ir_native_psp_renderer_ready();')
        else:
            text = replace(text, 'ERROR_LOG(Log::G3D, "Failed to initialize graphics.");',
                           'ERROR_LOG(Log::G3D, "Failed to initialize graphics.");\n\t\t\tir_native_psp_renderer_failed();\n\t\t\texitRenderLoop = true;')
            text = replace(text, '\t\tgraphicsContext->ThreadStart();',
                           '\t\tgraphicsContext->ThreadStart();\n\t\tir_native_psp_renderer_ready();')
            text = replace(text, '\t\t_assert_msg_(false, "Failed to init Vulkan");',
                           '\t\tir_native_psp_renderer_failed();\n\t\tdelete graphicsContext; graphicsContext = nullptr;\n\t\tfinalize_glslang();\n\t\treturn;')
            text = replace(text, '\t\tdelete graphicsContext;\n\t\tgraphicsContext = nullptr;\n\t\trenderLoopRunning = false;',
                           '\t\tir_native_psp_renderer_failed();\n\t\trenderLoopRunning = false;')
            # Early cancellation/failure still completes the started-thread handshake.
            text = text.replace('\t\trenderLoopRunning = false;\n',
                                '\t\trenderLoopRunning = false;\n\t\tiridiumLoopStarted = true;\n')
        text = replace(text, 'UIScreen* screen = [(AppDelegate*)[UIApplication sharedApplication].delegate screen];',
                       'UIScreen* screen = self.view.window.windowScene.screen ?: UIScreen.mainScreen;')
        pause_display = 'self.displayLink.paused = YES;' if name.endswith('/ViewController.mm') else ''
        stop_method = '''- (void)iridiumStopRenderLoop:(void (^)(void))completion {
    NSAssert(NSThread.isMainThread, @"Renderer lifecycle belongs to the main thread");
    [super willResignActive];
    exitRenderLoop = true;
    [self iridiumAwaitRenderLoop:completion];
}

- (void)iridiumAwaitRenderLoop:(void (^)(void))completion {
    if (!g_renderLoopThread.joinable() || (iridiumLoopStarted && !renderLoopRunning)) {
        if (g_renderLoopThread.joinable()) g_renderLoopThread.join();
        exitRenderLoop = false;
        PAUSE_DISPLAY
        completion();
        return;
    }
    // Keep the main run loop free to drain GL commands and Vulkan surface callbacks.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 16 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        [self iridiumAwaitRenderLoop:completion];
    });
}

'''.replace('PAUSE_DISPLAY', pause_display)
        text = text.replace('forMode:NSDefaultRunLoopMode', 'forMode:NSRunLoopCommonModes')
        text = replace(text, '- (void)willResignActive {', stop_method + '- (void)willResignActive {')
        if name.endswith('/ViewController.mm'):
            text = replace(text, '\t\tgraphicsContext->ThreadFrame(true);',
                           '\t\tgraphicsContext->ThreadFrame(!exitRenderLoop.load());')
            text = replace(text, '\texitRenderLoop = false;\n\trenderLoopRunning = false;',
                           '\t// The UI owner clears the stop flag after joining.\n\trenderLoopRunning = false;')
            text = replace(text, '\t[super shutdown];\n', '\t[self.displayLink invalidate];\n\tself.displayLink = nil;\n\t[super shutdown];\n')
            text = replace(text, '\tif (self.context) {\n\t\tif ([EAGLContext currentContext] == self.context) {\n\t\t\t[EAGLContext setCurrentContext:nil];\n\t\t}\n\t\tself.context = nil;\n\t}',
                           '\tif ([EAGLContext currentContext] == self.glContext) [EAGLContext setCurrentContext:nil];\n\tself.glView.delegate = nil;\n\tself.glContext = nil;')
        # Rotation must share the same drain path and cannot restart a closing owner.
        renderer = 'GL' if name.endswith('/ViewController.mm') else 'Vulkan'
        text = replace(text,
            '\t\t[self requestExit' + renderer + 'RenderLoop];\n\t\t[self updateResolutionWithView:self.view];\n\t\t[self run' + renderer + 'RenderLoop];',
            '\t\t[self iridiumStopRenderLoop:^{\n\t\t\tif (ir_native_psp_should_render()) [self didBecomeActive];\n\t\t}];')
    if name == 'ios/ViewControllerCommon.mm':
        text = '#include "IRPPSSPPNative.h"\n' + text
        text = replace(text, '#if PPSSPP_PLATFORM(IOS_APP_STORE)\n\t[IAPManager sharedIAPManager];',
                       '#if PPSSPP_PLATFORM(IOS_APP_STORE) && defined(USE_IAP)\n\t[IAPManager sharedIAPManager];')
        text = replace(text, '- (void)setupController:(GCController *)controller {',
                       '- (void)setupController:(GCController *)controller {\n\tir_native_psp_capture_controller((__bridge void *)controller);')
    return text


PATCHED = ('CMakeLists.txt', 'UI/NativeApp.cpp', 'ios/main.mm', 'ios/ViewController.mm', 'ios/ViewControllerMetal.mm', 'ios/ViewControllerCommon.mm')


def stage(source, destination):
    """Mirror immutable source; only declared platform/ownership hooks are copied."""
    source = source.resolve(strict=True)
    destination.mkdir(parents=True, exist_ok=True)
    for relative in ('', 'ios', 'UI'):
        target = destination / relative
        target.mkdir(exist_ok=True)
        for origin in (source / relative).iterdir():
            if origin.name in ('.git', '.DS_Store'):
                continue
            name = origin.relative_to(source).as_posix()
            child = target / origin.name
            if name in ('ios', 'UI'):
                continue
            if name in PATCHED:
                if child.is_symlink():
                    child.unlink()  # Never write a newly adapted file through an old mirror link.
                with origin.open(newline='') as stream:
                    text = stream.read()
                newline = '\r\n' if '\r\n' in text else '\n'
                with child.open('w', newline='') as stream:
                    stream.write(apply(name, text.replace('\r\n', '\n')).replace('\n', newline))
            elif not child.exists():
                child.symlink_to(origin, target_is_directory=origin.is_dir())
