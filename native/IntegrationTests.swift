import AppKit
import WebKit
import CryptoKit

/// Application integration testing: real WKWebView and web/native bridge, no
/// Accessibility, AppleScript, synthetic OS input, or external UI automation.
@main struct IntegrationTests {
    static var runner: BridgeRunner?
    static func main() {
        guard CommandLine.arguments.count == 3 else {
            fputs("Usage: integration-tests WEB_DIRECTORY RESULT_JSON\n", stderr)
            exit(2)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        runner = BridgeRunner(webRoot: URL(fileURLWithPath: CommandLine.arguments[1]),
                              output: URL(fileURLWithPath: CommandLine.arguments[2]))
        runner!.start()
        app.run()
    }
}

final class BridgeRunner: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let webRoot: URL
    let output: URL
    let view: WKWebView
    let window: NSWindow
    let assetsRoot: URL
    var checks: [[String: Any]] = []
    var messages: [[String: Any]] = []
    var finished = false
    var began = false
    let started = Date()
    let fixture = "# UTF-8 café 📝\n\nBackticks: `hello` and `${notCode}`.\n\n</script><script>window.injectionExecuted = true</script>\n\nQuotes: \"double\" and 'single', backslash: \\\nUnicode separators: \u{2028} \u{2029}\n"

    init(webRoot: URL, output: URL) {
        self.webRoot = webRoot
        self.output = output
        assetsRoot = FileManager.default.temporaryDirectory.appendingPathComponent("margin-image-integration-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: assetsRoot, withIntermediateDirectories: true)
        let documentURL = assetsRoot.appendingPathComponent("note.md")
        try! Data("# Image integration\n".utf8).write(to: documentURL)
        try! Data("<svg xmlns='http://www.w3.org/2000/svg' width='2' height='3'><rect width='2' height='3' fill='red'/></svg>".utf8).write(to: assetsRoot.appendingPathComponent("fixture.svg"))
        // A sibling of the document's folder, reached with `../`.
        try! Data("<svg xmlns='http://www.w3.org/2000/svg' width='2' height='3'/>".utf8).write(to: assetsRoot.deletingLastPathComponent().appendingPathComponent(assetsRoot.lastPathComponent + "-outside.svg"))
        try! Data("not an image".utf8).write(to: assetsRoot.deletingLastPathComponent().appendingPathComponent(assetsRoot.lastPathComponent + "-outside.txt"))
        let figures = assetsRoot.appendingPathComponent("figures")
        try! FileManager.default.createDirectory(at: figures, withIntermediateDirectories: true)
        let png = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 3, bitsPerSample: 8,
                                  samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                  bytesPerRow: 0, bitsPerPixel: 0)!
        for x in 0..<2 { for y in 0..<3 { png.setColor(.systemGray, atX: x, y: y) } }
        for name in ["model_a_alpha", "model_a_psi", "model_b_alpha", "model_b_psi"] {
            try! png.representation(using: .png, properties: [:])!.write(to: figures.appendingPathComponent(name + ".png"))
        }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(DocumentAssetHandler(file: try! MarkdownFile(contentsOf: documentURL)), forURLScheme: "margin-asset")
        view = WKWebView(frame: NSRect(x: 0, y: 0, width: 960, height: 720), configuration: config)
        window = NSWindow(contentRect: view.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        super.init()
        config.userContentController.add(self, name: "margin")
        view.navigationDelegate = self
        view.pageZoom = 1.2
        window.contentView = view
    }

    func start() {
        view.loadFileURL(webRoot.appendingPathComponent("index.html"), allowingReadAccessTo: webRoot)
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            if !self.finished { self.check("completion before timeout", false); self.finish() }
        }
    }

    func check(_ name: String, _ passed: Bool, detail: String? = nil) {
        var result: [String: Any] = ["name": name, "passed": passed]
        if let detail { result["detail"] = detail }
        checks.append(result)
        print("\(passed ? "PASS" : "FAIL"): \(name)\(detail.map { " — " + $0 } ?? "")")
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        messages.append(body)
        if body["type"] as? String == "ready", !began {
            began = true
            check("main-frame ready bridge", message.frameInfo.isMainFrame)
            Task { await runChecks() }
        }
    }

