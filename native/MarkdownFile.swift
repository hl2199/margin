import Foundation

/// Disk bytes and editor text have separate identities: the editor uses LF, while
/// saves preserve a file's UTF-8 BOM and original (uniform) newline convention.
final class MarkdownFile {
    enum FileError: LocalizedError {
        case notUTF8, changedOnDisk
        var errorDescription: String? {
            switch self {
            case .notUTF8: return "This file is not valid UTF-8. Convert it to UTF-8 before opening it in Margin."
            case .changedOnDisk: return "This file changed outside Margin after it was opened or saved."
            }
        }
    }

    /// Extensions Margin opens as documents, matching CFBundleDocumentTypes.
    static let documentExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "txt"]

    private(set) var url: URL?
    private(set) var savedText: String
    private var diskBytes: Data?
    private var hasBOM = false
    private var newline = "\n"
    var text: String
    var isDirty: Bool { text != savedText }
    var name: String { url?.lastPathComponent ?? "Untitled.md" }

    init(text: String = "") {
        self.text = text
        self.savedText = text
    }

    convenience init(contentsOf url: URL) throws {
        self.init()
        let data = try Data(contentsOf: url)
        hasBOM = data.starts(with: [0xef, 0xbb, 0xbf])
        let payload = hasBOM ? data.dropFirst(3) : data[...]
        guard let decoded = String(data: payload, encoding: .utf8) else { throw FileError.notUTF8 }
        if let first = decoded.firstIndex(where: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }) {
            newline = String(decoded[first])
        }
        text = decoded.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        savedText = text
        diskBytes = data
        self.url = url.resolvingSymlinksInPath().standardizedFileURL
    }

    func changedOnDisk() -> Bool {
        guard let url, let diskBytes else { return false }
        return (try? Data(contentsOf: url)) != diskBytes
    }

    func save(to destination: URL, text snapshot: String, replacingExternalChanges: Bool = false) throws {
        let canonical = destination.resolvingSymlinksInPath().standardizedFileURL
        if canonical == url && !replacingExternalChanges && changedOnDisk() { throw FileError.changedOnDisk }
        // A no-op save retains byte-for-byte fidelity, including mixed newlines.
        let data: Data
        if snapshot == savedText, let original = diskBytes {
            data = original
        } else {
            var bytes = Data()
            if hasBOM { bytes.append(contentsOf: [0xef, 0xbb, 0xbf]) }
            bytes.append(Data(snapshot.replacingOccurrences(of: "\n", with: newline).utf8))
            data = bytes
        }
        try data.write(to: canonical, options: .atomic)
        url = canonical
        savedText = snapshot
        diskBytes = data
    }
}
