"""Present the native directory picker inside its active Iridium session."""
def replace(text, old, new):
    if text.count(old) != 1: raise ValueError('Picker ownership hook changed: ' + old[:80])
    return text.replace(old, new)


NAME = 'Core/Util/DarwinFileSystemServices.mm'


def apply(text):
    text = '#include "IRPPSSPPNative.h"\n' + text
    text = replace(text, '@property DarwinDirectoryPanelCallback panelCallback;',
                   '@property DarwinDirectoryPanelCallback panelCallback;\n@property BOOL iridiumResolved;\n@property uint64_t iridiumOwner;\n@property (weak) UIDocumentPickerViewController *iridiumPicker;\n- (void)iridiumCancel;')
    start = text.index('\t// TODO: Figure out how to free the delegate.')
    end = text.index('\n}', start)
    text = text[:start] + '\tif (__pickerDelegate) CFRelease(__pickerDelegate);\n\t__pickerDelegate = nullptr;' + text[end:]
    text = replace(text, '\t\tself.panelCallback = panelCallback;',
                   '\t\tself.panelCallback = panelCallback;\n\t\tself.iridiumOwner = ir_native_psp_generation();')
    text = replace(text, 'static void addBookmark(NSURL *url);', '''- (void)iridiumFinish:(bool)success path:(Path)path {
    if (self.iridiumResolved) return;
    self.iridiumResolved = YES;
    self.iridiumPicker.delegate = nil;
    DarwinDirectoryPanelCallback callback = self.panelCallback;
    self.panelCallback = {};
    ir_native_psp_presentation_finished(self.iridiumPicker);
    DarwinFileSystemServices::ClearDelegate();
    callback(success, path);
}
- (void)iridiumCancel { [self iridiumFinish:false path:Path()]; }

static void addBookmark(NSURL *url);''')
    text = replace(text, '\tNSURL *url = urls.firstObject;',
                   '\tif (self.iridiumResolved) return;\n\tif (!ir_native_psp_generation_current(self.iridiumOwner)) { [self iridiumCancel]; return; }\n\tNSURL *url = urls.firstObject;')
    text = text.replace('self.panelCallback(false, Path());', '[self iridiumCancel];')
    text = replace(text, 'BOOL success = [url startAccessingSecurityScopedResource];', 'BOOL success = activeAccessTokens.count(url.path.UTF8String) != 0;')
    text = replace(text, 'self.panelCallback(true, Path(url.path.UTF8String));', '[self iridiumFinish:true path:Path(url.path.UTF8String)];')
    # Completion now releases the retained delegate exactly once, before any new picker.
    text = replace(text, '\t[sharedViewController hideKeyboard];\n\tDarwinFileSystemServices::ClearDelegate();', '\t[sharedViewController hideKeyboard];')
    text = replace(text, '\tdispatch_async(dispatch_get_main_queue(), ^{\n#if PPSSPP_PLATFORM(MAC)',
                   '\tuint64_t owner = ir_native_psp_generation();\n\tdispatch_async(dispatch_get_main_queue(), ^{\n#if PPSSPP_PLATFORM(MAC)')
    start = text.index('\t\tUIViewController *rootViewController = UIApplication.sharedApplication')
    end = text.index('\t\tNSMutableArray<NSString *> *types', start)
    text = text[:start] + '\t\tif (!ir_native_psp_generation_current(owner) || __pickerDelegate) { panelCallback(false, Path()); return; }\n\n' + text[end:]
    text = replace(text, '\t\tpickerVC.delegate = (__bridge DocumentPickerDelegate *)__pickerDelegate;\n\t\t[rootViewController presentViewController:pickerVC animated:true completion:nil];',
                   '\t\tDocumentPickerDelegate *delegate = (__bridge DocumentPickerDelegate *)__pickerDelegate;\n\t\tdelegate.iridiumPicker = pickerVC;\n\t\tpickerVC.delegate = delegate;\n\t\tir_native_psp_present(pickerVC, ^{ [delegate iridiumCancel]; });')
    return text