    @MainActor func evaluate(_ script: String) async -> Any? {
        await withCheckedContinuation { continuation in
            view.evaluateJavaScript(script) { result, error in
                if let error { self.check("JavaScript evaluation", false, detail: error.localizedDescription) }
                continuation.resume(returning: result)
            }
        }
    }

    func json(_ value: Any) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), encoding: .utf8)!
    }

    @MainActor func runChecks() async {
        let document: [String: Any] = ["text": fixture, "name": "café `test`.md", "path": "/tmp/test.md", "dirty": false]
        _ = await evaluate("window.margin.loadDocument(\(json(document)))")
        let text = await evaluate("window.margin.getText()") as? String
        check("JSON payload roundtrip preserves Unicode, backticks, quotes and script strings", text == fixture)
        check("script-like payload is inert", await evaluate("window.injectionExecuted === undefined") as? Bool == true)
        check("document name updated", await evaluate("document.title") as? String == "café `test`.md — Margin")
        let crlf = "# Windows\r\n\r\nUnicode café 📝\r\n"
        _ = await evaluate("window.margin.loadDocument(\(json(["text": crlf, "name": "windows.md", "dirty": false])))")
        check("CRLF bridge roundtrip", await evaluate("window.margin.getText()") as? String == crlf)

        let navigation = "## One\n\nParagraph **two**.\n\nLast paragraph."
        _ = await evaluate("window.margin.loadDocument(\(json(["text": navigation, "name": "navigation.md", "dirty": false])))")
        _ = await evaluate("window.margin.command('selectAll'); document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown', {key:'ArrowLeft',bubbles:true,cancelable:true})); document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown', {key:'End',bubbles:true,cancelable:true})); window.margin.command('bold');")
        check("line-end stays on active heading beside rendered blocks", await evaluate("window.margin.getText()") as? String == "## One****\n\nParagraph **two**.\n\nLast paragraph.")
        // Visual vertical-navigation behavior is covered by NavigationTests.swift.
        // The former source-character-column assertion intentionally no longer applies.

        let editable = "Native bridge test café 📝"
        _ = await evaluate("window.margin.loadDocument(\(json(["text": editable, "name": "edit.md", "dirty": false])))")
        _ = await evaluate("window.margin.command('selectAll'); document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown', { key: 'b', code: 'KeyB', metaKey: true, bubbles: true, cancelable: true }));")
        let edited = "**" + editable + "**"
        check("DOM keyboard formatting edits document", await evaluate("window.margin.getText()") as? String == edited)
        check("change bridge sends edited text", messages.contains { $0["type"] as? String == "change" && $0["text"] as? String == edited })
        _ = await evaluate("window.margin.command('undo')")
        check("native undo command restores original text", await evaluate("window.margin.getText()") as? String == editable)
        _ = await evaluate("window.margin.command('redo')")
        check("native redo command restores edit", await evaluate("window.margin.getText()") as? String == edited)
        _ = await evaluate("window.margin.setDocumentInfo(\(json(["name": "saved.md", "path": "/tmp/saved.md", "dirty": false])))")
        check("saved document info clears edited title", await evaluate("document.title") as? String == "saved.md — Margin")
        _ = await evaluate("window.margin.command('find')")
        check("native find command opens search", await evaluate("!!document.querySelector('.cm-search input')") as? Bool == true)
        _ = await evaluate("window.margin.command('save'); window.margin.command('saveAs');")
        // A subsequent evaluation gives the native message queue a turn.
        _ = await evaluate("window.margin.getText()")
        check("save request carries exact text", messages.contains { $0["type"] as? String == "save" && $0["text"] as? String == edited })
        check("save-as request carries exact text", messages.contains { $0["type"] as? String == "saveAs" && $0["text"] as? String == edited })
        _ = await evaluate("window.margin.openLink('https://example.com/reference')")
        _ = await evaluate("window.margin.getText()")
        check("links delegate through native bridge", messages.contains { $0["type"] as? String == "openLink" && $0["url"] as? String == "https://example.com/reference" })
        check("native page zoom matches observed MDV setting", view.pageZoom == 1.2)
        _ = await evaluate("""
            window.imageResult = null;
            const image = new Image();
            image.onload = () => { window.imageResult = image.naturalWidth === 2 && image.naturalHeight === 3; };
            image.onerror = () => { window.imageResult = false; };
            image.src = 'margin-asset://document/?path=fixture.svg';
            document.body.appendChild(image);
            void 0;
            """)
        for _ in 0..<20 {
            if await evaluate("window.imageResult") as? Bool != nil { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        check("custom-scheme SVG image decodes with correct MIME", await evaluate("window.imageResult") as? Bool == true)
        _ = await evaluate("""
            window.deniedImage = null;
            const denied = new Image();
            denied.onload = () => { window.deniedImage = false; };
            denied.onerror = () => { window.deniedImage = true; };
            denied.src = 'margin-asset://document/?path=..%2F\(assetsRoot.lastPathComponent)-outside.txt';
            document.body.appendChild(denied);
            void 0;
            """)
        for _ in 0..<20 {
            if await evaluate("window.deniedImage") as? Bool != nil { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        check("custom-scheme request for a non-image file fails in WebKit", await evaluate("window.deniedImage") as? Bool == true)
        let outsideMarkdown = "![Outside](../\(assetsRoot.lastPathComponent)-outside.svg)\n"
        _ = await evaluate("window.margin.loadDocument(\(json(["text": outsideMarkdown, "name": "outside.md", "path": assetsRoot.appendingPathComponent("note.md").path, "dirty": false])))")
        for _ in 0..<20 {
            if await evaluate("document.querySelector('.md-image img')?.complete") as? Bool == true { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        check("a ../ image outside the document's folder renders", await evaluate("document.querySelector('.md-image img')?.naturalWidth === 2") as? Bool == true)
        let imageMarkdown = "![Local diagram](fixture%2Esvg)\n\nAnother paragraph.\n"
        _ = await evaluate("window.margin.loadDocument(\(json(["text": imageMarkdown, "name": "images.md", "path": assetsRoot.appendingPathComponent("note.md").path, "dirty": false])))")
        for _ in 0..<20 {
            if await evaluate("document.querySelector('.md-image img')?.complete") as? Bool == true { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        check("rendered Markdown rewrites encoded relative image URL correctly", await evaluate("document.querySelector('.md-image img')?.naturalWidth === 2") as? Bool == true)
        check("relative image rendering preserves source Markdown", await evaluate("window.margin.getText()") as? String == imageMarkdown)
        let htmlTable = try! String(contentsOf: webRoot.appendingPathComponent("fixtures/html-table-images.md"), encoding: .utf8)
        _ = await evaluate("window.margin.loadDocument(\(json(["text": htmlTable, "name": "table.md", "path": assetsRoot.appendingPathComponent("note.md").path, "dirty": false])))")
        for _ in 0..<30 {
            if await evaluate("Array.from(document.querySelectorAll('.prose td img')).filter(img => img.complete && img.naturalWidth === 2).length === 4") as? Bool == true { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let tableImages = await evaluate("Array.from(document.querySelectorAll('.prose td img')).map(img => ({src:img.getAttribute('src'),width:img.getAttribute('width'),alt:img.alt,naturalWidth:img.naturalWidth,naturalHeight:img.naturalHeight,displayWidth:img.getBoundingClientRect().width}))")
        check("all four HTML table images load through document-relative PNG paths", await evaluate("Array.from(document.querySelectorAll('.prose td img')).filter(img => img.complete && img.naturalWidth === 2 && img.naturalHeight === 3 && img.src.startsWith('margin-asset://document/?path=figures')).length === 4") as? Bool == true, detail: tableImages.map { json($0) })
        check("HTML table images preserve width and descriptive alt text", await evaluate("Array.from(document.querySelectorAll('.prose td img')).filter(img => img.getAttribute('width') === '320' && img.alt.includes('Model ') && img.getBoundingClientRect().width > 0 && img.getBoundingClientRect().width <= 321).length === 4") as? Bool == true)
        check("rendering the image table preserves exact source", await evaluate("window.margin.getText()") as? String == htmlTable)
        _ = await evaluate("(() => { const img=document.querySelector('.prose td img');if(!img)return; const r=img.getBoundingClientRect();const e={button:0,buttons:1,detail:1,clientX:r.left+1,clientY:r.top+1,bubbles:true,cancelable:true};img.dispatchEvent(new MouseEvent('mousedown',e));document.dispatchEvent(new MouseEvent('mouseup',{...e,buttons:0})); })()")
        check("clicking a table image edits that cell's Markdown in place without changing it", await evaluate("document.activeElement?.closest('.table-widget td') && document.activeElement.textContent.includes('<img') && window.margin.getText() === \(json(htmlTable))") as? Bool == true)
        _ = await evaluate("document.activeElement.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true,cancelable:true})); window.margin.command('selectAll')")
        check("select all keeps the image table rendered and its source unchanged", await evaluate("!!document.querySelector('.table-widget.md-widget-selected') && document.querySelectorAll('.table-widget td img').length === 4 && window.margin.getText() === \(json(htmlTable))") as? Bool == true)
        let unsafeImage = "<img src=\"javascript:window.imageAttack=true\" onerror=\"window.imageAttack=true\" onclick=\"window.imageAttack=true\" width=\"320\"><script>window.imageAttack=true</script>"
        _ = await evaluate("window.margin.loadDocument(\(json(["text":unsafeImage,"name":"unsafe.md","dirty":false])))")
        check("HTML images pass through sanitization before reaching the DOM", await evaluate("!!document.querySelector('.md-image img') && !document.querySelector('.md-image img').hasAttribute('src') && !document.querySelector('.md-image img').hasAttribute('onerror') && !document.querySelector('.md-image img').hasAttribute('onclick') && !document.querySelector('.cm-content script') && window.imageAttack !== true") as? Bool == true)
        _ = await evaluate("window.margin.loadDocument({text:'Paragraph',name:'newlines.md',dirty:false}); window.margin.command('selectAll'); document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowRight',bubbles:true,cancelable:true}));")
        var lineTops: [Double] = []
        for count in 1...3 {
            _ = await evaluate("document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',code:'Enter',bubbles:true,cancelable:true}));")
            try? await Task.sleep(nanoseconds: 80_000_000)
            let source = await evaluate("window.margin.getText()") as? String
            let top = await evaluate("document.querySelector('.cm-content > .cm-line:last-child').getBoundingClientRect().top") as? Double ?? -1
            lineTops.append(top)
            check("Enter \(count) preserves all source newlines", source == "Paragraph" + String(repeating: "\n", count: count), detail: source.debugDescription)
        }
        check("successive Enter presses advance to visible new lines", zip(lineTops, lineTops.dropFirst()).allSatisfy { $1 - $0 > 10 }, detail: "caret-line tops: \(lineTops)")
        let sourceWithBlanks = "Paragraph\n\n\n"
        _ = await evaluate("window.margin.command('save'); window.margin.command('undo'); window.margin.command('redo');")
        check("undo and redo preserve consecutive newlines", await evaluate("window.margin.getText()") as? String == sourceWithBlanks)
        check("save carries consecutive newlines", messages.contains { $0["type"] as? String == "save" && $0["text"] as? String == sourceWithBlanks })
        _ = await evaluate("window.margin.loadDocument({text:\(json(sourceWithBlanks)),name:'newlines.md',dirty:false})")
        let blankHeights = await evaluate("JSON.stringify(Array.from(document.querySelectorAll('.cm-content > .cm-line')).map(line => line.getBoundingClientRect().height))") as? String ?? "[]"
        check("additional blank lines remain visible after reload", await evaluate("Array.from(document.querySelectorAll('.cm-content > .cm-line')).filter(line => line.getBoundingClientRect().height > 10).length >= 2") as? Bool == true, detail: blankHeights)
        _ = await evaluate("window.margin.loadDocument({text:'One\\n\\nTwo',name:'spacing.md',dirty:false})")
        check("ordinary paragraph separator is a visible row, as in Obsidian", await evaluate("document.querySelectorAll('.cm-content > .cm-line')[1].getBoundingClientRect().height > 10") as? Bool == true)
        _ = await evaluate("window.margin.loadDocument({text:'One\\n\\n\\n\\nTwo',name:'spacing.md',dirty:false})")
        check("extra spacing between paragraphs stays visible", await evaluate("Array.from(document.querySelectorAll('.cm-content > .cm-line')).filter(line => line.getBoundingClientRect().height > 10).length === 5") as? Bool == true)
        let fenced = "```text\nfirst\n\n\nlast\n```"
        _ = await evaluate("window.margin.loadDocument({text:\(json(fenced)),name:'code.md',dirty:false}); window.margin.command('selectAll'); document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowLeft',bubbles:true,cancelable:true}));")
        check("active code block retains blank source lines", await evaluate("Array.from(document.querySelectorAll('.md-code-line')).filter(line => !line.textContent.trim()).length >= 2 && Array.from(document.querySelectorAll('.md-code-line')).filter(line => !line.textContent.trim()).every(line => line.getBoundingClientRect().height > 10)") as? Bool == true)
        _ = await evaluate("window.margin.loadDocument({text:'',name:'empty.md',dirty:false}); window.margin.command('selectAll'); for(let i=0;i<3;i++) document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',code:'Enter',bubbles:true,cancelable:true}));")
        check("empty document accepts successive visible newlines", await evaluate("window.margin.getText() === '\\n\\n\\n' && Array.from(document.querySelectorAll('.cm-content > .cm-line')).filter(line => line.getBoundingClientRect().height > 10).length === 4") as? Bool == true)
        _ = await evaluate("window.margin.loadDocument({text:'Paragraph\\r\\n',name:'windows.md',dirty:false}); window.margin.command('selectAll'); document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowRight',bubbles:true,cancelable:true})); for(let i=0;i<2;i++) document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',code:'Enter',bubbles:true,cancelable:true}));")
        check("successive newlines preserve CRLF document convention", await evaluate("window.margin.getText()") as? String == "Paragraph\r\n\r\n\r\n")
        // Exercise pointer selection through rendered DOM without exposing editor internals.
        _ = await evaluate("""
            window.clickWord = (word, shiftKey = false, detail = 1, release = true, eventType = 'mousedown') => {
              const walker = document.createTreeWalker(document.querySelector('.cm-content'), NodeFilter.SHOW_TEXT);
              let node;
              while (node = walker.nextNode()) {
                const offset = node.textContent.indexOf(word);
                if (offset < 0) continue;
                const range = document.createRange();
                range.setStart(node, offset); range.setEnd(node, offset + word.length);
                const rect = range.getBoundingClientRect();
                const event = {button:0,buttons:1,detail,shiftKey,clientX:rect.right - 1,clientY:rect.top + rect.height / 2,bubbles:true,cancelable:true};
                node.parentElement.dispatchEvent(new MouseEvent(eventType,event));
                if (release) document.dispatchEvent(new MouseEvent('mouseup',{...event,buttons:0}));
                return true;
              }
              return false;
            }; void 0;
            """)
        let multiline = "alpha\nbeta\n\ngamma delta"
        _ = await evaluate("window.margin.loadDocument({text:\(json(multiline)),name:'click.md',dirty:false}); window.clickWord('beta'); window.margin.command('bold');")
        let multilineResult = await evaluate("window.margin.getText()") as? String
        check("clicking second source line in a rendered paragraph edits that line", multilineResult == "alpha\nbeta****\n\ngamma delta", detail: multilineResult.debugDescription)
        _ = await evaluate("window.margin.loadDocument({text:\(json(multiline.replacingOccurrences(of: "\n", with: "\r\n"))),name:'click-crlf.md',dirty:false}); window.clickWord('beta'); window.margin.command('bold');")
        check("multiline click preserves CRLF source offsets", await evaluate("window.margin.getText()") as? String == "alpha\r\nbeta****\r\n\r\ngamma delta")
        let selectSource = "First.\n\nSecond.\n\nThird."
        _ = await evaluate("window.margin.loadDocument({text:\(json(selectSource)),name:'selection.md',dirty:false}); window.clickWord('First'); window.clickWord('Third',true); window.margin.command('bold');")
        let selectionResult = await evaluate("window.margin.getText()") as? String
        check("Shift-click extends selection across rendered paragraphs", selectionResult == "First**.\n\nSecond.\n\nThird**.", detail: selectionResult.debugDescription)
        _ = await evaluate("window.margin.loadDocument({text:'alpha beta gamma',name:'word.md',dirty:false}); window.clickWord('beta',false,2); window.margin.command('bold');")
        let wordResult = await evaluate("window.margin.getText()") as? String
        check("double-click selects a rendered word", wordResult == "alpha **beta** gamma", detail: wordResult.debugDescription)
        let codeSource = "```text\nfirst\nsecond\n```"
        _ = await evaluate("window.margin.loadDocument({text:\(json(codeSource)),name:'code-click.md',dirty:false}); window.clickWord('second'); window.margin.command('bold');")
        let codeResult = await evaluate("window.margin.getText()") as? String
        check("clicking a rendered code line edits that source line", codeResult == "```text\nfirst\nsecond****\n```", detail: codeResult.debugDescription)
        _ = await evaluate("window.margin.loadDocument({text:\(json(selectSource)),name:'drag.md',dirty:false}); window.clickWord('First',false,1,false); window.clickWord('Third',false,1,true,'mousemove'); window.margin.command('bold');")
        let dragResult = await evaluate("window.margin.getText()") as? String
        check("drag from rendered text selects across paragraphs", dragResult == "First**.\n\nSecond.\n\nThird**.", detail: dragResult.debugDescription)
        _ = await evaluate("window.margin.loadDocument({text:\(json(selectSource)),name:'geometry.md',dirty:false})")
        check("paragraphs and their separators are contiguous visible rows", await evaluate("(() => { const lines = [...document.querySelectorAll('.cm-content > .cm-line')]; return lines.length === 5 && lines.every((line, i) => line.getBoundingClientRect().height > 10 && (!i || Math.abs(lines[i - 1].getBoundingClientRect().bottom - line.getBoundingClientRect().top) < 1)); })()") as? Bool == true)
        _ = await evaluate("window.clickWord('Second'); window.clickWord('Second',false,2); window.margin.command('bold');")
        let repeatedClick = await evaluate("window.margin.getText()") as? String
        check("second click after revealing text selects the same paragraph", repeatedClick == "First.\n\n**Second**.\n\nThird.", detail: repeatedClick.debugDescription)
        _ = await evaluate("window.margin.loadDocument({text:'- item',name:'list.md',dirty:false}); window.margin.command('selectAll'); document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowRight',bubbles:true,cancelable:true})); document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true,cancelable:true}));")
        check("Enter continues a Markdown list", await evaluate("window.margin.getText()") as? String == "- item\n- ")
        _ = await evaluate("document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true,cancelable:true}));")
        check("Enter on an empty list item exits the list", await evaluate("window.margin.getText()") as? String == "- item\n")
        _ = await evaluate("window.margin.loadDocument({text:'One\\n\\nTwo',name:'delete.md',dirty:false}); window.margin.command('selectAll'); document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowRight',bubbles:true,cancelable:true})); document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'Home',bubbles:true,cancelable:true})); for(let i=0;i<2;i++) document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'Backspace',bubbles:true,cancelable:true}));")
        check("Backspace joins paragraphs without losing text", await evaluate("window.margin.getText()") as? String == "OneTwo")
        _ = await evaluate("window.margin.command('undo')")
        check("undo restores deleted paragraph breaks", await evaluate("window.margin.getText()") as? String == "One\n\nTwo")
        finish()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        check("navigation", false, detail: error.localizedDescription); finish()
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        check("provisional navigation", false, detail: error.localizedDescription); finish()
    }

    func finish() {
        guard !finished else { return }
        finished = true
        try? FileManager.default.removeItem(at: assetsRoot)
        let passed = checks.allSatisfy { $0["passed"] as? Bool == true }
        var hashes: [String: String] = [:]
        if let files = FileManager.default.enumerator(at: webRoot, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let url as URL in files {
                if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                   let data = try? Data(contentsOf: url) {
                    hashes[String(url.path.dropFirst(webRoot.path.count + 1))] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                }
            }
        }
        let result: [String: Any] = [
            "passed": passed, "started": ISO8601DateFormatter().string(from: started),
            "elapsedSeconds": Date().timeIntervalSince(started),
            "webRoot": webRoot.path, "checks": checks, "messages": messages,
            "webAssetSHA256": hashes, "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "invocation": CommandLine.arguments
        ]
        do { try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic) }
        catch { fputs("Could not save result: \(error)\n", stderr); exit(2) }
        print("\(checks.filter { $0["passed"] as? Bool == true }.count)/\(checks.count) WKWebView checks passed")
        exit(passed ? 0 : 1)
    }
}
