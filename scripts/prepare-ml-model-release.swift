#!/usr/bin/env swift

import CryptoKit
import Foundation

private struct Artifact: Encodable {
    let path: String
    let url: URL
    let sha256: String
    let bytes: Int64
    let source: URL

    enum CodingKeys: String, CodingKey { case path, url, sha256, bytes }
}

private struct Model: Encodable {
    let id: String
    let revision: String
    let artifacts: [Artifact]
}

private struct Catalog: Encodable {
    let schemaVersion = 1
    let models: [Model]
}

private struct Options {
    let privateKey: URL
    let output: URL
    let bucket: String
    let rcloneRemote: String
    let baseURL: URL
    let tinyCLIP: URL
    let sigLIP2: URL
}

private enum ReleaseError: Error, CustomStringConvertible {
    case usage
    case missing(URL)
    case invalidKey
    case invalidBaseURL

    var description: String {
        switch self {
        case .usage:
            return "Usage: prepare-ml-model-release.swift --private-key PATH --output DIR --bucket NAME --rclone-remote NAME --base-url https://host/models/ --tinyclip TinyCLIP.mlmodelc --siglip2 DIR"
        case .missing(let url): return "Missing required file: \(url.path)"
        case .invalidKey: return "The signing key must contain exactly 32 raw Ed25519 bytes"
        case .invalidBaseURL: return "--base-url must be an HTTPS URL ending in /models/"
        }
    }
}

private func parseOptions() throws -> Options {
    var values: [String: String] = [:]
    var index = 1
    while index + 1 < CommandLine.arguments.count {
        values[CommandLine.arguments[index]] = CommandLine.arguments[index + 1]
        index += 2
    }
    guard let key = values["--private-key"],
          let output = values["--output"],
          let bucket = values["--bucket"],
          let base = values["--base-url"],
          let baseURL = URL(string: base),
          let tiny = values["--tinyclip"],
          let siglip = values["--siglip2"] else { throw ReleaseError.usage }
    guard baseURL.scheme == "https", baseURL.absoluteString.hasSuffix("/models/") else {
        throw ReleaseError.invalidBaseURL
    }
    return Options(
        privateKey: URL(fileURLWithPath: key),
        output: URL(fileURLWithPath: output, isDirectory: true),
        bucket: bucket,
        rcloneRemote: values["--rclone-remote"] ?? "r2",
        baseURL: baseURL,
        tinyCLIP: URL(fileURLWithPath: tiny, isDirectory: true),
        sigLIP2: URL(fileURLWithPath: siglip, isDirectory: true)
    )
}

private func sha256(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
        hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

private func files(under root: URL) throws -> [URL] {
    guard FileManager.default.fileExists(atPath: root.path) else { throw ReleaseError.missing(root) }
    let keys: [URLResourceKey] = [.isRegularFileKey]
    guard let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: keys,
        options: [.skipsHiddenFiles]
    ) else { return [] }
    return try enumerator.compactMap { item -> URL? in
        guard let url = item as? URL,
              try url.resourceValues(forKeys: Set(keys)).isRegularFile == true else { return nil }
        return url
    }.sorted { $0.path < $1.path }
}

private func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

