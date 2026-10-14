"""Reject retired UIKit/input callbacks before native teardown or a new session."""
import re


def apply(name, text):
    guard = 'if (!ir_native_psp_generation_current(iridiumOwnerGeneration)) return;'
    if name == 'ios/main.mm':
        # These entry points may originate from emulation/network workers. Every
        # queued UIKit effect captures the requesting session, not the global VC.
        for signature, end in (
            ('void System_Notify(', 'bool System_MakeRequest('),
            ('bool System_MakeRequest(', 'void System_Toast('),
            ('void System_LaunchUrl(', 'PermissionStatus System_GetPermissionStatus('),
            ('void System_Vibrate(', 'AudioBackend *System_CreateAudioBackend('),
        ):
            start = text.index(signature); stop = text.index(end, start)
            region = text[start:stop]
            brace = region.index('{')
            region = region[:brace+1] + '\n\tuint64_t iridiumCallbackOwner = ir_native_psp_generation();\n' + region[brace+1:]
            region = region.replace('dispatch_async(dispatch_get_main_queue(), ^{',
                'dispatch_async(dispatch_get_main_queue(), ^{\n\t\tif (!ir_native_psp_generation_current(iridiumCallbackOwner)) return;')
            # Direct controller accesses must also be performed on the UI thread.
            if signature.startswith('bool System_MakeRequest'):
                region = region.replace('DarwinDirectoryPanelCallback callback = [requestId] (bool success, Path path) {',
                    'DarwinDirectoryPanelCallback callback = [requestId, iridiumCallbackOwner] (bool success, Path path) {\n\t\t\tif (!ir_native_psp_generation_current(iridiumCallbackOwner)) return;')
                region = region.replace('[sharedViewController shareText:text];',
                    'dispatch_async(dispatch_get_main_queue(), ^{\n\t\t\tif (ir_native_psp_generation_current(iridiumCallbackOwner)) [sharedViewController shareText:text];\n\t\t});')
                a = region.index('\t\tswitch ((UIEventNotification)param3)'); b = region.index('\n\t\treturn true;', a)
                body = region[a:b]
                region = region[:a] + '\t\tdispatch_async(dispatch_get_main_queue(), ^{\n\t\t\tif (!ir_native_psp_generation_current(iridiumCallbackOwner)) return;\n' + body + '\n\t\t});' + region[b:]
            text = text[:start] + region + text[stop:]
    if name == 'ios/Controls.mm':
        text = '#include "IRPPSSPPNative.h"\n' + text
        text = text.replace('bool InitController(GCController *controller) {',
            'bool InitController(GCController *controller) {\n\tuint64_t iridiumCallbackOwner = ir_native_psp_generation();')
        pattern = r'(\.valueChangedHandler = \^\([^\n]+\) \{\n)(.*?)(\n(\t+)\};)'
        def wrap(match):
            indent = match[4]
            return match[1] + indent + '\tdispatch_async(dispatch_get_main_queue(), ^{\n' + indent + '\t\tif (!ir_native_psp_generation_current(iridiumCallbackOwner)) return;\n' + match[2] + '\n' + indent + '\t});' + match[3]
        text, count = re.subn(pattern, wrap, text, flags=re.S)
        if count != 21: raise ValueError('Controller handler inventory changed: ' + str(count))
    if name == 'ios/ViewControllerCommon.mm':
        # Main-thread input and UIKit delegates all share the same owner gate.
        names = ('savePickedImage', 'setupController', 'touchesBegan', 'touchesMoved', 'touchesEnded',
                 'touchesCancelled', 'pickPhoto', 'picker', 'imagePickerController', 'imagePickerControllerDidCancel',
                 'handleSwipeFrom', 'deleteBackward', 'insertText', 'buttonDown', 'buttonUp',
                 'pressesBegan', 'pressesEnded', 'pressesCancelled', 'controllerDidConnect', 'controllerDidDisconnect',
                 'updateResolutionWithView')
        for name_ in names:
            pattern = r'(- \(void\)' + name_ + r'\b[^{]*\{)'
            text, count = re.subn(pattern, lambda m: m[0] + '\n\t' + guard, text, count=1)
            if count != 1: raise ValueError('Callback owner hook changed: ' + name_)
        # The provider can return after the modal and its owning session closed.
        text = text.replace('dispatch_async(dispatch_get_main_queue(), ^{',
                            'dispatch_async(dispatch_get_main_queue(), ^{\n\t\t' + guard)
        # Register pending photo requests with the owning host so close cancels them
        # before NativeShutdown destroys the request manager. Late results are gated.
        text = text.replace('[self presentViewController:picker animated:YES completion:nil];',
            'ir_native_psp_present(picker, ^{\n\t\tpicker.delegate = nil;\n\t\tg_requestManager.PostSystemFailure(requestId);\n\t});')
        text = text.replace('[picker dismissViewControllerAnimated:YES completion:nil];',
                            'ir_native_psp_presentation_finished(picker);\n\t[picker dismissViewControllerAnimated:YES completion:nil];')
        text = text.replace('UIActivityViewController * viewController = [[UIActivityViewController alloc] initWithActivityItems:items applicationActivities:nil];',
            'UIActivityViewController * viewController = [[UIActivityViewController alloc] initWithActivityItems:items applicationActivities:nil];\n\tviewController.popoverPresentationController.sourceView = self.view;\n\tviewController.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);')
        text = text.replace('[self presentViewController:viewController animated:YES completion:nil];',
                            'ir_native_psp_present(viewController, ^{});')
    return text
