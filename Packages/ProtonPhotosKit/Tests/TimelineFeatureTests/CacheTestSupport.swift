import Foundation

func timelineFeatureTestCacheRoot(_ prefix: String = "cache") -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ProtonPhotosKit-\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}
