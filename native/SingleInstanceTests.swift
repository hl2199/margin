import AppKit

@main
struct SingleInstanceTests {
    static func main() throws {
        if CommandLine.arguments.contains("--unit") {
            let identifier = "local.margin.single-instance-test.\(UUID().uuidString)"
            var owner: SingleInstanceRouter? = try SingleInstanceRouter(bundleIdentifier: identifier)
            precondition(owner!.isPrimary, "first router must own lock")
            let second = try SingleInstanceRouter(bundleIdentifier: identifier)
            precondition(!second.isPrimary, "second router must redirect")
            owner = nil
            let successor = try SingleInstanceRouter(bundleIdentifier: identifier)
            precondition(successor.isPrimary, "closed owner releases lock even with stale PID file")
            do {
                _ = try SingleInstanceRouter(bundleIdentifier: nil)
                preconditionFailure("missing bundle identifier must fail")
            } catch {}
            print("PASS lock ownership, exclusion, release/stale PID, missing bundle identifier")
            return
        }
        let application = NSApplication.shared
        let delegate = TestDelegate()
        application.delegate = delegate
        application.setActivationPolicy(delegate.router?.isPrimary == false ? .accessory : .regular)
        application.run()
    }
}

final class TestDelegate: NSObject, NSApplicationDelegate {
    let router: SingleInstanceRouter?
    let log: URL
    override init() {
        router = ProcessInfo.processInfo.environment["MARGIN_TEST_LEGACY"] == "1" ? nil : try! SingleInstanceRouter(legacyBundleIdentifier: ProcessInfo.processInfo.environment["MARGIN_TEST_LEGACY_IDENTIFIER"])
        log = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MARGIN_TEST_LOG"]!)
        super.init()
    }
    func record(_ event: String) {
        let line = Data("\(getpid()) \(event)\n".utf8)
        let descriptor = Darwin.open(log.path, O_CREAT | O_WRONLY | O_APPEND, S_IRUSR | S_IWUSR)
        line.withUnsafeBytes { _ = Darwin.write(descriptor, $0.baseAddress, $0.count) }
        Darwin.close(descriptor)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        record("policy \(NSApp.activationPolicy().rawValue)")
        guard let router else { record("legacy-primary"); return }
        if router.isPrimary { record("primary"); return }
        record("duplicate")
        let paths = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        router.forward(urls: paths.map { URL(fileURLWithPath: $0) }) { result in
            switch result {
            case .success: self.record("forwarded"); exit(0)
            case .failure(let error): self.record("failure \(error.localizedDescription)"); exit(1)
            }
        }
    }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        for filename in filenames { record("open \(filename)") }
        sender.reply(toOpenOrPrint: .success)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        record("reopen")
        return false
    }
}
