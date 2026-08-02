import Darwin
import Foundation

@MainActor
enum SingleInstanceLock {
    private static var lockFileDescriptor: CInt = -1
    private static let directoryPermissions: NSNumber = 0o700
    private static let lockFilePermissions: mode_t = S_IRUSR | S_IWUSR

    static func acquire() -> Bool {
        guard lockFileDescriptor < 0 else {
            return true
        }

        let lockURL = lockFileURL()
        hardenLockDirectory(lockURL.deletingLastPathComponent())

        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, lockFilePermissions)
        guard descriptor >= 0 else {
            AppLog.app.error("Unable to open single-instance lock file")
            return true
        }
        fchmod(descriptor, lockFilePermissions)

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return false
        }

        lockFileDescriptor = descriptor
        writeCurrentProcessIdentifier(to: descriptor)
        return true
    }

    static func release() {
        guard lockFileDescriptor >= 0 else {
            return
        }

        flock(lockFileDescriptor, LOCK_UN)
        close(lockFileDescriptor)
        lockFileDescriptor = -1
    }

    private static func lockFileURL() -> URL {
        if let applicationSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first {
            return applicationSupportURL
                .appendingPathComponent("Perch", isDirectory: true)
                .appendingPathComponent("Perch.lock")
        }

        return FileManager.default.temporaryDirectory.appendingPathComponent("com.jurajkrivda.perch.lock")
    }

    private static func hardenLockDirectory(_ directoryURL: URL) {
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: directoryPermissions]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: directoryPermissions],
                ofItemAtPath: directoryURL.path
            )
        } catch {
            AppLog.app.error("Unable to harden single-instance lock directory: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func writeCurrentProcessIdentifier(to descriptor: CInt) {
        let processIdentifier = "\(ProcessInfo.processInfo.processIdentifier)\n"
        ftruncate(descriptor, 0)
        lseek(descriptor, 0, SEEK_SET)
        _ = processIdentifier.withCString { pointer in
            write(descriptor, pointer, strlen(pointer))
        }
    }
}
