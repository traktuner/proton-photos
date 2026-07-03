import Darwin
import Foundation

/// Process-wide gate for the macOS app shell.
///
/// Launch Services usually reuses a running app for normal opens, but `open -n` or launching a copied
/// binary can still create a second process. Keep a non-blocking advisory lock open for the lifetime of the
/// primary process so those duplicate launches terminate before creating UI or starting app work.
final class SingleInstanceGuard {
    private let lockURL: URL
    private var lockDescriptor: CInt = -1

    init(lockURL: URL = SingleInstanceGuard.defaultLockURL()) {
        self.lockURL = lockURL
    }

    deinit {
        if lockDescriptor >= 0 {
            flock(lockDescriptor, LOCK_UN)
            close(lockDescriptor)
        }
    }

    func acquire() -> Bool {
        if lockDescriptor >= 0 { return true }

        do {
            try FileManager.default.createDirectory(
                at: lockURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            NSLog("ProtonPhotos single-instance lock directory failed: \(error)")
            return false
        }

        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            NSLog("ProtonPhotos single-instance lock open failed: errno=\(errno)")
            return false
        }

        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            lockDescriptor = descriptor
            writeOwnerPID(to: descriptor)
            return true
        }

        let lockErrno = errno
        close(descriptor)
        if lockErrno == EWOULDBLOCK || lockErrno == EAGAIN {
            NSLog("ProtonPhotos duplicate launch ignored")
        } else {
            NSLog("ProtonPhotos single-instance lock failed: errno=\(lockErrno)")
        }
        return false
    }

    private func writeOwnerPID(to descriptor: CInt) {
        let text = "\(getpid())\n"
        _ = ftruncate(descriptor, 0)
        _ = text.withCString { pointer in
            write(descriptor, pointer, strlen(pointer))
        }
    }

    private static func defaultLockURL() -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        let namespace = Bundle.main.bundleIdentifier ?? "me.protonphotos.mac"
        return root
            .appendingPathComponent(namespace, isDirectory: true)
            .appendingPathComponent("Locks", isDirectory: true)
            .appendingPathComponent("single-instance.lock")
    }
}