private func prepareModel(
    id: String,
    sources: [(root: URL, prefix: String)],
    individualFiles: [(file: URL, path: String)] = [],
    baseURL: URL
) throws -> (model: Model, uploads: [(source: URL, key: String, bytes: Int64)]) {
    var raw: [(path: String, source: URL, sha: String, bytes: Int64)] = []
    for source in sources {
        for file in try files(under: source.root) {
            let relative = String(file.path.dropFirst(source.root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let path = source.prefix.isEmpty ? relative : source.prefix + "/" + relative
            let values = try file.resourceValues(forKeys: [.fileSizeKey])
            raw.append((path, file, try sha256(file), Int64(values.fileSize ?? 0)))
        }
    }
    for item in individualFiles {
        guard FileManager.default.fileExists(atPath: item.file.path) else { throw ReleaseError.missing(item.file) }
        let values = try item.file.resourceValues(forKeys: [.fileSizeKey])
        raw.append((item.path, item.file, try sha256(item.file), Int64(values.fileSize ?? 0)))
    }
    raw.sort { $0.path < $1.path }
    let fingerprint = raw.map { "\($0.path):\($0.sha):\($0.bytes)" }.joined(separator: "\n")
    let revision = "r1-" + SHA256.hash(data: Data(fingerprint.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    let prefix = "\(id)/\(revision)/"
    let artifacts = raw.map { item in
        Artifact(
            path: item.path,
            url: baseURL.appendingPathComponent(prefix + item.path),
            sha256: item.sha,
            bytes: item.bytes,
            source: item.source
        )
    }
    return (
        Model(id: id, revision: revision, artifacts: artifacts),
        artifacts.map { ($0.source, "models/" + prefix + $0.path, $0.bytes) }
    )
}

do {
    let options = try parseOptions()
    let fm = FileManager.default
    let tinyModelName = options.tinyCLIP.lastPathComponent
    let tiny = try prepareModel(
        id: "tinyclip-vit-40m-32-text-19m",
        sources: [(options.tinyCLIP, tinyModelName)],
        baseURL: options.baseURL
    )

    let sigModel = options.sigLIP2.appendingPathComponent("SigLIP2.mlmodelc", isDirectory: true)
    let tokenizer = options.sigLIP2.appendingPathComponent("tokenizer.json")
    guard fm.fileExists(atPath: tokenizer.path) else { throw ReleaseError.missing(tokenizer) }
    let sig = try prepareModel(
        id: "siglip2-base-patch16-256",
        sources: [(sigModel, "SigLIP2.mlmodelc")],
        individualFiles: [(tokenizer, "tokenizer.json")],
        baseURL: options.baseURL
    )

    try fm.createDirectory(at: options.output, withIntermediateDirectories: true)
    let catalog = Catalog(models: [sig.model, tiny.model])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let catalogData = try encoder.encode(catalog)

    let keyData = try Data(contentsOf: options.privateKey)
    guard keyData.count == 32,
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: keyData) else {
        throw ReleaseError.invalidKey
    }
    let signature = try key.signature(for: catalogData)
    let catalogURL = options.output.appendingPathComponent("catalog-v1.json")
    let signatureURL = options.output.appendingPathComponent("catalog-v1.sig")
    try catalogData.write(to: catalogURL, options: .atomic)
    try signature.write(to: signatureURL, options: .atomic)

    let uploads = (tiny.uploads + sig.uploads).sorted(by: { $0.key < $1.key })
    var commands = ["#!/bin/zsh", "set -euo pipefail", ""]
    if uploads.contains(where: { $0.bytes > 300 * 1_024 * 1_024 }) {
        commands.append("command -v rclone >/dev/null || { echo 'rclone is required for artifacts larger than 300 MiB' >&2; exit 1; }")
        commands.append("rclone lsd \(shellQuote(options.rcloneRemote + ":" + options.bucket)) --max-depth 1 >/dev/null || { echo 'rclone remote is missing valid R2 credentials' >&2; exit 1; }")
        commands.append("")
    }
    for upload in uploads {
        if upload.bytes > 300 * 1_024 * 1_024 {
            commands.append("rclone copyto \(shellQuote(upload.source.path)) \(shellQuote(options.rcloneRemote + ":" + options.bucket + "/" + upload.key)) --s3-upload-cutoff 256Mi --s3-chunk-size 64Mi --s3-upload-concurrency 4 --header-upload 'Content-Type: application/octet-stream' --header-upload 'Cache-Control: public, max-age=31536000, immutable' --progress")
        } else {
            commands.append("npx --yes wrangler@latest r2 object put \(shellQuote(options.bucket + "/" + upload.key)) --remote --file \(shellQuote(upload.source.path)) --content-type application/octet-stream --cache-control 'public, max-age=31536000, immutable'")
        }
    }
    commands.append("npx --yes wrangler@latest r2 object put \(shellQuote(options.bucket + "/catalog-v1.json")) --remote --file \(shellQuote(catalogURL.path)) --content-type application/json --cache-control 'public, max-age=300'")
    commands.append("npx --yes wrangler@latest r2 object put \(shellQuote(options.bucket + "/catalog-v1.sig")) --remote --file \(shellQuote(signatureURL.path)) --content-type application/octet-stream --cache-control 'public, max-age=300'")
    commands.append("")
    let uploadScript = options.output.appendingPathComponent("wrangler-upload.sh")
    try commands.joined(separator: "\n").write(to: uploadScript, atomically: true, encoding: .utf8)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: uploadScript.path)

    print("Catalog: \(catalogURL.path)")
    print("Signature: \(signatureURL.path)")
    print("Upload commands: \(uploadScript.path)")
    for model in catalog.models {
        let bytes = model.artifacts.reduce(Int64(0)) { $0 + $1.bytes }
        print("\(model.id): \(model.revision), \(bytes) bytes")
    }
} catch {
    fputs("error: \(error)\n", stderr)
    exit(1)
}
