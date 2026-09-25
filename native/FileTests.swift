import Foundation

@main struct FileTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("margin-file-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var checks = 0
        func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
            guard try value() else { fatalError("FAIL: \(message)") }
            checks += 1
            print("PASS: \(message)")
        }
        for (name, source) in [
            ("lf", Data("# Title\n\nUnicode: café 📝\n".utf8)),
            ("crlf", Data("# Title\r\n\r\nUnicode: café 📝\r\n".utf8)),
            ("cr", Data("# Title\r\rUnicode: café 📝\r".utf8)),
            ("bom", Data([0xef, 0xbb, 0xbf]) + Data("# Title\r\ntext\r\n".utf8)),
            ("mixed", Data("one\r\ntwo\nthree\r".utf8))
        ] {
            let url = root.appendingPathComponent("\(name).md")
            try source.write(to: url)
            let document = try MarkdownFile(contentsOf: url)
            try check(!document.isDirty, "\(name): opened pristine")
            try check(!document.text.contains("\r"), "\(name): editor uses LF")
            try document.save(to: url, text: document.text)
            try check(try Data(contentsOf: url) == source, "\(name): no-op save is byte identical")
            document.text += "added\n"
            try check(document.isDirty, "\(name): edit sets dirty")
            document.text = document.savedText
            try check(!document.isDirty, "\(name): undo clears dirty")
            document.text += "added\n"
            try document.save(to: url, text: document.text)
            let saved = try Data(contentsOf: url)
            if name == "crlf" || name == "bom" {
                try check(saved.suffix(7) == Data("added\r\n".utf8), "\(name): edited save keeps CRLF")
            }
            if name == "bom" { try check(saved.starts(with: [0xef, 0xbb, 0xbf]), "BOM preserved after editing") }
            if name == "cr" { try check(saved.suffix(6) == Data("added\r".utf8), "CR preserved after editing") }
            let reopened = try MarkdownFile(contentsOf: url)
            try check(reopened.text == document.text, "\(name): reopened text matches edited text")
            try check(!document.isDirty, "\(name): save clears dirty")
        }
        let url = root.appendingPathComponent("conflict.md")
        try Data("initial\n".utf8).write(to: url)
        let document = try MarkdownFile(contentsOf: url)
        document.text = "our edits\n"
        try Data("external edits\n".utf8).write(to: url)
        do {
            try document.save(to: url, text: document.text)
            fatalError("FAIL: external edit was overwritten")
        } catch MarkdownFile.FileError.changedOnDisk { print("PASS: external edit refused"); checks += 1 }
        try check(try Data(contentsOf: url) == Data("external edits\n".utf8), "external bytes remain untouched")
        try check(document.isDirty, "failed save retains dirty state")
        let copy = root.appendingPathComponent("copy.md")
        try document.save(to: copy, text: document.text)
        try check(try Data(contentsOf: copy) == Data("our edits\n".utf8), "Save As keeps edits")
        try check(try Data(contentsOf: url) == Data("external edits\n".utf8), "Save As keeps external version")
        try FileManager.default.removeItem(at: copy)
        try check(document.changedOnDisk(), "external deletion detected")
        try document.save(to: copy, text: document.text, replacingExternalChanges: true)
        try check(!document.changedOnDisk(), "explicit replacement restores disk baseline")
        let invalid = root.appendingPathComponent("invalid.md")
        try Data([0xff, 0xfe, 0x00]).write(to: invalid)
        do {
            _ = try MarkdownFile(contentsOf: invalid)
            fatalError("FAIL: invalid UTF-8 accepted")
        } catch MarkdownFile.FileError.notUTF8 { print("PASS: invalid UTF-8 refused"); checks += 1 }
        let untitled = MarkdownFile()
        untitled.text = "new text\n"
        try untitled.save(to: root.appendingPathComponent("new.md"), text: untitled.text)
        try check(!untitled.isDirty && untitled.name == "new.md", "new document save assigns identity")
        untitled.text = "newer text\n"
        try untitled.save(to: untitled.url!, text: "new text\n")
        try check(untitled.isDirty, "editing newer than saved snapshot stays dirty")
        let previousURL = untitled.url
        do {
            try untitled.save(to: root.appendingPathComponent("missing/fail.md"), text: untitled.text)
            fatalError("FAIL: save into missing parent unexpectedly succeeded")
        } catch {
            try check(untitled.isDirty && untitled.url == previousURL, "failed Save As preserves dirty state and identity")
        }
        let emptyURL = root.appendingPathComponent("empty.md")
        try Data().write(to: emptyURL)
        let empty = try MarkdownFile(contentsOf: emptyURL)
        try check(empty.text.isEmpty && !empty.isDirty, "empty UTF-8 document opens")
        let link = root.appendingPathComponent("linked.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: emptyURL)
        let linked = try MarkdownFile(contentsOf: link)
        linked.text = "via link\n"
        try linked.save(to: linked.url!, text: linked.text)
        try check(try String(contentsOf: emptyURL, encoding: .utf8) == "via link\n", "symlink opens and saves target")
        print("\(checks) native file checks passed")
    }
}
