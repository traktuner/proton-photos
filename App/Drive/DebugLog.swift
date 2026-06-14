import Foundation

/// Lightweight file logger for local debugging. Appends to /tmp/protonphotos.log so runtime
/// flow is observable without the GUI/unified-log. (Dev-only; remove before release.)
enum DebugLog {
    private static let url = URL(fileURLWithPath: "/tmp/protonphotos.log")
    private static let queue = DispatchQueue(label: "protonphotos.debuglog")

    static func log(_ message: String) {
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
}
