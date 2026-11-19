import AppKit
import SwiftUI

/// Två tvåsiffriga fält med ett fast kolon emellan (MM:SS eller HH:MM). Byggt i AppKit, eftersom SwiftUI:s fält
/// varken markerar allt vid ett klick eller låter markören hoppa vidare pålitligt i en popover.
struct TimePairField: NSViewRepresentable {
    @Binding var parts: [String]
    var placeholders: (String, String)
    var autofocus = false
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSStackView {
        let c = context.coordinator
        let colon = NSTextField(labelWithString: ":")
        colon.font = .systemFont(ofSize: 13, weight: .semibold)
        let stack = NSStackView(views: [c.first, colon, c.second])
        stack.spacing = 2
        for (field, placeholder) in [(c.first, placeholders.0), (c.second, placeholders.1)] {
            field.placeholderString = placeholder
            field.delegate = c
            field.widthAnchor.constraint(equalToConstant: 40).isActive = true
        }
        c.first.nextKeyView = c.second
        c.second.nextKeyView = c.first
        c.first.stringValue = parts[0]
        c.second.stringValue = parts[1]
        if autofocus {
            // Fönstret finns först när vyn har lagts in.
            // Popoverns fönster blir nyckelfönster en stund efter att den visats, så försök igen strax efter.
            for delay in [0.05, 0.25] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    guard let window = c.first.window, c.first.currentEditor() == nil, c.second.currentEditor() == nil else { return }
                    window.makeFirstResponder(c.first)
                }
            }
        }
        return stack
    }

    func updateNSView(_ stack: NSStackView, context: Context) {
        let c = context.coordinator
        c.parent = self
        for (i, field) in [c.first, c.second].enumerated() where field.currentEditor() == nil && field.stringValue != parts[i] {
            field.stringValue = parts[i]
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: TimePairField
        let first = SelectAllField()
        let second = SelectAllField()

        init(_ parent: TimePairField) { self.parent = parent }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            var digits = field.stringValue.filter(\.isWholeNumber)
            if digits.count > 2 {
                // Fältet var fullt utan markering: siffran som just skrevs börjar om fältet i stället för att försvinna.
                let text = field.stringValue as NSString
                let caret = field.currentEditor()?.selectedRange.location ?? text.length
                let typed = caret > 0 ? text.substring(with: NSRange(location: caret - 1, length: 1)) : ""
                digits = typed.allSatisfy(\.isWholeNumber) && !typed.isEmpty ? typed : String(digits.prefix(2))
            }
            if field.stringValue != digits { field.stringValue = digits }
            let index = field === first ? 0 : 1
            parent.parts[index] = digits
            // Två siffror i första fältet: vidare till det andra, där innehållet markeras och skrivs över.
            if index == 0 && digits.count == 2 { field.window?.makeFirstResponder(second) }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
                return true
            case #selector(NSResponder.deleteBackward(_:)) where control === second && second.stringValue.isEmpty:
                // Backsteg i ett tomt andra fält: tillbaka till det första med markören sist.
                first.selectAllOnFocus = false
                control.window?.makeFirstResponder(first)
                first.currentEditor()?.selectedRange = NSRange(location: first.stringValue.count, length: 0)
                first.selectAllOnFocus = true
                return true
            default:
                return false
            }
        }
    }
}

/// Markerar hela innehållet när fältet får fokus och vid varje enkelklick, så att det som skrivs ersätter det.
final class SelectAllField: NSTextField {
    override class var cellClass: AnyClass? {
        get { SelectAllCell.self }
        set {}
    }

    var selectAllOnFocus = true

    convenience init() {
        self.init(frame: .zero)
        isEditable = true
        isSelectable = true
        isBezeled = true
        bezelStyle = .roundedBezel
        alignment = .center
        // Den egna cellen börjar som en etikett som radbryter, så den andra siffran hamnade på en osynlig rad.
        cell?.wraps = false
        cell?.isScrollable = true
        cell?.usesSingleLineMode = true
        font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    }

    // Snabbpanelen aktiverar aldrig appen, så första klicket måste räknas.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Klick som når fältet i stället för fältredigeraren (när det inte redan redigeras): markera allt efteråt.
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        currentEditor()?.selectAll(nil)
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok && selectAllOnFocus { DispatchQueue.main.async { [weak self] in self?.currentEditor()?.selectAll(nil) } }
        return ok
    }
}

/// Ger fältet en egen fältredigerare, eftersom klicken går till den och inte till fältet medan man skriver.
private final class SelectAllCell: NSTextFieldCell {
    private lazy var editor: SelectAllEditor = {
        let editor = SelectAllEditor()
        editor.isFieldEditor = true
        return editor
    }()

    override func fieldEditor(for controlView: NSView) -> NSTextView? { editor }
}

/// Fältredigeraren följer musen tills knappen släpps; därefter markeras allt i stället för att markören hamnar där man klickade.
private final class SelectAllEditor: NSTextView {
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        selectAll(nil)
    }
}
