import AppKit

/// Renaming a document from its title: a plain click on the window title (or
/// File → Rename…) shows a small popover with the name selected. Command-click
/// still shows the folder menu.
enum DocumentRename {
    enum RenameError: LocalizedError {
        case invalid, exists(String)
        var errorDescription: String? {
            switch self {
            case .invalid: return "A document name can't be empty or contain “/” or “:”."
            case .exists(let name): return "“\(name)” already exists in this folder. Choose a different name."
            }
        }
    }

    /// The file name for what was typed: the current extension is kept unless a
    /// document extension was typed.
    static func fileName(for input: String, current: String) throws -> String {
        let typed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty, !typed.contains("/"), !typed.contains(":"), typed != ".", typed != ".." else { throw RenameError.invalid }
        if MarkdownFile.documentExtensions.contains((typed as NSString).pathExtension.lowercased()) { return typed }
        let ext = (current as NSString).pathExtension
        return ext.isEmpty ? typed : "\(typed).\(ext)"
    }
}

/// A document window whose title can be clicked to rename the document.
final class DocumentWindow: NSWindow {
    var onTitleClick: (() -> Void)?

    /// AppKit's own title label in the title bar.
    var titleField: NSTextField? {
        func find(_ view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.stringValue == title, !field.isEditable { return field }
            for subview in view.subviews { if let found = find(subview) { return found } }
            return nil
        }
        return standardWindowButton(.closeButton)?.superview.flatMap(find)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, event.clickCount == 1, onTitleClick != nil,
           event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
           let field = titleField, field.bounds.contains(field.convert(event.locationInWindow, from: nil)) {
            onTitleClick?()
            return
        }
        super.sendEvent(event)
    }
}

/// The rename popover: a name field that commits on Return and cancels on Escape.
final class RenamePopover: NSObject, NSTextFieldDelegate, NSPopoverDelegate {
    let popover = NSPopover()
    let field = NSTextField()
    private let commit: (String) -> Void
    private var committed = false

    init(name: String, commit: @escaping (String) -> Void) {
        self.commit = commit
        super.init()
        let label = NSTextField(labelWithString: "Name:")
        field.stringValue = name
        field.delegate = self
        field.lineBreakMode = .byTruncatingMiddle
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 44))
        for view in [label, field] { view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view) }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            label.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            field.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            field.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            field.centerYAnchor.constraint(equalTo: content.centerYAnchor)
        ])
        let controller = NSViewController()
        controller.view = content
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.delegate = self
    }

    func show(relativeTo rect: NSRect, of view: NSView) {
        popover.show(relativeTo: rect, of: view, preferredEdge: .minY)
        field.window?.makeFirstResponder(field)
        // Select the name without its extension, as Finder does.
        let name = field.stringValue as NSString
        let ext = name.pathExtension
        field.currentEditor()?.selectedRange = NSRange(location: 0, length: ext.isEmpty ? name.length : name.length - ext.count - 1)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) { finish(); return true }
        if selector == #selector(NSResponder.cancelOperation(_:)) { committed = true; popover.performClose(nil); return true }
        return false
    }

    /// Clicking elsewhere applies the name, as in macOS's own rename popover.
    func popoverDidClose(_ notification: Notification) { finish() }

    /// Commits the typed name and closes the popover.
    func finish() {
        guard !committed else { return }
        committed = true
        if popover.isShown { popover.performClose(nil) }
        commit(field.stringValue)
    }
}
