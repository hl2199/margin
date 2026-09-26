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
        let resolved = try candidate(request, documentURL: documentURL)
        guard let mime = imageTypes[resolved.pathExtension.lowercased()],
              (try? resolved.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { throw denied }
        return (resolved, mime)
    }

    /// The image file a request names, whether or not it exists yet. A `v` item
    /// is a reload token from the page and does not affect the path.
    static func candidate(_ request: URL, documentURL: URL?) throws -> URL {
        guard let components = URLComponents(url: request, resolvingAgainstBaseURL: false),
              components.scheme == "margin-asset", components.host == "document",
              components.user == nil, components.password == nil, components.port == nil,
              components.path == "/", components.fragment == nil,
              let query = components.queryItems, query.filter({ $0.name == "path" }).count == 1,
              query.allSatisfy({ $0.name == "path" || $0.name == "v" }), query.count <= 2,
              let path = query.first(where: { $0.name == "path" })?.value, !path.isEmpty,
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
        guard imageTypes[resolved.pathExtension.lowercased()] != nil else { throw denied }
        return resolved
    }
}

final class DocumentAssetHandler: NSObject, WKURLSchemeHandler {
    var file: MarkdownFile
    /// Every image file the page asked for, with its modification date when it
    /// was served (nil if it did not exist), so later changes can be noticed.
    private var requested: [URL: Date?] = [:]
    init(file: MarkdownFile) { self.file = file }

    /// Read from the file system each time: URL resource values are cached per URL.
    private static func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// True if any requested image has appeared, disappeared or changed since
    /// it was last served. Cheap enough to poll: one file-date lookup per image.
    func imagesChanged() -> Bool {
        var changed = false
        for (url, date) in requested where DocumentAssetHandler.modified(url) != date {
            requested[url] = DocumentAssetHandler.modified(url)
            changed = true
        }
        return changed
    }

    /// Remembers the image file a request names and its current modification date.
    func note(_ request: URL) {
        if let url = try? DocumentAsset.candidate(request, documentURL: file.url) { requested[url] = DocumentAssetHandler.modified(url) }
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        do {
            guard let request = urlSchemeTask.request.url else { throw DocumentAsset.denied }
            note(request)
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
