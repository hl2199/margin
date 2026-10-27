import AppKit
import WebKit
import PDFKit

@main struct LifecycleTests {
    static var runner: LifecycleRunner!
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        runner = LifecycleRunner()
        Task { @MainActor in await runner.run(); exit(runner.finish() ? 0 : 1) }
        app.run()
    }
}

@MainActor final class LifecycleRunner {
    var results: [[String: Any]] = []
    var errors: [String] = []
    let settingsSuite = "local.margin.tab-tests.\(UUID().uuidString)"
    lazy var defaults = UserDefaults(suiteName: settingsSuite)!
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("margin-lifecycle-\(UUID().uuidString)")
    func check(_ name: String, _ passed: Bool) {
        results.append(["name": name, "passed": passed])
        print("\(passed ? "PASS" : "FAIL"): \(name)")
        fflush(stdout)
    }
    func controller(showsWindows: Bool = false) -> AppDelegate { AppDelegate(showsWindows: showsWindows, defaults: defaults, reportError: { self.errors.append($0.localizedDescription) }) }
    func launch(_ controller: AppDelegate) { controller.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification)) }
    func close(_ controller: AppDelegate) { for editor in Array(controller.editors) { editor.closeWithoutPrompt() } }
    func js(_ editor: EditorWindow, _ script: String) async -> Any? {
        await withCheckedContinuation { continuation in
            editor.webView.evaluateJavaScript(script) { value, _ in continuation.resume(returning: value) }
        }
    }
    func wait(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<150 {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }
    func ready(_ editor: EditorWindow, text: String) async -> Bool {
        await wait { await self.js(editor, "window.margin?.getText()") as? String == text }
    }
    func represents(_ item: NSMenuItem, _ url: URL) -> Bool {
        (item.representedObject as? URL)?.resolvingSymlinksInPath().standardizedFileURL == url.resolvingSymlinksInPath().standardizedFileURL
    }
    func run() async {
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let first = root.appendingPathComponent("first.md")
        let second = root.appendingPathComponent("second.md")
        try! Data("# First\n\nDocument one.\n".utf8).write(to: first)
        try! Data("# Second\n\nDocument two.\n".utf8).write(to: second)
        let app = controller()
        launch(app)
        let fileMenu = NSApp.mainMenu!.item(withTitle: "File")!.submenu!
        let recent = fileMenu.item(withTitle: "Open Recent")!.submenu!
        check("Open Recent sits immediately after Open", fileMenu.items.map(\.title).prefix(3) == ["New", "Open…", "Open Recent"])
        // This test app has its own bundle identity and recent-document list.
        recent.performActionForItem(at: recent.indexOfItem(withTitle: "Clear Menu"))
        app.menuNeedsUpdate(recent)
        check("cleared recent menu shows disabled empty state", recent.item(at: 0)?.title == "No Recent Documents" && recent.item(at: 0)?.isEnabled == false && NSDocumentController.shared.recentDocumentURLs.isEmpty)
        NSDocumentController.shared.noteNewRecentDocumentURL(first)
        _ = await wait { !NSDocumentController.shared.recentDocumentURLs.isEmpty }
        app.menuNeedsUpdate(recent)
        check("recent menu uses native document history", represents(recent.item(at: 0)!, first) && recent.item(at: 0)?.toolTip == (recent.item(at: 0)?.representedObject as? URL)?.path)
        check("plain launch creates one empty startup window", app.editors.count == 1 && app.editors[0].file.text.isEmpty && app.editors[0].isStartupPlaceholder)
        let initial = app.editors[0]
        check("startup editor bridge loads", await ready(initial, text: ""))
        let initialWindow = initial.window
        recent.performActionForItem(at: 0)
        check("first open reuses exact startup window and loads file", await wait { app.editors.count == 1 && app.editors[0].window === initialWindow && app.editors[0].file.url == first })
        check("reused WebKit editor contains first file", await ready(initial, text: "# First\n\nDocument one.\n"))
        check("reused window title and file identity update", initial.window.title == "first.md" && initial.window.representedURL == first && !initial.window.isDocumentEdited && !initial.isStartupPlaceholder)
        _ = await js(initial, "window.webkit.messageHandlers.margin.postMessage({type:'change',documentID:'old-document',text:'stale edit'}); void 0")
        _ = await js(initial, "window.margin.getText()")
        check("stale document messages cannot overwrite replacement", initial.file.text == "# First\n\nDocument one.\n" && !initial.file.isDirty)
        app.open(second)
        check("subsequent file opens a second window", await wait { app.editors.count == 2 && app.editors[0] === initial && app.editors[1].file.url == second })
        app.menuNeedsUpdate(recent)
        check("newly opened file appears in recent menu", recent.items.contains { represents($0, second) })
        if let index = recent.items.firstIndex(where: { represents($0, first) }) {
            recent.performActionForItem(at: index)
        } else { check("first document remains in recent menu", false) }
        check("opening same path again keeps existing window count", app.editors.count == 2)
        close(app)

        let multi = controller()
        launch(multi)
        let original = multi.editors[0]
        multi.open(first)
        multi.open(second)
        check("rapid multi-file open consumes placeholder only once", await wait { multi.editors.count == 2 && multi.editors[0] === original && Set(multi.editors.compactMap { $0.file.url }) == Set([first, second]) })
        close(multi)

        let direct = controller()
        direct.open(first)
        launch(direct)
        check("file launch has no extra startup window", direct.editors.count == 1 && direct.editors[0].file.url == first)
        close(direct)

        let failed = controller()
        launch(failed)
        let spare = failed.editors[0]
        failed.open(root.appendingPathComponent("missing.md"))
        check("failed open leaves startup window untouched", failed.editors.count == 1 && failed.editors[0] === spare && spare.isStartupPlaceholder && !errors.isEmpty)
        close(failed)

        let explicit = controller()
        explicit.newDocument(nil)
        let newWindow = explicit.editors[0]
        explicit.open(first)
        check("File New windows are never consumed", explicit.editors.count == 2 && explicit.editors[0] === newWindow && newWindow.file.url == nil)
        close(explicit)

        let edited = controller()
        launch(edited)
        let draft = edited.editors[0]
        check("draft editor loads", await ready(draft, text: ""))
        // Formatting an empty selection is a real CodeMirror transaction and
        // posts its change asynchronously through the production bridge.
        _ = await js(draft, "window.margin.command('bold')")
        edited.open(first)
        check("pending edits prevent startup replacement", await wait { edited.editors.count == 2 && draft.file.text == "****" && draft.file.url == nil && draft.file.isDirty })
        _ = await js(draft, "window.margin.command('undo')")
        check("undo returns to empty source", await ready(draft, text: ""))
        edited.open(second)
        check("previously edited startup stays protected after undo", await wait { edited.editors.count == 3 && draft.file.url == nil && !draft.isStartupPlaceholder })
        close(edited)

        let saved = controller()
        launch(saved)
        let savedDraft = saved.editors[0]
        let savedURL = root.appendingPathComponent("saved.md")
        try! savedDraft.file.save(to: savedURL, text: "")
        saved.open(first)
        check("saved startup document is never replaced", await wait { saved.editors.count == 2 && savedDraft.file.url == savedURL })
        close(saved)

        let reopen = controller()
        _ = reopen.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
        check("reopening with no windows creates reusable startup", reopen.editors.count == 1 && reopen.editors[0].isStartupPlaceholder)
        let reopened = reopen.editors[0]
        _ = reopen.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
        check("reopen does not multiply hidden windows", reopen.editors.count == 1 && reopen.editors[0] === reopened)
        close(reopen)

        let tabs = controller(showsWindows: true)
        launch(tabs)
        let marginMenu = NSApp.mainMenu!.item(withTitle: "Margin")!.submenu!
        check("Margin menu has no Settings window", marginMenu.item(withTitle: "Settings…") == nil)
        let viewItems = NSApp.mainMenu!.item(withTitle: "View")!.submenu!
        let tabsItem = viewItems.item(withTitle: "Open Documents in Tabs")!
        let toggleTabs = { viewItems.performActionForItem(at: viewItems.index(of: tabsItem)) }
        _ = tabs.validateMenuItem(tabsItem)
        check("View offers Open Documents in Tabs, off by default", tabsItem.state == .off && !defaults.bool(forKey: "preferTabs"))
        toggleTabs()
        _ = tabs.validateMenuItem(tabsItem)
        check("Open Documents in Tabs persists and shows a checkmark", UserDefaults(suiteName: settingsSuite)!.bool(forKey: "preferTabs") && tabsItem.state == .on)
        let blank = tabs.editors[0]
        tabs.open(first)
        check("tabs enabled still reuse startup window", await wait { tabs.editors.count == 1 && tabs.editors[0] === blank && blank.file.url == first })
        tabs.open(second)
        check("additional file becomes selected native tab", await wait { tabs.editors.count == 2 && blank.window.tabbedWindows?.count == 2 && blank.window.tabGroup?.selectedWindow === tabs.editors[1].window })
        let secondTab = tabs.editors[1]
        let firstLoaded = await ready(blank, text: "# First\n\nDocument one.\n")
        let secondLoaded = await ready(secondTab, text: "# Second\n\nDocument two.\n")
        check("tabs keep independent document content", firstLoaded && secondLoaded)
        tabs.open(first)
        check("reopening existing document selects its tab", tabs.editors.count == 2 && blank.window.tabGroup?.selectedWindow === blank.window)
        secondTab.closeWithoutPrompt()
        check("closing one tab retains the other document", tabs.editors.count == 1 && tabs.editors[0] === blank && blank.file.url == first)
        toggleTabs()
        tabs.open(second)
        let separate = tabs.editors.last!
        check("turning preference off opens a separate window", tabs.editors.count == 2 && !(blank.window.tabbedWindows ?? []).contains(separate.window))
        toggleTabs()
        blank.show()
        let appearanceMenu = viewItems.item(withTitle: "Appearance")!.submenu!
        let choose = { (title: String) in appearanceMenu.performActionForItem(at: appearanceMenu.indexOfItem(withTitle: title)) }
        let prefersDark = { await self.js(blank, "matchMedia('(prefers-color-scheme: dark)').matches") as? Bool }
        choose("Dark")
        let darkItem = appearanceMenu.item(withTitle: "Dark")!
        _ = tabs.validateMenuItem(darkItem)
        let dark = await wait { await prefersDark() == true }
        check("View > Appearance > Dark darkens the app and its documents, with a checkmark", dark && NSApp.appearance?.name == .darkAqua && defaults.string(forKey: "appearance") == "dark" && darkItem.state == .on)
        choose("Light")
        let light = await wait { await prefersDark() == false }
        check("View > Appearance > Light lightens documents", light && NSApp.appearance?.name == .aqua && defaults.string(forKey: "appearance") == "light")
        choose("Match System")
        let systemItem = appearanceMenu.item(withTitle: "Match System")!
        _ = tabs.validateMenuItem(systemItem)
        check("View > Appearance > Match System follows the system again", NSApp.appearance == nil && defaults.string(forKey: "appearance") == nil && systemItem.state == .on)
        tabs.newDocument(nil)
        let newTab = tabs.editors.last!
        check("new document joins active document group", blank.window.tabbedWindows?.contains(newTab.window) == true && !(separate.window.tabbedWindows ?? []).contains(newTab.window))
        check("new tab is selected and preserves existing file", newTab.window.tabGroup?.selectedWindow === newTab.window && blank.file.text == "# First\n\nDocument one.\n" && !blank.file.isDirty)
        close(tabs)
        await experienceChecks()
        defaults.removePersistentDomain(forName: settingsSuite)
        try? FileManager.default.removeItem(at: root)
    }
    func disk(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
    func experienceChecks() async {
        defaults.set(false, forKey: "preferTabs")
        let notes = root.appendingPathComponent("notes.md")
        let linked = root.appendingPathComponent("linked.md")
        let filler = Array(repeating: "Filler paragraph.\n", count: 80).joined(separator: "\n")
        let original = "# Notes\n\n- [ ] Task\n\nSee [linked](linked.md) and [end](#the-end).\n\n\(filler)\n## The End\n\nDone.\n"
        try! Data(original.utf8).write(to: notes)
        try! Data("# Linked\n".utf8).write(to: linked)
        let app = controller()
        launch(app)
        app.open(notes)
        _ = await wait { app.editors.first?.file.url == notes }
        let editor = app.editors[0]
        check("experience document loads", await ready(editor, text: original))
        check("diagram library is not loaded without diagrams", await js(editor, "typeof window.mermaid") as? String == "undefined")

        _ = await js(editor, "document.querySelector('.md-task').dispatchEvent(new MouseEvent('mousedown', { bubbles: true, button: 0 })); void 0")
        let toggled = original.replacingOccurrences(of: "- [ ] Task", with: "- [x] Task")
        check("clicking a task checkbox toggles its Markdown", await ready(editor, text: toggled))
        check("task toggle keeps the checkbox rendered", await js(editor, "document.querySelector('.md-task')?.checked === true && !document.querySelector('.md-marker')") as? Bool == true)
        check("edited file autosaves after a pause", await wait { self.disk(notes) == toggled && !editor.file.isDirty })

        let external = toggled.replacingOccurrences(of: "Done.", with: "Changed elsewhere.")
        try! Data(external.utf8).write(to: notes)
        check("external change reloads a clean document silently", await ready(editor, text: external))
        check("reloaded document is clean", !editor.file.isDirty && editor.window.title == "notes.md")
        let atomic = external.replacingOccurrences(of: "Changed elsewhere.", with: "Replaced atomically.")
        try! Data(atomic.utf8).write(to: notes, options: .atomic)
        check("atomic replacement by another app also reloads", await ready(editor, text: atomic))

        _ = await js(editor, "window.margin.command('bold'); void 0")
        let closedText = await js(editor, "window.margin.getText()") as? String ?? ""
        var closeAllowed: Bool?
        editor.requestClose { closeAllowed = $0 }
        check("closing an edited file saves without asking", await wait { closeAllowed == true } && disk(notes) == closedText && closedText.hasPrefix("****"))
        close(app)

        let outlined = "# Notes\n\n## Details\n\nSee [linked](linked.md) and [end](#the-end).\n\n\(filler)\n## The End\n\nDone.\n"
        try! Data(outlined.utf8).write(to: notes)
        let reopened = controller()
        launch(reopened)
        reopened.open(notes)
        _ = await wait { reopened.editors.first?.file.url == notes }
        let view = reopened.editors[0]
        _ = await ready(view, text: outlined)
        reopened.toggleOutline(nil)
        reopened.toggleWordCount(nil)
        check("outline shows a lone top heading as the title and its sections as the top level", await wait { await self.js(view, "[...document.querySelectorAll('#outline a')].map(a => a.textContent + ':' + a.className.replace(' current', '')).join('|')") as? String == "Notes:title|Details:depth-0|The End:depth-0" })
        let outlineWidth = "Math.round(document.querySelector('#outline').getBoundingClientRect().width)"
        _ = await js(view, "(() => { const handle = document.querySelector('#outline-resizer'), at = { bubbles: true, button: 0, buttons: 1, clientY: 100 }; handle.dispatchEvent(new MouseEvent('mousedown', { ...at, clientX: 220 })); document.dispatchEvent(new MouseEvent('mousemove', { ...at, clientX: 300 })); document.dispatchEvent(new MouseEvent('mouseup', { ...at, clientX: 300, buttons: 0 })); })()")
        check("dragging the outline's edge saves its width", await wait { self.defaults.double(forKey: "outlineWidth") == 300 })
        view.applyPanels()
        check("the saved width is restored", await wait { await self.js(view, outlineWidth) as? Int == 300 })
        _ = await js(view, "document.querySelector('#outline-resizer').dispatchEvent(new MouseEvent('dblclick', { bubbles: true }))")
        check("double-clicking the edge resets the width", await wait { let width = await self.js(view, outlineWidth) as? Int; return self.defaults.object(forKey: "outlineWidth") == nil && width == 220 })
        check("word count appears", await wait { (await self.js(view, "document.querySelector('#word-count').hidden ? '' : document.querySelector('#word-count').textContent") as? String)?.hasSuffix(" words") == true })
        let viewMenu = NSApp.mainMenu!.item(withTitle: "View")!.submenu!
        let fileItems = NSApp.mainMenu!.item(withTitle: "File")!.submenu!
        check("File menu offers Export as PDF", fileItems.item(withTitle: "Export as PDF…")?.action == #selector(AppDelegate.exportPDF(_:)))
        let pdfURL = root.appendingPathComponent("notes.pdf")
        let exportError: String? = await withCheckedContinuation { continuation in
            _ = PDFExporter(file: view.file, destination: pdfURL, parent: view.window) { continuation.resume(returning: $0?.localizedDescription) }
        }
        let pdf = PDFDocument(url: pdfURL)
        let pdfText = (0..<(pdf?.pageCount ?? 0)).compactMap { pdf?.page(at: $0)?.string }.joined(separator: "\n")
        check("Export as PDF writes the rendered document, paginated, without markup", exportError == nil && (pdf?.pageCount ?? 0) >= 2 && pdfText.contains("Notes") && pdfText.contains("The End") && !pdfText.contains("##") && !pdfText.contains("]("))
        // Renaming from the title.
        check("rename keeps the extension unless one is typed", (try? DocumentRename.fileName(for: " Field notes ", current: "a.md")) == "Field notes.md" && (try? DocumentRename.fileName(for: "x.markdown", current: "a.md")) == "x.markdown" && (try? DocumentRename.fileName(for: "v1.2", current: "a.md")) == "v1.2.md")
        check("rename refuses empty names and path separators", (try? DocumentRename.fileName(for: "  ", current: "a.md")) == nil && (try? DocumentRename.fileName(for: "a/b", current: "a.md")) == nil && (try? DocumentRename.fileName(for: "a:b", current: "a.md")) == nil)
        check("File menu offers Rename…", fileItems.item(withTitle: "Rename…")?.action == #selector(AppDelegate.renameDocument(_:)))
        let toRename = root.appendingPathComponent("Rename me.md")
        try! "# Rename me\n".write(to: toRename, atomically: true, encoding: .utf8)
        reopened.open(toRename)
        _ = await wait { reopened.editors.contains { $0.file.url == toRename } }
        let renaming = reopened.editors.first { $0.file.url == toRename }!
        _ = await ready(renaming, text: "# Rename me\n")
        renaming.show()
        if let field = (renaming.window as? DocumentWindow)?.titleField {
            let point = field.convert(NSPoint(x: field.bounds.midX, y: field.bounds.midY), to: nil)
            renaming.window.sendEvent(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: renaming.window.windowNumber, context: nil as NSGraphicsContext?, eventNumber: 0, clickCount: 1, pressure: 1)!)
        }
        check("clicking the window title opens the rename popover with the name", renaming.renamePopover?.popover.isShown == true && renaming.renamePopover?.field.stringValue == "Rename me.md")
        renaming.renamePopover?.field.stringValue = "Renamed"
        renaming.renamePopover?.finish()
        let renamed = root.appendingPathComponent("Renamed.md")
        check("renaming moves the file on disk and retitles the window", FileManager.default.fileExists(atPath: renamed.path) && !FileManager.default.fileExists(atPath: toRename.path) && renaming.file.url == renamed && renaming.window.title == "Renamed.md")
        _ = await js(renaming, "window.margin.setSelection(window.margin.getText().length); document.execCommand('insertText', false, 'more'); void 0")
        _ = await wait { renaming.file.text.hasSuffix("more") }
        try! "taken\n".write(to: root.appendingPathComponent("Taken.md"), atomically: true, encoding: .utf8)
        var refused = false
        do { try renaming.rename(to: "Taken") } catch { refused = true }
        check("renaming to an existing name is refused and changes nothing", refused && renaming.file.url == renamed && (try? String(contentsOf: root.appendingPathComponent("Taken.md"), encoding: .utf8)) == "taken\n")
        try? renaming.rename(to: "Renamed again")
        check("renaming keeps unsaved edits", renaming.file.url == root.appendingPathComponent("Renamed again.md") && renaming.file.isDirty && renaming.file.text.hasSuffix("more"))
        renaming.closeWithoutPrompt()
        reopened.newDocument(nil)
        let unnamed = reopened.editors.last!
        try? unnamed.rename(to: "Draft")
        check("renaming an untitled document names it for its first save", unnamed.file.url == nil && unnamed.window.title == "Draft.md" && unnamed.file.name == "Draft.md")
        unnamed.closeWithoutPrompt()
        // Pasted and dropped images (a private pasteboard leaves the user's clipboard alone).
        let pngRep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 5, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let png = pngRep.representation(using: .png, properties: [:])!
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("margin-tests-\(UUID().uuidString)"))
        pasteboard.clearContents(); pasteboard.setData(png, forType: .png)
        _ = await js(view, "window.margin.setSelection(0); void 0")
        check("pasting image data is handled as an image", view.pasteImage(from: pasteboard))
        let assets = root.appendingPathComponent("assets")
        let pasted = (try? FileManager.default.contentsOfDirectory(atPath: assets.path))?.first { $0.hasPrefix("Pasted image ") && $0.hasSuffix(".png") }
        check("a pasted image is saved in an assets folder beside the document and linked", await wait {
            guard let pasted, let text = await self.js(view, "window.margin.getText()") as? String else { return false }
            return text.hasPrefix("![](assets/\(pasted.replacingOccurrences(of: " ", with: "%20")))")
        })
        check("the pasted image renders", await wait { await self.js(view, "[...document.querySelectorAll('.md-image img')].some(img => img.naturalWidth === 5)") as? Bool == true })
        let reveal = await js(view, "(() => { const end = window.margin.getText().indexOf(')') + 1, drawn = () => !!document.querySelector('.md-image'); window.margin.setSelection(2); const entered = drawn(); window.margin.setSelection(end); return [entered, drawn()]; })()") as? [Bool]
        check("an image's source, once entered, stays shown with the caret at its end", reveal == [false, false])
        let clicked = await js(view, "(() => { window.margin.setSelection(window.margin.getText().indexOf(')') + 2); const img = document.querySelector('.md-image'); if (!img) return 'not drawn'; const box = img.getBoundingClientRect(), point = { clientX: box.right - 1, clientY: box.top + box.height / 2, bubbles: true, button: 0, buttons: 1 }; document.elementFromPoint(point.clientX, point.clientY).dispatchEvent(new MouseEvent('mousedown', point)); document.dispatchEvent(new MouseEvent('mouseup', { ...point, buttons: 0 })); return document.querySelector('.md-image') ? 'drawn' : 'shown'; })()") as? String
        check("clicking the right edge of a drawn image shows its source", clicked == "shown")
        let pdfFigure = root.appendingPathComponent("figure.pdf")
        let drawing = NSView(frame: NSRect(x: 0, y: 0, width: 60, height: 40))
        try! drawing.dataWithPDF(inside: drawing.bounds).write(to: pdfFigure)
        view.insertImages(files: [pdfFigure], data: nil, at: nil)
        check("a PDF figure is linked like an image and renders", await wait {
            let text = await self.js(view, "window.margin.getText()") as? String ?? ""
            _ = await self.js(view, "window.margin.setSelection(window.margin.getText().indexOf('## Details')); void 0")
            let rendered = await self.js(view, "[...document.querySelectorAll('.md-image img')].some(img => img.src.includes('figure.pdf') && img.naturalWidth > 0)") as? Bool
            return text.contains("![](figure.pdf)") && rendered == true
        })
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("margin-drop-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let figure = outside.appendingPathComponent("My figure (final).png")
        try! png.write(to: figure)
        view.insertImages(files: [figure], data: nil, at: nil)
        view.insertImages(files: [figure], data: nil, at: nil)
        check("an image from another folder is copied into assets, with a numbered name on a clash", await wait {
            let text = await self.js(view, "window.margin.getText()") as? String ?? ""
            return FileManager.default.fileExists(atPath: assets.appendingPathComponent("My figure (final).png").path) && FileManager.default.fileExists(atPath: assets.appendingPathComponent("My figure (final) 2.png").path)
                && text.contains("![](assets/My%20figure%20%28final%29.png)") && text.contains("![](assets/My%20figure%20%28final%29%202.png)")
        })
        let inside = root.appendingPathComponent("figures")
        try! FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        try! png.write(to: inside.appendingPathComponent("local.png"))
        view.insertImages(files: [inside.appendingPathComponent("local.png")], data: nil, at: nil)
        let linkedInPlace = await wait { (await self.js(view, "window.margin.getText()") as? String ?? "").contains("![](figures/local.png)") }
        check("an image inside the document's folder is linked where it is", linkedInPlace && !FileManager.default.fileExists(atPath: assets.appendingPathComponent("local.png").path))
        pasteboard.clearContents(); pasteboard.setString("plain words", forType: .string); pasteboard.setData(png, forType: .png)
        check("a pasteboard with text pastes as text, not as an image", !view.pasteImage(from: pasteboard))
        reopened.newDocument(nil)
        let untitled = reopened.editors.last!
        _ = await wait { await self.js(untitled, "window.margin?.getText()") as? String == "" }
        pasteboard.clearContents(); pasteboard.setData(png, forType: .png)
        _ = untitled.pasteImage(from: pasteboard)
        let noticed = await wait { await self.js(untitled, "document.querySelector('#notice').textContent") as? String == "Save this document first so its images have a folder." }
        let untouched = await js(untitled, "window.margin.getText()") as? String == ""
        check("an untitled document does not save images", noticed && untouched)
        untitled.closeWithoutPrompt()
        pasteboard.releaseGlobally()
        let editMenu = NSApp.mainMenu!.item(withTitle: "Edit")!.submenu!
        check("Paste routes images into the document and everything else to the normal paste", editMenu.item(withTitle: "Paste")?.action == #selector(AppDelegate.pasteFocused(_:)))
        check("Select All selects the editor's whole document or the focused cell, not WebKit's partial page", editMenu.item(withTitle: "Select All")?.action == #selector(AppDelegate.selectAllFocused(_:)))
        check("View menu offers outline and word count toggles", viewMenu.items.contains { $0.action == #selector(AppDelegate.toggleOutline(_:)) } && viewMenu.items.contains { $0.action == #selector(AppDelegate.toggleWordCount(_:)) })
        _ = await js(view, "window.margin.openLink('#the-end'); void 0")
        check("heading anchor links scroll within the document", await wait { (await self.js(view, "document.querySelector('.cm-scroller').scrollTop") as? Double ?? 0) > 100 })
        check("outline follows scroll position", await wait { await self.js(view, "document.querySelector('#outline a.current')?.textContent") as? String == "The End" })
        _ = await js(view, "window.margin.openLink('linked.md'); void 0")
        check("relative Markdown links open in Margin", await wait { reopened.editors.contains { $0.file.url == linked } })
        reopened.toggleOutline(nil)
        reopened.toggleWordCount(nil)
        check("panels hide again", await wait { await self.js(view, "document.querySelector('#outline').hidden && document.querySelector('#word-count').hidden") as? Bool == true })

        let zoomIn = viewMenu.items.first { $0.title == "Zoom In" && !$0.isHidden }!
        _ = (zoomIn.target as? NSObject)?.perform(zoomIn.action, with: zoomIn)
        reopened.newDocument(nil)
        check("new windows use the last chosen zoom", abs((reopened.editors.last?.webView.pageZoom ?? 0) - 1.3) < 0.001)
        // Hidden test windows accept no typed input; the invariant suite types with
        // these settings. Here, check the editor window turns substitutions off.
        check("editor windows disable smart quotes, dashes, replacement and autocorrect",
              ["WebAutomaticQuoteSubstitutionEnabled", "WebAutomaticDashSubstitutionEnabled", "WebAutomaticTextReplacementEnabled", "WebAutomaticSpellingCorrectionEnabled"]
                .allSatisfy { UserDefaults.standard.object(forKey: $0) as? Bool == false })
        let diagram = reopened.editors.last!
        _ = await wait { await self.js(diagram, "window.margin?.getText()") as? String == "" }
        _ = await js(diagram, "window.margin.loadDocument({ text: '```mermaid\\ngraph LR\\nA --> B\\n```\\n', name: 'd.md', dirty: false }); void 0")
        check("diagram library loads on demand and renders", await wait { await self.js(diagram, "!!document.querySelector('.diagram svg') && typeof window.mermaid") as? String == "object" })
        close(reopened)
    }
    func finish() -> Bool {
        let passed = results.allSatisfy { $0["passed"] as? Bool == true }
        let data: [String: Any] = ["passed": passed, "checks": results, "expectedErrors": errors,
            "surface": "Production AppDelegate and EditorWindow with actual bundled WKWebView editor; test bundle has a separate identity", "os": ProcessInfo.processInfo.operatingSystemVersionString]
        try! JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        print("\(results.filter { $0["passed"] as? Bool == true }.count)/\(results.count) lifecycle checks passed")
        return passed
    }
}
