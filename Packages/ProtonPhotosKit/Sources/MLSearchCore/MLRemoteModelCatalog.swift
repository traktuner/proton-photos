import Foundation

public protocol MLModelCatalogProvider: Sendable {
    func catalog() async throws -> MLModelCatalog
}

public struct StaticMLModelCatalogProvider: MLModelCatalogProvider {
    private let value: MLModelCatalog

    public init(_ value: MLModelCatalog) {
        self.value = value
    }

    public func catalog() async throws -> MLModelCatalog { value }
}

/// Small signed JSON document published beside immutable model artifacts.
/// Only distribution data is remote; runtime and licensing contracts remain app-reviewed.
public struct MLRemoteModelCatalogDocument: Sendable, Equatable, Codable {
    public static let supportedSchemaVersion = 1

    public struct Model: Sendable, Equatable, Codable {
        public let id: MLModelID
        public let revision: String
        public let artifacts: [Artifact]

        public init(id: MLModelID, revision: String, artifacts: [Artifact]) {
            self.id = id
            self.revision = revision
            self.artifacts = artifacts
        }
    }

    public struct Artifact: Sendable, Equatable, Codable {
        public let path: String
        public let url: URL
        public let sha256: String
        public let bytes: Int64

        public init(path: String, url: URL, sha256: String, bytes: Int64) {
            self.path = path
            self.url = url
            self.sha256 = sha256
            self.bytes = bytes
        }
    }

    public let schemaVersion: Int
    public let models: [Model]

    public init(schemaVersion: Int = supportedSchemaVersion, models: [Model]) {
        self.schemaVersion = schemaVersion
        self.models = models
    }
}

public enum MLRemoteModelCatalogError: Error, Equatable {
    case unsupportedSchema(Int)
    case duplicateModel(String)
    case unknownModel(String)
    case invalidRevision(String)
    case noArtifacts(String)
    case duplicateArtifact(String)
    case unsafeArtifactPath(String)
    case invalidArtifactURL(String)
    case invalidHash(String)
    case invalidByteCount(String)
    case invalidModelLayout(String)
    case missingRuntimeResource(String)
}

/// Resolves untrusted distribution JSON against the app's trusted compatibility registry.
public struct MLRemoteModelCatalogResolver: Sendable {
    private let trustedCatalog: MLModelCatalog
    private let allowedBaseURL: URL

    public init(trustedCatalog: MLModelCatalog, allowedBaseURL: URL) {
        self.trustedCatalog = trustedCatalog
        self.allowedBaseURL = allowedBaseURL
    }

    public func resolve(_ document: MLRemoteModelCatalogDocument) throws -> MLModelCatalog {
        guard document.schemaVersion == MLRemoteModelCatalogDocument.supportedSchemaVersion else {
            throw MLRemoteModelCatalogError.unsupportedSchema(document.schemaVersion)
        }

        var seenModels: Set<MLModelID> = []
        var plans: [MLModelID: MLModelDownloadPlan] = [:]
        for remote in document.models {
            guard seenModels.insert(remote.id).inserted else {
                throw MLRemoteModelCatalogError.duplicateModel(remote.id.rawValue)
            }
            guard let trusted = trustedCatalog.entry(for: remote.id),
                  trusted.license.allowsRedistribution,
                  trusted.license.allowsProductUse else {
                throw MLRemoteModelCatalogError.unknownModel(remote.id.rawValue)
            }
            guard Self.isSafeRevision(remote.revision) else {
                throw MLRemoteModelCatalogError.invalidRevision(remote.revision)
            }
            guard !remote.artifacts.isEmpty else {
                throw MLRemoteModelCatalogError.noArtifacts(remote.id.rawValue)
            }

            var seenPaths: Set<String> = []
            var modelRoots: Set<String> = []
            var items: [MLModelDownloadPlan.Item] = []
            for artifact in remote.artifacts {
                guard seenPaths.insert(artifact.path).inserted else {
                    throw MLRemoteModelCatalogError.duplicateArtifact(artifact.path)
                }
                guard MLModelInstallLayout.isSafeRelativePath(artifact.path) else {
                    throw MLRemoteModelCatalogError.unsafeArtifactPath(artifact.path)
                }
                guard isAllowedArtifactURL(artifact.url) else {
                    throw MLRemoteModelCatalogError.invalidArtifactURL(artifact.url.absoluteString)
                }
                let hash = artifact.sha256.lowercased()
                guard hash.count == 64, hash.allSatisfy({ $0.isHexDigit }) else {
                    throw MLRemoteModelCatalogError.invalidHash(artifact.path)
                }
                guard artifact.bytes > 0 else {
                    throw MLRemoteModelCatalogError.invalidByteCount(artifact.path)
                }

                let firstComponent = artifact.path.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
                if firstComponent.lowercased().hasSuffix(".mlmodelc") {
                    modelRoots.insert(firstComponent)
                }
                items.append(MLModelDownloadPlan.Item(
                    url: artifact.url,
                    artifact: MLModelArtifactSpec(
                        relativePath: artifact.path,
                        sha256: hash,
                        byteCount: artifact.bytes
                    )
                ))
            }
            guard modelRoots.count == 1 else {
                throw MLRemoteModelCatalogError.invalidModelLayout(remote.id.rawValue)
            }
            for resource in trusted.runtimeResourcePaths where !seenPaths.contains(resource) {
                throw MLRemoteModelCatalogError.missingRuntimeResource(resource)
            }
            plans[remote.id] = MLModelDownloadPlan(
                revision: remote.revision,
                items: items.sorted { $0.artifact.relativePath < $1.artifact.relativePath }
            )
        }

        return MLModelCatalog(entries: trustedCatalog.entries.map { entry in
            entry.withDownloadPlan(plans[entry.id])
        })
    }

    private func isAllowedArtifactURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.host?.lowercased() == allowedBaseURL.host?.lowercased() else { return false }
        let basePath = allowedBaseURL.path.hasSuffix("/") ? allowedBaseURL.path : allowedBaseURL.path + "/"
        return url.path.hasPrefix(basePath)
    }

    private static func isSafeRevision(_ revision: String) -> Bool {
        !revision.isEmpty && revision.count <= 128 && revision.allSatisfy {
            $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "."
        }
    }
}
