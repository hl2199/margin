import AppKit
import WebKit
import UniformTypeIdentifiers

func json(_ value: Any) -> String {
    String(data: try! JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), encoding: .utf8)!
}

final class SettingsWindow: NSWindowController {
    private let defaults: UserDefaults
    let preferTabs = NSButton(checkboxWithTitle: "Prefer tabs", target: nil, action: nil)

    init(defaults: UserDefaults) {
        self.defaults = defaults
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 150),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Settings"
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.center()
        preferTabs.state = defaults.bool(forKey: "preferTabs") ? .on : .off
        preferTabs.target = self
        preferTabs.action = #selector(changePreference(_:))
        let description = NSTextField(wrappingLabelWithString: "Open additional documents in tabs instead of new windows.")
        description.textColor = .secondaryLabelColor
        description.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let content = window.contentView!
        for view in [preferTabs, description] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            preferTabs.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            preferTabs.topAnchor.constraint(equalTo: content.topAnchor, constant: 28),
            description.leadingAnchor.constraint(equalTo: preferTabs.leadingAnchor, constant: 20),
            description.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            description.topAnchor.constraint(equalTo: preferTabs.bottomAnchor, constant: 8)
        ])
    }

    required init?(coder: NSCoder) { fatalError("SettingsWindow is created programmatically") }

    @objc private func changePreference(_ sender: NSButton) {
        defaults.set(sender.state == .on, forKey: "preferTabs")
    }
}

/// Dropping Markdown files onto a document opens them; other drops reach the editor.
final class DocumentWebView: WKWebView {
    var openFiles: ([URL]) -> Void = { _ in }
    private var handlingDrop = false

    private func documents(_ info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return !urls.isEmpty && urls.allSatisfy({ MarkdownFile.documentExtensions.contains($0.pathExtension.lowercased()) }) ? urls : []
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        handlingDrop = !documents(sender).isEmpty
        return handlingDrop ? .copy : super.draggingEntered(sender)
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        handlingDrop ? .copy : super.draggingUpdated(sender)
    }
    override func draggingExited(_ sender: NSDraggingInfo?) {
        if handlingDrop { handlingDrop = false } else { super.draggingExited(sender) }
    }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        handlingDrop || super.prepareForDragOperation(sender)
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard handlingDrop else { return super.performDragOperation(sender) }
        openFiles(documents(sender))
        return true
    }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        if handlingDrop { handlingDrop = false } else { super.concludeDragOperation(sender) }
    }
}

final class EditorWindow: NSObject, NSWindowDelegate, WKScriptMessageHandler, WKNavigationDelegate {
    let window: NSWindow
    let webView: DocumentWebView
    private(set) var file: MarkdownFile
    private let assetHandler: DocumentAssetHandler
    private var documentID = UUID().uuidString
    private(set) var isStartupPlaceholder: Bool
    weak var app: AppDelegate?
    private var ready = false
    private var permittedClose = false
    private var closing = false
    private var saving = false
    private var autosaveTimer: Timer?
    /// Set when the user declines to overwrite a conflicting disk version.
    private var autosavePaused = false
    private var watcher: DispatchSourceFileSystemObject?
    private var promptedDiskBytes: Data?

    /// Markdown is source text: WebKit must not turn `--` into dashes, straight
    /// quotes into curly ones, or autocorrect words. WebKit reads these once per
    /// process, so they are set before the first web view exists.
    static let plainTextInput: Void = {
        for key in ["WebAutomaticQuoteSubstitutionEnabled", "WebAutomaticDashSubstitutionEnabled",
                    "WebAutomaticTextReplacementEnabled", "WebAutomaticSpellingCorrectionEnabled"] {
            UserDefaults.standard.set(false, forKey: key)
        }
    }()

