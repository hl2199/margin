import AppKit
import Darwin

/// Keep one editor process per user and bundle identifier, including app copies.
/// Construct before creating windows; only `isPrimary` may become a regular app.
final class SingleInstanceRouter {
    let isPrimary: Bool
    private let compatibleIdentifiers: [String]
    private var descriptor: Int32 = -1
    private var legacyTarget: NSRunningApplication?

    init(bundleIdentifier: String? = Bundle.main.bundleIdentifier, legacyBundleIdentifier: String? = nil) throws {
        guard let identifier = bundleIdentifier, !identifier.isEmpty else {
            throw Self.error("The app has no bundle identifier.")
        }
        // Retain the original lock and accept old builds after the app's
        // identity migration, so an existing editor keeps its unsaved work.
        let legacy = legacyBundleIdentifier ?? (identifier == "local.margin.desktop" ? "local.margin.editor" : nil)
        compatibleIdentifiers = [identifier] + (legacy.map { [$0] } ?? [])
        let coordinationIdentifier = legacy ?? identifier
        // NSTemporaryDirectory is private to the signed-in user. A persistent
        // inode is intentional: unlinking a held lock allows two owners.
        let safeName = coordinationIdentifier.utf8.map { String(format: "%02x", $0) }.joined()
        let path = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("margin-instance-\(safeName).lock").path
        descriptor = Darwin.open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw Self.error("Could not coordinate app launch: \(String(cString: strerror(errno)))") }
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            // Earlier builds do not hold our lock. Adopt an already-launched
            // copy, without terminating it or touching its unsaved documents.
            legacyTarget = compatibleIdentifiers.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
                .filter { $0.processIdentifier != getpid() && !$0.isTerminated && $0.isFinishedLaunching }
                .sorted { ($0.launchDate ?? .distantFuture, $0.processIdentifier) < ($1.launchDate ?? .distantFuture, $1.processIdentifier) }
                .first
            isPrimary = legacyTarget == nil
            if isPrimary {
                let data = Data("\(getpid())\n".utf8)
                guard ftruncate(descriptor, 0) == 0,
                      data.withUnsafeBytes({ pwrite(descriptor, $0.baseAddress, $0.count, 0) }) == data.count else {
                    Darwin.close(descriptor)
                    descriptor = -1
                    throw Self.error("Could not record the running app process.")
                }
            } else {
                flock(descriptor, LOCK_UN)
            }
        } else if errno == EWOULDBLOCK {
            isPrimary = false
        } else {
            let reason = String(cString: strerror(errno))
            Darwin.close(descriptor)
            descriptor = -1
            throw Self.error("Could not coordinate app launch: \(reason)")
        }
    }

    deinit { if descriptor >= 0 { Darwin.close(descriptor) } }

    /// Use standard open-document / reopen Apple events so older builds work.
    /// Success means Launch Services accepted the request; document loading and
    /// any resulting file error remain the receiving app's responsibility.
    func forward(urls: [URL], completion: @escaping (Result<Void, Error>) -> Void) {
        guard !isPrimary else { completion(.failure(Self.error("The primary app cannot redirect to itself."))); return }
        resolveTarget(until: Date().addingTimeInterval(5)) { result in
            switch result {
            case .failure(let error): completion(.failure(error))
            case .success(let target):
                guard let appURL = target.bundleURL else {
                    completion(.failure(Self.error("The running app's location is unavailable.")))
                    return
                }
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.createsNewApplicationInstance = false
                configuration.allowsRunningApplicationSubstitution = false
                configuration.activates = true
                let delivered: (NSRunningApplication?, Error?) -> Void = { app, error in
                    DispatchQueue.main.async {
                        if let error { completion(.failure(error)); return }
                        guard let app, app.processIdentifier != getpid(), self.compatibleIdentifiers.contains(app.bundleIdentifier ?? "") else {
                            completion(.failure(Self.error("The open request did not reach the running app.")))
                            return
                        }
                        completion(.success(()))
                    }
                }
                if urls.isEmpty {
                    NSWorkspace.shared.openApplication(at: appURL, configuration: configuration, completionHandler: delivered)
                } else {
                    NSWorkspace.shared.open(urls, withApplicationAt: appURL, configuration: configuration, completionHandler: delivered)
                }
            }
        }
    }

    private func resolveTarget(until deadline: Date, completion: @escaping (Result<NSRunningApplication, Error>) -> Void) {
        if let target = legacyTarget, !target.isTerminated { completion(.success(target)); return }
        var bytes = [UInt8](repeating: 0, count: 32)
        let count = pread(descriptor, &bytes, bytes.count, 0)
        if count > 0, let pid = Int32(String(decoding: bytes.prefix(Int(count)), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)),
           pid != getpid(), let target = NSRunningApplication(processIdentifier: pid),
           !target.isTerminated, compatibleIdentifiers.contains(target.bundleIdentifier ?? ""), target.bundleURL != nil {
            completion(.success(target))
            return
        }
        guard Date() < deadline else {
            completion(.failure(Self.error("The running Margin app could not be reached. Your files were not opened. Quit the other copy normally and try again.")))
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.resolveTarget(until: deadline, completion: completion) }
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "Margin.SingleInstance", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
