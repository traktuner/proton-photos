import Foundation

/// Lightweight file logger for local debugging. Disabled by default because the messages can contain local
/// filenames, node IDs, or API paths. Enable only for a deliberate Debug run with
/// `PROTONPHOTOS_DEBUG_LOG=1`; Release never writes this log.
public enum DebugLog {
    private static let queue = DispatchQueue(label: "protonphotos.debuglog")
    private static let url: URL = {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("ProtonPhotos", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        return logs.appendingPathComponent("protonphotos.log")
    }()

    public static func log(_ message: String) {
        guard enabled else { return }
        let line = "\(Date().formatted(date: .omitted, time: .standard)) \(message)\n"
        queue.async {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? line.data(using: .utf8)?.write(to: url)
            }
        }
    }

    private static var enabled: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["PROTONPHOTOS_DEBUG_LOG"] == "1"
        #else
        return false
        #endif
    }
}
