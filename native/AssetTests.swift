import Foundation

@main struct AssetTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("margin-assets-\(UUID().uuidString)")
        let directory = root.appendingPathComponent("document")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("images"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let document = directory.appendingPathComponent("note.md")
        let image = directory.appendingPathComponent("images/café picture.SVG")
        try Data("<svg xmlns='http://www.w3.org/2000/svg'/>".utf8).write(to: image)
        let outside = root.appendingPathComponent("outside.svg")
        try Data("<svg/>".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("escape.svg"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("inside.svg"), withDestinationURL: image)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("linked"), withDestinationURL: root)
        let text = directory.appendingPathComponent("secret.txt")
        try Data("not an image".utf8).write(to: text)
        var count = 0
        func request(_ path: String) -> URL {
            var components = URLComponents(string: "margin-asset://document/")!
            components.queryItems = [URLQueryItem(name: "path", value: path)]
            return components.url!
        }
        func accept(_ path: String, _ name: String) throws {
            let asset = try DocumentAsset.resolve(request(path), documentURL: document)
            precondition(asset.mime == "image/svg+xml" && asset.url == image.resolvingSymlinksInPath())
            count += 1; print("PASS: \(name)")
        }
        func denyURL(_ url: URL, _ name: String, documentURL: URL? = nil) throws {
            do { _ = try DocumentAsset.resolve(url, documentURL: documentURL ?? document); fatalError("FAIL: \(name)") }
            catch { count += 1; print("PASS: \(name)") }
        }
        try accept("images/café picture.SVG", "nested Unicode and spaces resolve with SVG MIME")
        try accept("./images/café picture.SVG", "current-directory prefix resolves")
        try accept("inside.svg", "symlink to an image within document directory resolves")
        // Images outside the document's folder load, as in other Markdown editors.
        func acceptOutside(_ path: String, _ name: String, documentURL: URL? = nil) throws {
            let asset = try DocumentAsset.resolve(request(path), documentURL: documentURL ?? document)
            precondition(asset.mime == "image/svg+xml" && asset.url == outside.resolvingSymlinksInPath())
            count += 1; print("PASS: \(name)")
        }
        try acceptOutside("../outside.svg", "parent-folder image resolves")
        try acceptOutside("images/../../outside.svg", "nested parent traversal resolves")
        try acceptOutside(outside.path, "absolute image path resolves")
        try acceptOutside(outside.path, "absolute image path resolves for untitled documents", documentURL: URL(fileURLWithPath: "/nonexistent/untitled"))
        try acceptOutside("escape.svg", "symlink to an image elsewhere resolves")
        try acceptOutside("linked/outside.svg", "image through a linked folder resolves")
        let textLink = directory.appendingPathComponent("disguised.svg")
        try FileManager.default.createSymbolicLink(at: textLink, withDestinationURL: text)
        for path in ["https://example.com/a.svg", "file:///tmp/a.svg", "//server/share.svg", "images\\a.svg", "secret.txt", "../document/secret.txt", text.path, "disguised.svg", "missing.png", "../missing.png", "images", "", "a\0.svg"] {
            try denyURL(request(path), "reject \(path.debugDescription)")
        }
        try acceptOutside("%2e%2e%2foutside.svg".removingPercentEncoding!, "percent-decoded parent path resolves")
        try denyURL(URL(string: "margin-asset://document/?path=images/a.svg&path=secret.txt")!, "ambiguous duplicate path rejected")
        try denyURL(URL(string: "margin-asset://document/?path=inside.svg&x=1")!, "unknown query items rejected")
        var versioned = URLComponents(string: "margin-asset://document/")!
        versioned.queryItems = [URLQueryItem(name: "path", value: "images/café picture.SVG"), URLQueryItem(name: "v", value: "3")]
        let versionedAsset = try DocumentAsset.resolve(versioned.url!, documentURL: document)
        precondition(versionedAsset.url == image.resolvingSymlinksInPath())
        count += 1; print("PASS: a reload token does not change the image path")
        // Images that appear or change after being requested are noticed.
        let handler = DocumentAssetHandler(file: MarkdownFile())
        let note = directory.appendingPathComponent("note.md")
        try Data("x".utf8).write(to: note)
        handler.file = try MarkdownFile(contentsOf: note)
        handler.note(request("later.png"))
        handler.note(request("images/café picture.SVG"))
        precondition(!handler.imagesChanged())
        count += 1; print("PASS: unchanged images report no change")
        try Data("png".utf8).write(to: directory.appendingPathComponent("later.png"))
        precondition(handler.imagesChanged() && !handler.imagesChanged())
        count += 1; print("PASS: an image created after its request is noticed once")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: image.path)
        precondition(handler.imagesChanged())
        count += 1; print("PASS: an image rewritten in place is noticed")
        try denyURL(URL(string: "margin-asset://other/?path=inside.svg")!, "other host rejected")
        try denyURL(URL(string: "margin-asset://document/inside.svg?path=inside.svg")!, "noncanonical request path rejected")
        try denyURL(URL(string: "margin-asset://document/?path=inside.svg#fragment")!, "scheme fragments rejected")
        try denyURL(URL(string: "margin-asset://name@document/?path=inside.svg")!, "userinfo rejected")
        do { _ = try DocumentAsset.resolve(request("inside.svg"), documentURL: nil); fatalError("FAIL: untitled document") }
        catch { count += 1; print("PASS: untitled document cannot resolve relative images") }
        print("\(count) asset checks passed")
    }
}
