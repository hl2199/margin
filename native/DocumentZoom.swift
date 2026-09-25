import AppKit
import WebKit

/// Native menu commands affect only the current document's rendering scale.
final class DocumentZoom: NSObject, NSMenuItemValidation {
    /// MDV's reading scale. Actual Size returns here rather than to 100%.
    static let defaultZoom: CGFloat = 1.2
    private let currentWebView: () -> WKWebView?
    private let changed: (CGFloat) -> Void

    init(currentWebView: @escaping () -> WKWebView?, changed: @escaping (CGFloat) -> Void = { _ in }) {
        self.currentWebView = currentWebView
        self.changed = changed
    }

    func addItems(to menu: NSMenu) {
        func add(_ title: String, _ key: String, _ action: Selector, hidden: Bool = false) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = [.command]
            item.target = self
            item.isHidden = hidden
            item.allowsKeyEquivalentWhenHidden = hidden
            menu.addItem(item)
        }
        add("Zoom In", "+", #selector(zoomIn(_:)))
        // The unshifted equals key is the usual Mac shortcut on US keyboards.
        add("Zoom In", "=", #selector(zoomIn(_:)), hidden: true)
        add("Zoom Out", "-", #selector(zoomOut(_:)))
        add("Actual Size", "0", #selector(actualSize(_:)))
    }

    @objc private func zoomIn(_ sender: Any?) { change(by: 1) }
    @objc private func zoomOut(_ sender: Any?) { change(by: -1) }
    @objc private func actualSize(_ sender: Any?) { set(Self.defaultZoom) }

    private func change(by steps: Int) {
        guard let view = currentWebView() else { return }
        let percent = (view.pageZoom * 100).rounded() + Double(steps * 10)
        set(min(300, max(50, percent)) / 100)
    }

    private func set(_ zoom: CGFloat) {
        guard let view = currentWebView() else { return }
        view.pageZoom = zoom
        changed(zoom)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let view = currentWebView() else { return false }
        if menuItem.action == #selector(zoomIn(_:)) { return view.pageZoom < 3.0 }
        if menuItem.action == #selector(zoomOut(_:)) { return view.pageZoom > 0.5 }
        return true
    }
}
