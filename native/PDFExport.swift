import AppKit
import WebKit

/// Prints a document to PDF from Margin's own editor, so the PDF looks exactly
/// as the document renders in the app. The editor page runs read-only in an
/// offscreen, light-appearance web view that is grown until every line is drawn
/// (the editor draws only what fits its window), then the macOS print system
/// paginates it. The exporter keeps itself alive until printing finishes.
final class PDFExporter: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    private let webView: WKWebView
    private let window: NSWindow
    private let assets: DocumentAssetHandler
    private let payload: [String: Any]
    private let destination: URL
    private weak var parent: NSWindow?
    private let printInfo: NSPrintInfo
    private var completion: ((Error?) -> Void)?
    private var keepAlive: PDFExporter?

    init(file: MarkdownFile, destination: URL, parent: NSWindow, completion: @escaping (Error?) -> Void) {
        self.destination = destination
        self.parent = parent
        self.completion = completion
        payload = ["text": file.text, "path": file.url?.path ?? ""]
        printInfo = NSPrintInfo.shared.copy() as! NSPrintInfo
        printInfo.topMargin = 54; printInfo.bottomMargin = 54; printInfo.leftMargin = 54; printInfo.rightMargin = 54
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic
        printInfo.isHorizontallyCentered = false
        printInfo.isVerticallyCentered = false
        printInfo.jobDisposition = .save
        printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = destination
        // Lay out at the printable width so line breaks match the page.
        let width = printInfo.paperSize.width - printInfo.leftMargin - printInfo.rightMargin
        let frame = NSRect(x: 0, y: 0, width: width, height: 4000)
        assets = DocumentAssetHandler(file: file)
        let configuration = WKWebViewConfiguration()
        // Code and table shading are backgrounds, which printing drops by default.
        if #available(macOS 13.3, *) { configuration.preferences.shouldPrintBackgrounds = true }
        configuration.setURLSchemeHandler(assets, forURLScheme: "margin-asset")
        webView = WKWebView(frame: frame, configuration: configuration)
        webView.appearance = NSAppearance(named: .aqua)
        // About 11 pt body text, with line lengths close to the app's column.
        webView.pageZoom = 0.8
        window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        configuration.userContentController.add(self, name: "margin")
        webView.navigationDelegate = self
        window.contentView = webView
        keepAlive = self
        if let web = Bundle.main.resourceURL?.appendingPathComponent("web") {
            var page = URLComponents(url: web.appendingPathComponent("index.html").absoluteURL, resolvingAgainstBaseURL: false)!
            page.query = "print"
            webView.loadFileURL(page.url!, allowingReadAccessTo: web)
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        guard type == "ready" else { return }
        Task { @MainActor in
            do {
                var height = try await layout("return await window.margin.printDocument(payload)", ["payload": payload])
                // Grow the page until it holds the whole document, so every line is drawn.
                for _ in 0..<20 where height > webView.frame.height - 100 {
                    setHeight(height + 4000)
                    height = try await layout("return await window.margin.printLayout()")
                }
                height = try await layout("return await window.margin.printAssets()")
                setHeight(height)
                print()
            } catch { finish(error) }
        }
    }

    @MainActor private func layout(_ script: String, _ arguments: [String: Any] = [:]) async throws -> CGFloat {
        let value = try await webView.callAsyncJavaScript(script, arguments: arguments, contentWorld: .page)
        return CGFloat((value as? NSNumber)?.doubleValue ?? 0) * webView.pageZoom
    }

    private func setHeight(_ height: CGFloat) {
        let frame = NSRect(x: 0, y: 0, width: webView.frame.width, height: max(height, 100))
        window.setContentSize(frame.size)
        webView.frame = frame
    }

    private func print() {
        let operation = webView.printOperation(with: printInfo)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        operation.view?.frame = webView.bounds
        guard let parent else { finish(NSError(domain: "Margin", code: 3)); return }
        operation.runModal(for: parent, delegate: self, didRun: #selector(printed(_:success:contextInfo:)), contextInfo: nil)
    }

    @objc private func printed(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        finish(success ? nil : NSError(domain: "Margin", code: 4, userInfo: [NSLocalizedDescriptionKey: "The PDF could not be written."]))
    }

    private func finish(_ error: Error?) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "margin")
        completion?(error)
        completion = nil
        keepAlive = nil
    }

    // Only the bundled print page may load; nothing in a document can navigate it.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let page = Bundle.main.resourceURL?.appendingPathComponent("web/index.html").standardizedFileURL.path
        decisionHandler(navigationAction.request.url?.standardizedFileURL.path == page ? .allow : .cancel)
    }
}
