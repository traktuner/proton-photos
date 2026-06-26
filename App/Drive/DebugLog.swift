import Foundation

/// Lightweight file logger for local debugging. Disabled by default because the messages can contain local
/// filenames, node IDs, or API paths. Enable only for a deliberate Debug run with
/// `PROTONPHOTOS_DEBUG_LOG=1`; Release never writes this log.
enum DebugLog {
    private static let url = URL(fileURLWithPath: "/tmp/protonphotos.log")
    private static let queue = DispatchQueue(label: "protonphotos.debuglog")

    static func log(_ message: String) {
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
