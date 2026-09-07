import Darwin
import Foundation

@MainActor
final class ProcessFileLock {
    private var lockFileDescriptor: CInt = -1
    private let directoryPermissions: NSNumber = 0o700
    private let lockFilePermissions: mode_t = S_IRUSR | S_IWUSR

    func acquire(at lockURL: URL) -> Bool {
        guard lockFileDescriptor < 0 else {
            return true
        }

        hardenLockDirectory(lockURL.deletingLastPathComponent())

        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, lockFilePermissions)
        guard descriptor >= 0 else {
            AppLog.app.error("Unable to open single-instance lock file; refusing an unprotected launch")
            return false
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

    deinit {
        if lockFileDescriptor >= 0 {
            flock(lockFileDescriptor, LOCK_UN)
            close(lockFileDescriptor)
        }
    }

    func release() {
        guard lockFileDescriptor >= 0 else {
            return
        }

        flock(lockFileDescriptor, LOCK_UN)
        close(lockFileDescriptor)
        lockFileDescriptor = -1
    }

    private func hardenLockDirectory(_ directoryURL: URL) {
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
            AppLog.app.error("Unable to harden single-instance lock directory: \(error.localizedDescription, privacy: .private)")
        }
    }

    private func writeCurrentProcessIdentifier(to descriptor: CInt) {
        let processIdentifier = "\(ProcessInfo.processInfo.processIdentifier)\n"
        ftruncate(descriptor, 0)
        lseek(descriptor, 0, SEEK_SET)
        _ = processIdentifier.withCString { pointer in
            write(descriptor, pointer, strlen(pointer))
        }
    }
}
