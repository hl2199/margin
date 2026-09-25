import Foundation
import WebKit

enum DocumentAsset {
    static let imageTypes = [
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
        "gif": "image/gif", "webp": "image/webp", "avif": "image/avif",
        "svg": "image/svg+xml", "ico": "image/x-icon", "bmp": "image/bmp",
        "tif": "image/tiff", "tiff": "image/tiff", "heic": "image/heic", "heif": "image/heif"
    ]
    static var denied: NSError {
        NSError(domain: NSURLErrorDomain, code: NSURLErrorNoPermissionsToReadFile,
                userInfo: [NSLocalizedDescriptionKey: "This document image is unavailable."])
    }

    /// Query values are percent-decoded once by URLComponents. The value is a
    /// filesystem path: absolute, or relative to the document's folder (`..`
    /// allowed, as in other Markdown editors). Only image files are served, and
    /// the page has no network access, so an image is only ever shown locally.
    static func resolve(_ request: URL, documentURL: URL?) throws -> (url: URL, mime: String) {
        guard let components = URLComponents(url: request, resolvingAgainstBaseURL: false),
              components.scheme == "margin-asset", components.host == "document",
              components.user == nil, components.password == nil, components.port == nil,
              components.path == "/", components.fragment == nil,
              let query = components.queryItems, query.count == 1,
              query[0].name == "path", let path = query[0].value, !path.isEmpty,
              !path.hasPrefix("//"), !path.contains("\\"), !path.contains("\0"),
              URL(string: path)?.scheme == nil else { throw denied }
        let asset: URL
        if path.hasPrefix("/") { asset = URL(fileURLWithPath: path) }
        else {
            // Relative paths need a saved document to resolve against.
            guard let documentURL, documentURL.isFileURL else { throw denied }
            asset = documentURL.resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent(path)
        }
        let resolved = asset.resolvingSymlinksInPath().standardizedFileURL
        guard let mime = imageTypes[resolved.pathExtension.lowercased()],
              (try? resolved.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { throw denied }
        return (resolved, mime)
    }
}

final class DocumentAssetHandler: NSObject, WKURLSchemeHandler {
    var file: MarkdownFile
    init(file: MarkdownFile) { self.file = file }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        do {
            guard let request = urlSchemeTask.request.url else { throw DocumentAsset.denied }
            let asset = try DocumentAsset.resolve(request, documentURL: file.url)
            let data = try Data(contentsOf: asset.url)
            urlSchemeTask.didReceive(URLResponse(url: request, mimeType: asset.mime,
                                                expectedContentLength: data.count, textEncodingName: nil))
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } catch { urlSchemeTask.didFailWithError(DocumentAsset.denied) }
    }

    // Requests are handled synchronously and have no outstanding operation to stop.
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}
