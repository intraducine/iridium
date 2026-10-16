"""Keep the pinned native emulation screen; replace its frontend with Iridium.

These hooks remove upstream widgets and input ownership, not merely their paint.
The PSP firmware utility dialogs remain part of the emulated game/PPGe renderer.
"""


def replace(text, old, new):
    if text.count(old) != 1:
        raise ValueError('PPSSPP frontend boundary changed: ' + old[:90])
    return text.replace(old, new)


def body(text, signature, replacement):
    start = text.index(signature)
    opening = text.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        if text[end] == '{': depth += 1
        elif text[end] == '}': depth -= 1
        end += 1
    return text[:opening + 1] + '\n' + replacement + '\n}' + text[end:]


def apply(name, text):
    if name == 'UI/NativeApp.cpp':
        text = replace(text, 'bool skipLogo = false;', 'bool skipLogo = true;')
        text = replace(text, '\tg_screenManager->SetBackgroundOverlayScreens(new BackgroundScreen(), new OSDOverlayScreen());',
                       '\t// Iridium owns loading, notifications and menus; no upstream overlay screens.')
    if name == 'UI/EmuScreen.cpp':
        text = '#include "IRPPSSPPNative.h"\n' + text
        text = body(text, 'void EmuScreen::CreateViews()', '''    // A structural root is required by the native boot/render lifecycle.
    // No PPSSPP controls, pause buttons, loading widgets or input targets exist.
    root_ = new UI::AnchorLayout(new UI::LayoutParams(UI::FILL_PARENT, UI::FILL_PARENT));''')
        text = body(text, 'bool EmuScreen::hasVisibleUI()', '    return false;')
        for signature, result in (
            ('bool EmuScreen::UnsyncKey(', '    return false;'),
            ('void EmuScreen::UnsyncAxis(', ''), ('bool EmuScreen::key(', '    return false;'),
            ('void EmuScreen::touch(', ''), ('void EmuScreen::runImDebugger()', ''),
            ('void EmuScreen::renderImDebugger()', ''),
        ): text = body(text, signature, result)
        for name_ in ('loadingViewVisible_', 'loadingViewColor_'):
            text = replace(text, '\t_dbg_assert_(' + name_ + ');', '')
        start = text.index('\tresumeButton_->SetVisibility', text.index('void EmuScreen::update()'))
        end = text.index('\n\tif (chatButton_', start)
        text = text[:start] + '''    ir_native_psp_frontend_frame();
''' + text[end:]
        start = text.index('\tif (!errorMessage_.empty())', text.index('void EmuScreen::update()'))
        end = text.index('\n\tif (pauseTrigger_)', start)
        text = text[:start] + '''    if (!errorMessage_.empty()) {
        ir_native_psp_frontend_event(2, errorMessage_.c_str());
        errorMessage_.clear();
        return;
    }
''' + text[end:]
        text = text.replace('screenManager()->push(new GamePauseScreen(gamePath_, bootPending_));',
                            'ir_native_psp_frontend_event(7, "Game requested the Iridium menu.");')
        text = text.replace('screenManager()->switchScreen(new MainScreen());', 'ir_native_psp_stop();')
        text = replace(text, '\tSystem_Notify(SystemNotification::BOOT_DONE);',
                       '\tSystem_Notify(SystemNotification::BOOT_DONE);\n\tir_native_psp_frontend_event(4, "Native game boot completed.");')
    if name == 'Core/HLE/sceCtrl.cpp':
        text = '#include "IRPPSSPPNative.h"\n' + text
        text = replace(text, '\t// This samples the ctrl data into the buffers and updates the latch.',
                       '\tir_native_psp_poll_input();\n\t// This samples the ctrl data into the buffers and updates the latch.')
    if name in ('ios/ViewController.mm', 'ios/ViewControllerMetal.mm'):
        text = body(text, '- (void)viewWillTransitionToSize:',
            '    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];\n'
            '    // The Iridium container serializes every viewport change with pause/close.')
    if name == 'ios/ViewControllerCommon.mm':
        text = body(text, '- (void)setupController:', '    // Iridium retains controller handlers and routing.')
        for signature in ('- (void)touchesBegan:', '- (void)touchesMoved:', '- (void)touchesEnded:',
                          '- (void)touchesCancelled:', '- (void)pressesBegan:', '- (void)pressesEnded:',
                          '- (void)pressesCancelled:', '- (void)showKeyboard', '- (void)hideKeyboard'):
            text = body(text, signature, '    // Display-only controller; the shared Iridium player owns input.')
        text = body(text, '- (void)viewSafeAreaInsetsDidChange', '''    [super viewSafeAreaInsetsDidChange];
    // The parent already places this surface inside Iridium's safe viewport.
    g_safeInsetLeft = g_safeInsetRight = g_safeInsetTop = g_safeInsetBottom = 0;''')
    return text


PATCHED = ('UI/EmuScreen.cpp', 'Core/HLE/sceCtrl.cpp')
