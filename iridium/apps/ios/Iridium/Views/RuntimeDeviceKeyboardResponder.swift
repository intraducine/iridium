#if os(iOS) && MADEIRA_RUNTIME
import UIKit

final class RuntimeDeviceKeyboardResponder: UIView, UIKeyInput {
    var onInsert: (String) -> Void = { _ in }
    var onDelete: () -> Void = {}
    var onDismiss: () -> Void = {}
    override var canBecomeFirstResponder: Bool { true }
    // The text belongs to the guest. UIKit must allow Backspace even though
    // this bridge intentionally has no local text buffer.
    var hasText: Bool { true }
    func insertText(_ text: String) { if isFirstResponder { onInsert(text) } }
    func deleteBackward() { if isFirstResponder { onDelete() } }

    private lazy var toolbar: UIToolbar = {
        let bar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        bar.items = [UIBarButtonItem(systemItem: .flexibleSpace),
                     UIBarButtonItem(title: "Done", style: .done, target: self, action: #selector(dismissKeyboard))]
        return bar
    }()
    override var inputAccessoryView: UIView? { toolbar }
    override var keyCommands: [UIKeyCommand]? {
        let escape = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(dismissKeyboard))
        escape.wantsPriorityOverSystemBehavior = true
        return [escape]
    }
    @objc private func dismissKeyboard() {
        _ = resignFirstResponder()
        onDismiss()
    }
    var keyboardType: UIKeyboardType { get { .asciiCapable } set {} }
    var autocorrectionType: UITextAutocorrectionType { get { .no } set {} }
    var autocapitalizationType: UITextAutocapitalizationType { get { .none } set {} }
    var smartQuotesType: UITextSmartQuotesType { get { .no } set {} }
    var smartDashesType: UITextSmartDashesType { get { .no } set {} }
    var spellCheckingType: UITextSpellCheckingType { get { .no } set {} }
}
#endif
