import AppKit
import WebKit
import CryptoKit

@main struct EditingLayoutTests {
    static var runner: EditingLayoutRunner!
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        runner = EditingLayoutRunner()
        app.run()
    }
}
final class EditingLayoutRunner: NSObject, WKScriptMessageHandler {
    let webRoot = URL(fileURLWithPath: CommandLine.arguments[1])
    let output = URL(fileURLWithPath: CommandLine.arguments[2])
    let harness = URL(fileURLWithPath: CommandLine.arguments[3])
    let view: WKWebView
    let window: NSWindow
    var began = false
    var finished = false
    var results: [[String: Any]] = []
    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        view = WKWebView(frame: NSRect(x: 0,y: 0,width: 640,height: 720), configuration: config)
        window = NSWindow(contentRect: view.frame, styleMask: [.titled,.resizable], backing: .buffered, defer: false)
        super.init()
        config.userContentController.add(self,name:"margin")
        view.pageZoom = 1.2
        window.contentView = view
        window.orderFront(nil)
        view.loadFileURL(webRoot.appendingPathComponent("index.html"), allowingReadAccessTo: webRoot)
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) { if !self.finished { self.results.append(["name":"suite completes before timeout","passed":false]);self.finish() } }
    }
    func userContentController(_ controller: WKUserContentController,didReceive message: WKScriptMessage) {
        guard let body=message.body as? [String:Any],body["type"] as? String == "ready", !began else {return}
        began=true
        Task { @MainActor in await run() }
    }
    @MainActor func js(_ code: String) async -> Any? {
        await withCheckedContinuation { continuation in
            view.evaluateJavaScript(code) { value,error in
                if let error { self.results.append(["name":"JavaScript evaluation","passed":false,"error":error.localizedDescription]) }
                continuation.resume(returning:value)
            }
        }
    }
    @MainActor func run() async {
        _ = await js(try! String(contentsOf:harness,encoding:.utf8))
        for (width,zoom) in [(640.0,1.2),(880.0,1.0)] {
            view.setFrameSize(NSSize(width:width,height:720))
            view.pageZoom=zoom
            _ = await js("window.layoutRun(\(width),\(zoom)).catch(error => { window.layoutResult = [{name: 'JavaScript harness error', passed: false, error: String(error)}]; }); void 0;")
            for _ in 0..<600 {
                if await js("(() => { if(window.layoutContinue){ const resume=window.layoutContinue;window.layoutContinue=null;resume(); } return window.layoutResult !== null; })()") as? Bool == true {break}
                if let name = await js("(() => { const name=window.layoutCapture;window.layoutCapture=null;return name??null; })()") as? String {
                    await capture(name + "-" + String(Int(width)))
                }
                try? await Task.sleep(nanoseconds:20_000_000)
            }
            if let batch=await js("window.layoutResult") as? [[String:Any]] { results.append(contentsOf:batch) }
            else {results.append(["name":"layout result returned","passed":false,"width":width,"zoom":zoom])}
        }
        finish()
    }
    @MainActor func capture(_ name: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            view.takeSnapshot(with: nil) { image, error in
                if let data=image?.tiffRepresentation, let bitmap=NSBitmapImageRep(data:data), let png=bitmap.representation(using:.png, properties:[:]) {
                    try? png.write(to:self.output.deletingLastPathComponent().appendingPathComponent(name + ".png"))
                } else { self.results.append(["name":"Snapshot " + name,"passed":false,"error":error?.localizedDescription ?? "No snapshot"]) }
                continuation.resume()
            }
        }
    }
    func finish() {
        guard !finished else{return};finished=true
        var hashes:[String:String]=[:]
        for url in (try? FileManager.default.contentsOfDirectory(at:webRoot,includingPropertiesForKeys:nil)) ?? [] {
            if let data=try? Data(contentsOf:url) {hashes[url.lastPathComponent]=SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
        }
        let passed=results.allSatisfy{$0["passed"] as? Bool == true}
        let payload:[String:Any]=["passed":passed,"checks":results,"webAssetSHA256":hashes,"os":ProcessInfo.processInfo.operatingSystemVersionString,"invocation":CommandLine.arguments]
        try! JSONSerialization.data(withJSONObject:payload,options:[.prettyPrinted,.sortedKeys]).write(to:output)
        for result in results { print("\(result["passed"] as? Bool == true ? "PASS":"FAIL"): \(result["name"] ?? "") [\(result["width"] ?? "") / \(result["zoom"] ?? "")]") }
        print("\(results.filter{$0["passed"] as? Bool == true}.count)/\(results.count) layout checks passed")
        exit(passed ? 0:1)
    }
}
