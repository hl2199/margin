import AppKit

/// Images pasted or dropped into a document. They live in an `assets` folder
/// beside the document; an image already inside the document's folder is linked
/// where it is, and one from elsewhere is copied in so the document stays
/// self-contained.
enum DocumentImages {
    static let folderName = "assets"

    static func isImage(_ url: URL) -> Bool { DocumentAsset.imageTypes[url.pathExtension.lowercased()] != nil }

    /// Link paths (relative to the document, URL-encoded) for image files.
    static func links(for files: [URL], document: URL) throws -> [String] {
        let directory = document.resolvingSymlinksInPath().deletingLastPathComponent().standardizedFileURL
        return try files.map { file in
            let source = file.resolvingSymlinksInPath().standardizedFileURL
            if source.path.hasPrefix(directory.path + "/") { return encode(String(source.path.dropFirst(directory.path.count + 1))) }
            let destination = try unusedURL(named: source.lastPathComponent, in: assetsFolder(for: directory))
            try FileManager.default.copyItem(at: source, to: destination)
            return encode("\(folderName)/\(destination.lastPathComponent)")
        }
    }

    /// Saves image data (converted to PNG if needed) as a new pasted image.
    static func save(_ data: Data, document: URL, date: Date = Date()) throws -> String {
        let png: Data
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { png = data }
        else if let rep = NSBitmapImageRep(data: data), let converted = rep.representation(using: .png, properties: [:]) { png = converted }
        else { throw NSError(domain: "Margin", code: 5, userInfo: [NSLocalizedDescriptionKey: "The pasted image could not be read."]) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        let directory = document.resolvingSymlinksInPath().deletingLastPathComponent().standardizedFileURL
        let destination = try unusedURL(named: "Pasted image \(formatter.string(from: date)).png", in: assetsFolder(for: directory))
        try png.write(to: destination, options: .atomic)
        return encode("\(folderName)/\(destination.lastPathComponent)")
    }

    /// Image files on a pasteboard (e.g. copied in Finder), or nil if there are none
    /// or any item is not an image.
    static func files(on pasteboard: NSPasteboard) -> [URL]? {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return !urls.isEmpty && urls.allSatisfy(isImage) ? urls : nil
    }

    /// Image data on a pasteboard that has no text (a screenshot, an image copied in
    /// Preview or a browser). Text wins, so copying rich text still pastes text.
    static func data(on pasteboard: NSPasteboard) -> Data? {
        guard pasteboard.string(forType: .string) == nil, files(on: pasteboard) == nil else { return nil }
        return pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff)
    }

    private static func assetsFolder(for directory: URL) throws -> URL {
        let folder = directory.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// `name`, or `name 2`, `name 3`… if a file with that name already exists.
    private static func unusedURL(named name: String, in folder: URL) throws -> URL {
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)")
            number += 1
        }
        return candidate
    }

    /// A Markdown link destination: spaces, brackets and other unsafe characters
    /// percent-encoded, path separators kept.
    static func encode(_ path: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "()<> ")
        return path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
    }
}
