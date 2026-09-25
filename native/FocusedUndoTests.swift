import AppKit
import WebKit
import CryptoKit

@main struct FocusedUndoTests {
    static var runner: FocusedUndoRunner!
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        runner = FocusedUndoRunner()
        Task { @MainActor in await runner.run(); exit(runner.finish() ? 0 : 1) }
        app.run()
    }
}

@MainActor final class FocusedUndoRunner {
    var checks: [[String: Any]] = []
    var observations: [[String: Any]] = []
    let suite = "local.margin.focused-undo.\(UUID().uuidString)"
    var editor: EditorWindow!
    var menu: NSMenu!
    var commandWindow: NSWindow!
    func check(_ name: String, _ passed: Bool) {
        checks.append(["name": name, "passed": passed])
        print("\(passed ? "PASS" : "FAIL"): \(name)"); fflush(stdout)
    }
    func js(_ script: String) async -> Any? {
        await withCheckedContinuation { continuation in
            editor.webView.evaluateJavaScript(script) { value, error in
                if let error { print("JS: \(error)") }
                continuation.resume(returning: value)
            }
        }
    }
    func focus(_ window: NSWindow) async {
        for _ in 0..<20 {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            await settle()
            if NSApp.keyWindow === window { return }
        }
    }
    func settle() async { try? await Task.sleep(nanoseconds: 200_000_000) }
    func text() async -> String {
        let state = await browserState() as? [String: Any] ?? [:]
        observations.append(["phase": "text check", "browser": state])
        return state["text"] as? String ?? "<missing>"
    }
    func command(_ title: String) async {
        await focus(commandWindow)
        let item = menu.item(withTitle: title)!
        observations.append(["command": title, "keyWindow": NSApp.keyWindow?.title ?? "nil",
                             "firstResponder": String(describing: NSApp.keyWindow?.firstResponder),
                             "target": String(describing: NSApp.target(forAction: item.action!, to: item.target, from: item))])
        menu.performActionForItem(at: menu.index(of: item))
        await settle()
    }
    func browserState() async -> Any? {
        await js("({text:window.margin.getText(),activeTag:document.activeElement?.tagName,activeClass:document.activeElement?.className,content:document.querySelector('.cm-content')?.innerHTML,selection:String(window.getSelection())})")
    }
    func run() async {
        let defaults = UserDefaults(suiteName: suite)!
        let app = AppDelegate(showsWindows: true, defaults: defaults, reportError: { print($0) })
        let fixtureRoot = FileManager.default.temporaryDirectory.appendingPathComponent("margin-focused-history-" + UUID().uuidString)
        try! FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        let fixtureURL = fixtureRoot.appendingPathComponent("fixture.md")
        try! Data("Document".utf8).write(to: fixtureURL)
        app.open(fixtureURL)
        app.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        editor = app.editors[0]
        commandWindow = editor.window
        for _ in 0..<100 {
            if await js("window.margin?.getText()") as? String == "Document" { break }
            await settle()
        }
        check("native document fixture finishes loading before editing", await text() == "Document" && editor.file.text == "Document" && editor.file.url == fixtureURL)
        menu = NSApp.mainMenu!.item(withTitle: "Edit")!.submenu!
        await focus(editor.window)
        editor.window.makeFirstResponder(editor.webView)
        await settle()
        check("document window has native keyboard focus", NSApp.keyWindow === editor.window)
        _ = await js("window.margin.command('selectAll'); window.margin.command('bold'); window.inputEvents=[]; document.addEventListener('beforeinput', e => inputEvents.push(e.inputType));")
        check("document edit is ready", await text() == "**Document**")
        await command("Undo")
        check("native Undo reverses document edit", await text() == "Document")
        await command("Redo")
        check("native Redo restores document edit", await text() == "**Document**")
        _ = await js("document.activeElement.blur()")
        await command("Undo")
        check("Undo still works after leaving editor focus for preview", await text() == "Document")
        await command("Redo")
        check("Redo still works in preview", await text() == "**Document**")
        _ = await js("window.margin.command('find'); var input=document.querySelector('.cm-search input'); input.focus(); input.select(); document.execCommand('insertText',false,'needle');")
        await settle()
        check("Find input owns browser focus with query", await js("document.activeElement.value") as? String == "needle")
        let documentBeforeFind = await text()
        await command("Undo")
        let undoQuery = await js("document.querySelector('.cm-search input').value") as? String ?? "missing"
        check("Undo in Find preserves document", await text() == documentBeforeFind)
        check("Undo in Find reverses query entry", undoQuery != "needle")
        await command("Redo")
        check("Redo in Find restores query", await js("document.querySelector('.cm-search input').value") as? String == "needle")
        check("Redo in Find preserves document", await text() == documentBeforeFind)
        observations.append(["browserBeforeinput": await js("window.inputEvents") ?? []])

        let documentBeforeNativeField = await text()
        let nativeWindow = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 300, height: 100), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        nativeWindow.isReleasedWhenClosed = false
        nativeWindow.title = "Native text field fixture"
        commandWindow = nativeWindow
        let field = NSTextField(frame: NSRect(x: 10, y: 30, width: 280, height: 25))
        nativeWindow.contentView!.addSubview(field)
        await focus(nativeWindow)
        field.selectText(nil)
        await settle()
        check("native field window has keyboard focus", NSApp.keyWindow === nativeWindow)
        if let fieldEditor = field.currentEditor() as? NSTextView {
            fieldEditor.allowsUndo = true
            fieldEditor.insertText("filename", replacementRange: NSRange(location: NSNotFound, length: 0))
            await settle()
            check("native filename field has text and undo history", fieldEditor.string == "filename" && fieldEditor.undoManager?.canUndo == true)
            await command("Undo")
            check("native field Undo changes field text", fieldEditor.string.isEmpty)
            check("native field Undo preserves document", await text() == documentBeforeNativeField)
            await command("Redo")
            check("native field Redo restores field text", fieldEditor.string == "filename")
            check("native field Redo preserves document", await text() == documentBeforeNativeField)
        } else { check("native field editor exists", false) }
        nativeWindow.close()
        editor.closeWithoutPrompt()
        defaults.removePersistentDomain(forName: suite)
        try! FileManager.default.removeItem(at: fixtureRoot)
    }
    func finish() -> Bool {
        let success = checks.allSatisfy { $0["passed"] as? Bool == true }
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        let payload: [String: Any] = ["passed": success, "checks": checks, "observations": observations,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "scope": "Production native Edit menu dispatch with real WKWebView Find input and native NSTextField; isolated test bundle"]
        try! JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]).write(to: output)
        return success
    }
}