    init(file: MarkdownFile, app: AppDelegate, startupPlaceholder: Bool = false, zoom: CGFloat = DocumentZoom.defaultZoom) {
        _ = EditorWindow.plainTextInput
        self.file = file
        self.assetHandler = DocumentAssetHandler(file: file)
        self.isStartupPlaceholder = startupPlaceholder
        self.app = app
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(assetHandler, forURLScheme: "margin-asset")
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = DocumentWebView(frame: .zero, configuration: configuration)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 780),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        super.init()
        configuration.userContentController.add(self, name: "margin")
        window.delegate = self
        window.minSize = NSSize(width: 540, height: 420)
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        // Leave native traffic lights and the title in their own 28-point row.
        let container = NSView()
        window.contentView = container
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            webView.topAnchor.constraint(equalTo: (window.contentLayoutGuide as! NSLayoutGuide).topAnchor)
        ])
        webView.navigationDelegate = self
        webView.openFiles = { [weak app] urls in urls.forEach { app?.open($0) } }
        webView.pageZoom = zoom
        webView.setValue(false, forKey: "drawsBackground")
        if #available(macOS 13.3, *) { webView.isInspectable = true }
        window.center()
        window.setFrameAutosaveName("MarginEditor")
        updateInfo()
        if let resources = Bundle.main.resourceURL {
            let web = resources.appendingPathComponent("web")
            webView.loadFileURL(web.appendingPathComponent("index.html"), allowingReadAccessTo: web)
        }
        watchFile()
    }

    func show() {
        window.tabGroup?.selectedWindow = window
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    /// Only the untouched, automatically created window may be consumed by Open.
    func replaceStartupDocument(with replacement: MarkdownFile, completion: @escaping (Bool) -> Void) {
        guard isStartupPlaceholder, file.url == nil, !file.isDirty, !closing, !saving,
              window.attachedSheet == nil else { completion(false); return }
        let replace: (Bool) -> Void = { [weak self] success in
            guard let self, success, self.isStartupPlaceholder, self.file.url == nil,
                  !self.file.isDirty else { completion(false); return }
            self.isStartupPlaceholder = false
            self.file = replacement
            self.assetHandler.file = replacement
            self.documentID = UUID().uuidString
            self.updateInfo(notifyWeb: false)
            self.watchFile()
            if self.ready { self.loadDocument() }
            completion(true)
        }
        // A page that has not announced readiness cannot contain user edits yet.
        if ready { snapshot(replace) } else { replace(true) }
    }

    private func loadDocument() {
        var payload = info
        payload["text"] = file.text
        webView.evaluateJavaScript("window.margin.loadDocument(\(json(payload)))") { [weak self] _, error in
            if let error { self?.present(error) }
        }
        applyPanels()
    }

    func applyPanels() {
        guard ready, let panels = app?.panels else { return }
        webView.evaluateJavaScript("window.margin.setPanels(\(json(panels)))", completionHandler: nil)
    }

    func updateInfo(notifyWeb: Bool = true) {
        window.title = file.name
        window.representedURL = file.url
        window.isDocumentEdited = file.isDirty
        guard ready, notifyWeb else { return }
        webView.evaluateJavaScript("window.margin.setDocumentInfo(\(json(info)))", completionHandler: nil)
    }

    private var info: [String: Any] {
        ["name": file.name, "path": file.url?.path ?? "", "dirty": file.isDirty, "documentID": documentID]
    }

    func command(_ name: String) {
        guard ready else { return }
        webView.evaluateJavaScript("window.margin.command(\(json(name)))", completionHandler: nil)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        guard type == "ready" || body["documentID"] as? String == documentID else { return }
        switch type {
        case "ready":
            ready = true
            loadDocument()
        case "change":
            if let text = body["text"] as? String {
                if text != file.savedText { isStartupPlaceholder = false }
                file.text = text
                updateInfo()
                scheduleAutosave()
            }
        case "save": save()
        case "saveAs": save(asNew: true)
        case "new": app?.newDocument(nil)
        case "open": app?.openDocument(nil)
        case "openLink":
            guard let raw = body["url"] as? String else { break }
            if let url = URL(string: raw), let scheme = url.scheme?.lowercased(), scheme != "file" {
                if ["https", "http", "mailto"].contains(scheme) { NSWorkspace.shared.open(url) }
            } else if let target = localLink(raw) {
                // Linked documents open in Margin; other files are only revealed, never launched.
                if MarkdownFile.documentExtensions.contains(target.pathExtension.lowercased()) { app?.open(target) }
                else { NSWorkspace.shared.activateFileViewerSelecting([target]) }
            }
        default: break
        }
    }

    /// Resolves a relative or file: link against this document's folder.
    private func localLink(_ raw: String) -> URL? {
        var path = String(raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0])
        path = String(path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0])
        if path.lowercased().hasPrefix("file://") { path = URL(string: path)?.path ?? "" }
        else { path = path.removingPercentEncoding ?? path }
        guard !path.isEmpty, let directory = file.url?.deletingLastPathComponent() else { return nil }
        let target = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : directory.appendingPathComponent(path)).standardizedFileURL
        guard (try? target.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
        return target
    }

    // MARK: Autosave

    /// Documents that already have a file save themselves shortly after edits pause.
    private func scheduleAutosave() {
        autosaveTimer?.invalidate()
        autosaveTimer = nil
        guard file.url != nil, file.isDirty, !autosavePaused else { return }
        autosaveTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in self?.autosave() }
    }

    func autosave() {
        autosaveTimer?.invalidate()
        autosaveTimer = nil
        guard file.url != nil, file.isDirty, !autosavePaused, !saving, !closing, window.attachedSheet == nil else { return }
        save { [weak self] saved in
            // Edits typed while writing are picked up by another pass.
            if saved, let self, self.file.isDirty { self.scheduleAutosave() }
        }
    }

    private func flushAutosave() { if autosaveTimer != nil { autosave() } }

    // MARK: Disk changes

    private func watchFile() {
        watcher?.cancel()
        watcher = nil
        guard let url = file.url else { return }
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .extend, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            if source.data.contains(.delete) || source.data.contains(.rename) {
                // Atomic saves replace the file; follow the path to its new node.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    guard let self, self.watcher === source else { return }
                    self.watchFile()
                    self.checkDisk()
                }
            } else { self.checkDisk() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watcher = source
    }

    /// Show another app's changes. Unsaved edits are never replaced without asking.
    func checkDisk() {
        guard ready, !saving, !closing, window.attachedSheet == nil, let url = file.url,
              file.changedOnDisk(), let disk = try? Data(contentsOf: url) else { return }
        snapshot { [weak self] success in
            guard let self, success, self.file.url == url, !self.saving, self.window.attachedSheet == nil else { return }
            if !self.file.isDirty { self.adoptDiskVersion(); return }
            guard disk != self.promptedDiskBytes else { return }
            self.promptedDiskBytes = disk
            let alert = NSAlert()
            alert.messageText = "“\(self.file.name)” changed on disk."
            alert.informativeText = "Another app changed this file while you had unsaved edits."
            alert.addButton(withTitle: "Keep My Version")
            alert.addButton(withTitle: "Use Disk Version")
            alert.beginSheetModal(for: self.window) { response in
                if response == .alertSecondButtonReturn { self.adoptDiskVersion(); return }
                self.write(to: url, replacingExternalChanges: true) { _ in }
            }
        }
    }

    private func adoptDiskVersion() {
        guard let url = file.url, let fresh = try? MarkdownFile(contentsOf: url) else { return }
        autosaveTimer?.invalidate()
        autosaveTimer = nil
        file = fresh
        assetHandler.file = fresh
        autosavePaused = false
        promptedDiskBytes = nil
        updateInfo(notifyWeb: false)
        var payload = info
        payload["text"] = fresh.text
        webView.evaluateJavaScript("window.margin.reloadDocument(\(json(payload)))", completionHandler: nil)
    }

    /// Snapshot the actual editor before destructive actions; bridge events alone
    /// may still be queued behind a keyboard-triggered Save or Close.
    private func snapshot(_ completion: @escaping (Bool) -> Void) {
        guard ready else {
            present(NSError(domain: "Margin", code: 1, userInfo: [NSLocalizedDescriptionKey: "The editor is still loading. Please try again in a moment."]))
            completion(false)
            return
        }
        webView.evaluateJavaScript("window.margin.getText()") { [weak self] value, error in
            guard let self else { completion(false); return }
            guard error == nil, let text = value as? String else {
                self.present(error ?? NSError(domain: "Margin", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not read the editor. Your window has been kept open."]))
                completion(false)
                return
            }
            if text != self.file.savedText { self.isStartupPlaceholder = false }
            self.file.text = text
            self.updateInfo()
            completion(true)
        }
    }

    func save(asNew: Bool = false, completion: @escaping (Bool) -> Void = { _ in }) {
        guard !saving else { completion(false); return }
        saving = true
        snapshot { [weak self] success in
            guard let self else { completion(false); return }
            guard success else { self.saving = false; completion(false); return }
            let finish: (Bool) -> Void = { [weak self] result in self?.saving = false; completion(result) }
            if asNew || self.file.url == nil {
                self.chooseDestination(completion: finish)
            } else {
                self.write(to: self.file.url!, completion: finish)
            }
        }
    }

    private func chooseDestination(completion: @escaping (Bool) -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.name
        panel.directoryURL = file.url?.deletingLastPathComponent()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { completion(false); return }
            self.write(to: url, completion: completion)
        }
    }

    private func write(to url: URL, replacingExternalChanges: Bool = false, completion: @escaping (Bool) -> Void) {
        // Take a second snapshot after a panel so edits preceding the sheet have
        // settled, and so savedText always refers to exactly the written text.
        snapshot { [weak self] success in
            guard let self, success else { completion(false); return }
            do {
                let previousURL = self.file.url
                try self.file.save(to: url, text: self.file.text, replacingExternalChanges: replacingExternalChanges)
                self.isStartupPlaceholder = false
                self.autosavePaused = false
                self.promptedDiskBytes = nil
                if previousURL != self.file.url { self.watchFile() }
                NSDocumentController.shared.noteNewRecentDocumentURL(url)
                self.updateInfo()
                completion(true)
            } catch MarkdownFile.FileError.changedOnDisk {
                let alert = NSAlert()
                alert.messageText = "“\(self.file.name)” changed on disk."
                alert.informativeText = "Another app changed or removed this file. Save a copy to keep both versions, or explicitly replace the disk version with your edits."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Save a Copy…")
                alert.addButton(withTitle: "Cancel")
                alert.addButton(withTitle: "Replace Disk Version")
                alert.beginSheetModal(for: self.window) { response in
                    switch response {
                    case .alertFirstButtonReturn: self.chooseDestination(completion: completion)
                    case .alertThirdButtonReturn: self.write(to: url, replacingExternalChanges: true, completion: completion)
                    default: self.autosavePaused = true; completion(false)
                    }
                }
            } catch { self.present(error); completion(false) }
        }
    }

    func requestClose(completion: @escaping (Bool) -> Void) {
        guard !closing, !saving else { completion(false); return }
        // A failed first page load cannot contain edits. Still permit that empty
        // window to close; a crashed editor with retained edits stays protected.
        if !ready && !file.isDirty { completion(true); return }
        closing = true
        snapshot { [weak self] success in
            guard let self else { completion(false); return }
            guard success else { self.closing = false; completion(false); return }
            if !self.file.isDirty { self.closing = false; completion(true); return }
            // Files that already exist are autosaved; only untitled drafts ask.
            if self.file.url != nil, !self.autosavePaused {
                self.closing = false
                self.save { saved in completion(saved && !self.file.isDirty) }
                return
            }
            let alert = NSAlert()
            alert.messageText = "Save changes to “\(self.file.name)”?"
            alert.informativeText = "Your changes will be lost if you don’t save them."
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Don’t Save")
            alert.beginSheetModal(for: self.window) { response in
                self.closing = false
                switch response {
                case .alertFirstButtonReturn:
                    self.save { saved in completion(saved && !self.file.isDirty) }
                case .alertThirdButtonReturn: completion(true)
                default: completion(false)
                }
            }
        }
    }

    func closeWithoutPrompt() { permittedClose = true; window.close() }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if permittedClose { return true }
        requestClose { [weak self] allowed in if allowed { self?.closeWithoutPrompt() } }
        return false
    }
    func windowDidBecomeKey(_ notification: Notification) { checkDisk() }
    func windowDidResignKey(_ notification: Notification) { flushAutosave() }
    func windowWillClose(_ notification: Notification) {
        autosaveTimer?.invalidate()
        watcher?.cancel()
        watcher = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "margin")
        app?.editors.removeAll { $0 === self }
    }

    private func present(_ error: Error) { NSAlert(error: error).beginSheetModal(for: window) }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Only the bundled entry document can replace the editor. User links are
        // delegated to the system browser; arbitrary document scripts never load.
        if let url = navigationAction.request.url, url.isFileURL,
           url.standardizedFileURL.path == Bundle.main.resourceURL?.appendingPathComponent("web/index.html").standardizedFileURL.path {
            decisionHandler(.allow)
        } else {
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url,
               ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) }
            decisionHandler(.cancel)
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        ready = false
        // Native retains the last bridge snapshot. Reloading preserves it instead
        // of silently replacing it with the original disk document.
        webView.reload()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    var editors: [EditorWindow] = []
    private let showsWindows: Bool
    private let reportError: (Error) -> Void
    private let instanceRouter: SingleInstanceRouter?
    private let defaults: UserDefaults
    private(set) lazy var settings = SettingsWindow(defaults: defaults)
    private var finishedLaunching = false
    private var forwardingLaunch = false
    private var launchURLs: [URL] = []
    private var opening = false
    private var pendingOpenURLs: [URL] = []
    private let recentMenu = NSMenu(title: "Open Recent")
    private lazy var documentZoom = DocumentZoom(currentWebView: { [weak self] in self?.current?.webView },
                                                 changed: { [weak self] zoom in self?.defaults.set(Double(zoom), forKey: "zoom") })
    /// New windows open at the most recently chosen zoom.
    private var zoom: CGFloat {
        let saved = defaults.double(forKey: "zoom")
        return saved >= 0.5 && saved <= 3 ? CGFloat(saved) : DocumentZoom.defaultZoom
    }
    var panels: [String: Bool] {
        ["outline": defaults.bool(forKey: "showOutline"), "wordCount": defaults.bool(forKey: "showWordCount")]
    }
    private var quitting = false
    var current: EditorWindow? {
        editors.first { $0.window === NSApp.keyWindow }
            ?? editors.first { $0.window === NSApp.mainWindow }
            ?? NSApp.orderedWindows.compactMap { window in editors.first { $0.window === window } }.first
            ?? editors.last
    }

    init(instanceRouter: SingleInstanceRouter? = nil, showsWindows: Bool = true, defaults: UserDefaults = .standard,
         reportError: @escaping (Error) -> Void = { NSAlert(error: $0).runModal() }) {
        self.instanceRouter = instanceRouter
        self.showsWindows = showsWindows
        self.defaults = defaults
        self.reportError = reportError
        super.init()
        // Group explicitly so the in-app preference wins over the system setting.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        finishedLaunching = true
        if instanceRouter?.isPrimary == false { forwardLaunch(); return }
        buildMenus()
        if editors.isEmpty {
            add(MarkdownFile(), startupPlaceholder: true)
        }
        if showsWindows { NSApp.activate(ignoringOtherApps: true) }
    }

    private func add(_ file: MarkdownFile, startupPlaceholder: Bool = false) {
        let previous = current
        let tabHost = defaults.bool(forKey: "preferTabs") ? previous : nil
        let editor = EditorWindow(file: file, app: self, startupPlaceholder: startupPlaceholder, zoom: zoom)
        editor.window.tabbingIdentifier = "MarginDocument"
        editor.window.tabbingMode = defaults.bool(forKey: "preferTabs") ? .preferred : .disallowed
        editors.append(editor)
        if let tabHost {
            tabHost.window.tabbingMode = .preferred
            tabHost.window.addTabbedWindow(editor.window, ordered: .above)
            editor.window.tabGroup?.selectedWindow = editor.window
        } else if let previous, previous.window.isVisible {
            // Offset from the current window instead of covering it exactly. A
            // window already filling the screen shrinks rather than snapping back.
            var frame = previous.window.frame.offsetBy(dx: 24, dy: -24)
            if let visible = (previous.window.screen ?? NSScreen.main)?.visibleFrame {
                let minimum = editor.window.minSize
                if frame.minY < visible.minY {
                    let top = frame.maxY
                    frame.size.height = max(minimum.height, top - visible.minY)
                    frame.origin.y = top - frame.height
                }
                if frame.maxX > visible.maxX { frame.size.width = max(minimum.width, visible.maxX - frame.minX) }
            }
            // Only the first window restores and records the saved frame.
            editor.window.setFrameAutosaveName("")
            editor.window.setFrame(frame, display: false)
        }
        if showsWindows { editor.show() }
    }

    @objc func showSettings(_ sender: Any?) { settings.showWindow(sender) }
    @objc func toggleOutline(_ sender: Any?) { togglePanel("showOutline") }
    @objc func toggleWordCount(_ sender: Any?) { togglePanel("showWordCount") }
    private func togglePanel(_ key: String) {
        defaults.set(!defaults.bool(forKey: key), forKey: key)
        editors.forEach { $0.applyPanels() }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleOutline(_:)) {
            menuItem.title = defaults.bool(forKey: "showOutline") ? "Hide Outline" : "Show Outline"
        } else if menuItem.action == #selector(toggleWordCount(_:)) {
            menuItem.title = defaults.bool(forKey: "showWordCount") ? "Hide Word Count" : "Show Word Count"
        }
        return true
    }
    @objc func newWindowForTab(_ sender: Any?) { newDocument(sender) }
    @objc func newDocument(_ sender: Any?) { add(MarkdownFile()) }
    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.plainText, .text, UTType(filenameExtension: "md") ?? .plainText]
        panel.allowsOtherFileTypes = true
        panel.begin { [weak self] response in
            if response == .OK { panel.urls.forEach { self?.open($0) } }
        }
    }
    func open(_ url: URL) {
        pendingOpenURLs.append(url)
        openNextDocument()
    }

    @objc private func openRecentDocument(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { open(url) }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === recentMenu else { return }
        menu.removeAllItems()
        let controller = NSDocumentController.shared
        let urls = controller.recentDocumentURLs
        if urls.isEmpty {
            let empty = NSMenuItem(title: "No Recent Documents", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for url in urls {
            let entry = NSMenuItem(title: url.lastPathComponent, action: #selector(openRecentDocument(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = url
            entry.toolTip = url.path
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        let clear = NSMenuItem(title: "Clear Menu", action: #selector(NSDocumentController.clearRecentDocuments(_:)), keyEquivalent: "")
        clear.target = controller
        menu.addItem(clear)
    }

    private func openNextDocument() {
        guard !opening, !pendingOpenURLs.isEmpty else { return }
        opening = true
        let url = pendingOpenURLs.removeFirst()
        let finished: () -> Void = { [weak self] in
            self?.opening = false
            self?.openNextDocument()
        }
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL
        if let existing = editors.first(where: { $0.file.url == canonical }) {
            if showsWindows { existing.show() }
            finished()
            return
        }
        do {
            let openedFile = try MarkdownFile(contentsOf: canonical)
            let complete: () -> Void = {
                NSDocumentController.shared.noteNewRecentDocumentURL(canonical)
                finished()
            }
            if let placeholder = editors.first(where: { $0.isStartupPlaceholder }) {
                placeholder.replaceStartupDocument(with: openedFile) { [weak self] reused in
                    guard let self else { return }
                    if !reused { self.add(openedFile) }
                    else if self.showsWindows { placeholder.show() }
                    complete()
                }
            } else {
                add(openedFile)
                complete()
            }
        } catch { reportError(error); finished() }
    }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        if instanceRouter?.isPrimary == false {
            launchURLs.append(contentsOf: filenames.map { URL(fileURLWithPath: $0) })
            if finishedLaunching { forwardLaunch() }
            return
        }
        filenames.forEach { open(URL(fileURLWithPath: $0)) }
        sender.reply(toOpenOrPrint: .success)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if instanceRouter?.isPrimary == false { forwardLaunch(); return false }
        if editors.isEmpty { add(MarkdownFile(), startupPlaceholder: true) }
        else if !flag, showsWindows { current?.window.deminiaturize(nil); current?.show() }
        return true
    }

    private func forwardLaunch() {
        guard !forwardingLaunch, let router = instanceRouter else { return }
        forwardingLaunch = true
        // Initial file-open events can precede didFinishLaunching; collect the
        // launch batch before asking the existing process to open the documents.
        DispatchQueue.main.async { [self] in
            let urls = launchURLs
            launchURLs.removeAll()
            router.forward(urls: urls) { [self] result in
                switch result {
                case .success:
                    NSApp.reply(toOpenOrPrint: .success)
                    if launchURLs.isEmpty { exit(0) }
                    forwardingLaunch = false
                    forwardLaunch()
                case .failure(let error):
                    reportError(error)
                    NSApp.reply(toOpenOrPrint: .failure)
                    exit(1)
                }
            }
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !quitting else { return .terminateCancel }
        quitting = true
        DispatchQueue.main.async { self.confirmQuit(Array(self.editors)) }
        return .terminateLater
    }
    private func confirmQuit(_ remaining: [EditorWindow]) {
        guard let editor = remaining.first else { NSApp.reply(toApplicationShouldTerminate: true); return }
        editor.show()
        editor.requestClose { [weak self] allowed in
            guard let self else { return }
            if allowed {
                editor.closeWithoutPrompt()
                self.confirmQuit(Array(remaining.dropFirst()))
            } else { self.quitting = false; NSApp.reply(toApplicationShouldTerminate: false) }
        }
    }

    @objc func undoFocused(_ sender: Any?) { history("undo", sender: sender) }
    @objc func redoFocused(_ sender: Any?) { history("redo", sender: sender) }

    private func history(_ command: String, sender: Any?) {
        let action = NSSelectorFromString(command + ":")
        guard let editor = editors.first(where: { $0.window === NSApp.keyWindow }),
              let responder = editor.window.firstResponder as? NSView,
              responder === editor.webView || responder.isDescendant(of: editor.webView) else {
            NSApp.sendAction(action, to: nil, from: sender)
            return
        }
        // CodeMirror owns its history; native/browser text fields own theirs.
        // Native WebKit undo alone cannot undo a CodeMirror transaction.
        let script = "(() => { const active = document.activeElement; if (active?.closest('input, textarea, .cm-search, [contenteditable=\"true\"]') && !active.closest('.cm-content')) return false; window.margin.command(\(json(command))); return true; })()"
        editor.webView.evaluateJavaScript(script) { handled, error in
            guard error == nil, handled as? Bool == false,
                  NSApp.keyWindow === editor.window,
                  editor.window.firstResponder === responder else { return }
            NSApp.sendAction(action, to: nil, from: sender)
        }
    }

    @objc func saveDocument(_ sender: Any?) { current?.save() }
    @objc func saveDocumentAs(_ sender: Any?) { current?.save(asNew: true) }
    @objc func editorCommand(_ sender: NSMenuItem) { if let name = sender.representedObject as? String { current?.command(name) } }

    private func buildMenus() {
        let main = NSMenu()
        NSApp.mainMenu = main
        func menu(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let child = NSMenu(title: title)
            item.submenu = child
            main.addItem(item)
            return child
        }
        func item(_ menu: NSMenu, _ title: String, _ selector: Selector?, _ key: String = "", _ flags: NSEvent.ModifierFlags = [.command], target: AnyObject? = nil) {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
            item.keyEquivalentModifierMask = flags
            item.target = target
            menu.addItem(item)
        }
        func command(_ menu: NSMenu, _ title: String, _ name: String, _ key: String, _ flags: NSEvent.ModifierFlags = [.command]) {
            let entry = NSMenuItem(title: title, action: #selector(editorCommand(_:)), keyEquivalent: key)
            entry.target = self
            entry.representedObject = name
            entry.keyEquivalentModifierMask = flags
            menu.addItem(entry)
        }
        let app = menu("Margin")
        item(app, "About Margin", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        item(app, "Settings…", #selector(showSettings(_:)), ",", target: self)
        app.addItem(.separator())
        item(app, "Hide Margin", #selector(NSApplication.hide(_:)), "h")
        item(app, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        item(app, "Show All", #selector(NSApplication.unhideAllApplications(_:)))
        app.addItem(.separator())
        item(app, "Quit Margin", #selector(NSApplication.terminate(_:)), "q")
        let file = menu("File")
        item(file, "New", #selector(newDocument(_:)), "n", target: self)
        item(file, "Open…", #selector(openDocument(_:)), "o", target: self)
        let recent = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        recent.submenu = recentMenu
        recentMenu.delegate = self
        menuNeedsUpdate(recentMenu)
        file.addItem(recent)
        file.addItem(.separator())
        item(file, "Close", #selector(NSWindow.performClose(_:)), "w")
        item(file, "Save", #selector(saveDocument(_:)), "s", target: self)
        item(file, "Save As…", #selector(saveDocumentAs(_:)), "s", [.command, .shift], target: self)
        let edit = menu("Edit")
        item(edit, "Undo", #selector(undoFocused(_:)), "z", target: self)
        item(edit, "Redo", #selector(redoFocused(_:)), "z", [.command, .shift], target: self)
        edit.addItem(.separator())
        item(edit, "Cut", #selector(NSText.cut(_:)), "x")
        item(edit, "Copy", #selector(NSText.copy(_:)), "c")
        item(edit, "Paste", #selector(NSText.paste(_:)), "v")
        item(edit, "Select All", #selector(NSText.selectAll(_:)), "a")
        edit.addItem(.separator())
        command(edit, "Find…", "find", "f")
        let view = menu("View")
        item(view, "Show Outline", #selector(toggleOutline(_:)), "s", [.command, .control], target: self)
        item(view, "Show Word Count", #selector(toggleWordCount(_:)), "", target: self)
        view.addItem(.separator())
        documentZoom.addItems(to: view)
        view.addItem(.separator())
        item(view, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])
        let window = menu("Window")
        item(window, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        item(window, "Zoom", #selector(NSWindow.performZoom(_:)))
        NSApp.windowsMenu = window
    }
}
