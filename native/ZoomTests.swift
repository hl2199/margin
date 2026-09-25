import AppKit
import WebKit

@main struct ZoomTests {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let first = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let second = WKWebView(frame: first.frame, configuration: configuration)
        first.pageZoom = 1.2
        second.pageZoom = 1.2
        var current: WKWebView? = first
        let commands = DocumentZoom { current }
        let menu = NSMenu(title: "View")
        commands.addItems(to: menu)
        let main = NSMenu()
        let entry = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        entry.submenu = menu
        main.addItem(entry)
        app.mainMenu = main
        var checks: [[String: Any]] = []
        func check(_ name: String, _ passed: Bool) {
            checks.append(["name": name, "passed": passed, "firstZoom": first.pageZoom, "secondZoom": second.pageZoom])
            print("\(passed ? "PASS" : "FAIL"): \(name)")
        }
        func key(_ text: String, _ flags: NSEvent.ModifierFlags = [.command], code: UInt16 = 24) -> Bool {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                        windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text,
                                        isARepeat: false, keyCode: code)!
            return menu.performKeyEquivalent(with: event)
        }
        check("Command-equals dispatches to zoom in", key("=") && abs(first.pageZoom - 1.3) < 0.001)
        check("Command-shift-plus dispatches to zoom in", key("+", [.command, .shift]) && abs(first.pageZoom - 1.4) < 0.001)
        check("Command-plus dispatches without shift on plus keyboards", key("+") && abs(first.pageZoom - 1.5) < 0.001)
        check("Command-minus dispatches to zoom out", key("-", code: 27) && abs(first.pageZoom - 1.4) < 0.001)
        check("Plain minus is not intercepted", !key("-", [], code: 27) && abs(first.pageZoom - 1.4) < 0.001)
        check("Other windows keep their own scale", abs(second.pageZoom - 1.2) < 0.001)
        for _ in 0..<30 { _ = key("=") }
        check("Zoom in clamps at 300 percent", abs(first.pageZoom - 3.0) < 0.001)
        check("Zoom in is disabled at upper limit", !commands.validateMenuItem(menu.items[0]))
        check("Command-zero resets to the 120 percent default", key("0", code: 29) && abs(first.pageZoom - 1.2) < 0.001)
        for _ in 0..<30 { _ = key("-", code: 27) }
        check("Zoom out clamps at 50 percent", abs(first.pageZoom - 0.5) < 0.001)
        check("Zoom out is disabled at lower limit", !commands.validateMenuItem(menu.items[2]))
        current = second
        check("Changing current window redirects shortcuts", key("=") && abs(second.pageZoom - 1.3) < 0.001 && abs(first.pageZoom - 0.5) < 0.001)
        check("Only three visible menu items", menu.items.filter { !$0.isHidden }.count == 3)
        current = nil
        menu.update()
        check("Commands disable with no document", menu.items.allSatisfy { !commands.validateMenuItem($0) })
        let passed = checks.allSatisfy { $0["passed"] as? Bool == true }
        let result: [String: Any] = ["passed": passed, "checks": checks,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "testSurface": "Production DocumentZoom, AppKit menu key-equivalent dispatch, real WKWebView instances"]
        if CommandLine.arguments.count > 1 {
            try! JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        }
        print("\(checks.filter { $0["passed"] as? Bool == true }.count)/\(checks.count) zoom checks passed")
        exit(passed ? 0 : 1)
    }
}
