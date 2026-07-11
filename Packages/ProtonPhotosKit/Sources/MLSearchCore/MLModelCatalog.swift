import Foundation

/// Stable identity of a Smart Search model in the catalog. Distinct from
/// `MLModelDescriptor.identifier` only in role: the catalog ID names the *product entry* a user
/// can select; the descriptor names the *embedding epoch* the entry currently produces.
public struct MLModelID: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

/// License classification the UI must surface before a model can be selected.
public struct MLModelLicense: Sendable, Equatable, Codable {
    /// SPDX-style identifier (`"MIT"`) or a stable custom marker (`"Apple-AMLR"`).
    public let identifier: String
    /// `true` only when the weights may legally ship to end users.
    public let allowsRedistribution: Bool
    /// `true` only when the weights may be used in a commercial product.
    public let allowsProductUse: Bool

    public init(identifier: String, allowsRedistribution: Bool, allowsProductUse: Bool) {
        self.identifier = identifier
        self.allowsRedistribution = allowsRedistribution
        self.allowsProductUse = allowsProductUse
    }

    public static let mit = MLModelLicense(identifier: "MIT", allowsRedistribution: true, allowsProductUse: true)
    public static let apache2 = MLModelLicense(identifier: "Apache-2.0", allowsRedistribution: true, allowsProductUse: true)
    /// Apple Machine Learning Research Model License: research-only. Weights must never be
    /// bundled, mirrored, or auto-downloaded by the product.
    public static let appleAMLR = MLModelLicense(identifier: "Apple-AMLR", allowsRedistribution: false, allowsProductUse: false)
}

/// Release track of a catalog entry. Developer-only entries are selectable exclusively in
/// environments that explicitly allow them (never in Release builds).
public enum MLModelReleaseTrack: String, Sendable, Codable {
    case production
    case developerOnly
}

/// Evidence that one immutable artifact revision passed the project's on-device release run.
/// Values are diagnostic; `passed` is set only after testing the oldest supported iPhone/iPad.
public struct MLModelReleaseQualification: Sendable, Equatable, Codable {
    public let artifactRevision: String
    public let hardwareModel: String
    public let osVersion: String
    public let peakResidentBytes: Int64
    public let imageP95Milliseconds: Double
    public let textP95Milliseconds: Double
    public let reachedSeriousThermalState: Bool
    public let neuralEngineExecutionVerified: Bool
    public let passed: Bool

    public init(
        artifactRevision: String,
        hardwareModel: String,
        osVersion: String,
        peakResidentBytes: Int64,
        imageP95Milliseconds: Double,
        textP95Milliseconds: Double,
        reachedSeriousThermalState: Bool,
        neuralEngineExecutionVerified: Bool,
        passed: Bool
    ) {
        self.artifactRevision = artifactRevision
        self.hardwareModel = hardwareModel
        self.osVersion = osVersion
        self.peakResidentBytes = peakResidentBytes
        self.imageP95Milliseconds = imageP95Milliseconds
        self.textP95Milliseconds = textP95Milliseconds
        self.reachedSeriousThermalState = reachedSeriousThermalState
        self.neuralEngineExecutionVerified = neuralEngineExecutionVerified
        self.passed = passed
    }
}

/// One file of a model installation, identified by its install-relative path and content hash.
///
/// `relativePath` is validated against path traversal before any filesystem use — see
/// `MLModelInstallLayout.isSafeRelativePath`.
public struct MLModelArtifactSpec: Sendable, Equatable, Codable {
    public let relativePath: String
    /// Lowercase hex SHA-256 of the artifact file content.
    public let sha256: String
    /// Expected byte size of the artifact file; verified before activation.
    public let byteCount: Int64

    public init(relativePath: String, sha256: String, byteCount: Int64) {
        self.relativePath = relativePath
        self.sha256 = sha256.lowercased()
        self.byteCount = byteCount
    }
}

/// Immutable description of a downloadable model revision.
///
/// The plan pins exact content: an immutable revision token (e.g. a Hugging Face commit hash or
/// a CDN release tag), one URL per artifact, and the SHA-256 each download must match. A plan
/// referencing a mutable branch is a configuration bug — revisions must be commit-pinned.
public struct MLModelDownloadPlan: Sendable, Equatable, Codable {
    public struct Item: Sendable, Equatable, Codable {
        public let url: URL
        public let artifact: MLModelArtifactSpec

        public init(url: URL, artifact: MLModelArtifactSpec) {
            self.url = url
            self.artifact = artifact
        }
    }

    /// Immutable revision token identifying this exact artifact set.
    public let revision: String
    public let items: [Item]

    public init(revision: String, items: [Item]) {
        self.revision = revision
        self.items = items
    }

    public var totalByteCount: Int64 { items.reduce(0) { $0 + $1.artifact.byteCount } }
}

/// Catalog-bound CoreML runtime contract: the exact function names, feature names, text
/// context length and image input size a model artifact must expose. The adapter validates a
/// loaded artifact against this contract BEFORE any session activates — a mismatching artifact
/// is a `modelLoad` failure, never undefined inference. Data, not code: new CLIP-family models
/// ship as catalog entries with their own contract values, without per-model runtime branches.
public struct MLModelRuntimeContract: Sendable, Equatable, Codable {
    /// Multi-function model: function computing image embeddings.
    public var imageFunctionName: String
    /// Multi-function model: function computing text embeddings.
    public var textFunctionName: String
    public var imageInputName: String
    public var tokenInputName: String
    /// End-of-text mask input, or `nil` for families whose text tower pools internally
    /// (SigLIP-style: fixed-length padded ids are the only text input).
    public var endTokenMaskInputName: String?
    public var embeddingOutputName: String
    /// Fixed token count of the text encoder input; the tokenizer must produce exactly this.
    public var textContextLength: Int
    /// Square input side (pixels) the image encoder expects; the artifact's image constraint
    /// must match exactly (preprocessing recipe identity lives in `preprocessingID`).
    public var imagePixelSide: Int

    public init(
        imageFunctionName: String,
        textFunctionName: String,
        imageInputName: String,
        tokenInputName: String,
        endTokenMaskInputName: String?,
        embeddingOutputName: String,
        textContextLength: Int,
        imagePixelSide: Int
    ) {
        self.imageFunctionName = imageFunctionName
        self.textFunctionName = textFunctionName
        self.imageInputName = imageInputName
        self.tokenInputName = tokenInputName
        self.endTokenMaskInputName = endTokenMaskInputName
        self.embeddingOutputName = embeddingOutputName
        self.textContextLength = textContextLength
        self.imagePixelSide = imagePixelSide
    }

    /// The CLIP dual-encoder convention our converted artifacts follow (77-token context).
    public static func clipDualEncoder(imagePixelSide: Int) -> MLModelRuntimeContract {
        MLModelRuntimeContract(
            imageFunctionName: "image",
            textFunctionName: "text",
            imageInputName: "image",
            tokenInputName: "input_ids",
            endTokenMaskInputName: "eot_mask",
            embeddingOutputName: "embedding",
            textContextLength: 77,
            imagePixelSide: imagePixelSide
        )
    }

    /// The SigLIP dual-encoder convention: fixed-length padded ids, internal pooling
    /// (no mask input), 64-token context.
    public static func siglipDualEncoder(imagePixelSide: Int) -> MLModelRuntimeContract {
        MLModelRuntimeContract(
            imageFunctionName: "image",
            textFunctionName: "text",
            imageInputName: "image",
            tokenInputName: "input_ids",
            endTokenMaskInputName: nil,
            embeddingOutputName: "embedding",
            textContextLength: 64,
            imagePixelSide: imagePixelSide
        )
    }
}

/// One selectable Smart Search model. Immutable: changing any compatibility-relevant property
/// (tokenizer, preprocessing, weights revision, dimension) requires bumping the descriptor
/// version, which retires every existing embedding for the old epoch deterministically.
public struct MLModelCatalogEntry: Sendable, Equatable, Identifiable {
    public let id: MLModelID
    /// Display-safe product name (localized display goes through the presentation layer).
    public let displayName: String
    /// Model family marker for diagnostics (`"TinyCLIP"`, `"MobileCLIP"`).
    public let family: String
    /// Immutable upstream weights revision used to produce the artifact, when applicable.
    public let sourceRevision: String?
    /// The embedding epoch this entry currently produces. `descriptor.version` is the single
    /// invalidation knob: bump it whenever tokenizer/preprocessing/weights change compatibility.
    public let descriptor: MLModelDescriptor
    /// Stable tokenizer identity; sessions must refuse to start when the runtime tokenizer
    /// doesn't match.
    public let tokenizerID: String
    /// Stable preprocessing identity (resize/crop/normalization recipe).
    public let preprocessingID: String
    /// CoreML runtime contract the installed artifact must satisfy before activation.
    public let runtimeContract: MLModelRuntimeContract
    /// Install-root files required beside the model. Local installs copy only these declared
    /// sidecars, so conversion work products cannot silently inflate the installed footprint.
    public let runtimeResourcePaths: [String]
    public let license: MLModelLicense
    public let releaseTrack: MLModelReleaseTrack
    /// Approximate installed size for UI, before an installation exists. Actual installed
    /// size is measured after install.
    public let estimatedInstalledBytes: Int64
    /// Pinned download plan, or `nil` when no immutable hosted artifact exists yet. A `nil`
    /// plan means the model can only be installed from a developer-provided local artifact.
    public let downloadPlan: MLModelDownloadPlan?
    /// On-device evidence for the exact hosted revision. Absent or stale evidence keeps the
    /// entry out of Release even when a download plan is accidentally added early.
    public let releaseQualification: MLModelReleaseQualification?

    public init(
        id: MLModelID,
        displayName: String,
        family: String,
        sourceRevision: String? = nil,
        descriptor: MLModelDescriptor,
        tokenizerID: String,
        preprocessingID: String,
        runtimeContract: MLModelRuntimeContract = .clipDualEncoder(imagePixelSide: 224),
        runtimeResourcePaths: [String] = [],
        license: MLModelLicense,
        releaseTrack: MLModelReleaseTrack,
        estimatedInstalledBytes: Int64,
        downloadPlan: MLModelDownloadPlan?,
        releaseQualification: MLModelReleaseQualification? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.family = family
        self.sourceRevision = sourceRevision
        self.descriptor = descriptor
        self.tokenizerID = tokenizerID
        self.preprocessingID = preprocessingID
        self.runtimeContract = runtimeContract
        self.runtimeResourcePaths = runtimeResourcePaths
        self.license = license
        self.releaseTrack = releaseTrack
        self.estimatedInstalledBytes = estimatedInstalledBytes
        self.downloadPlan = downloadPlan
        self.releaseQualification = releaseQualification
    }

    /// A model is downloadable only with a pinned plan AND a license that permits both
    /// redistributing the weights to end users and using them in the product. A plan on a
    /// restrictively licensed entry is a configuration bug and stays technically inert.
    /// Developer-only models install from local artifacts instead.
    public var isDownloadable: Bool {
        downloadPlan != nil && license.allowsRedistribution && license.allowsProductUse
    }

    /// Release builds expose only entries that can actually be installed. A production label
    /// without an immutable download plan is a staging state, not a user-selectable model.
    public var isReleaseReady: Bool {
        guard releaseTrack == .production,
              isDownloadable,
              let revision = downloadPlan?.revision,
              let releaseQualification else { return false }
        return releaseQualification.artifactRevision == revision
            && releaseQualification.passed
            && releaseQualification.neuralEngineExecutionVerified
    }
}

/// The immutable set of models this build can offer.
///
/// Hosts filter by environment (`allowsDeveloperModels`) before showing entries. The catalog is
/// data, not policy: enable/select/install decisions belong to `MLSmartSearchLifecycle`.
public struct MLModelCatalog: Sendable, Equatable {
    public let entries: [MLModelCatalogEntry]

    public init(entries: [MLModelCatalogEntry]) {
        self.entries = entries
    }

    public func entry(for id: MLModelID) -> MLModelCatalogEntry? {
        entries.first { $0.id == id }
    }

    /// Entries this environment may select. Release builds require the production track AND a
    /// license permitting product use — a mislabeled entry (production track, research-only
    /// license) is unselectable, not merely a data note. Developer environments additionally
    /// see developer-only entries (local-artifact installs; still never downloadable without
    /// a redistribution-clean license).
    public func selectableEntries(allowsDeveloperModels: Bool) -> [MLModelCatalogEntry] {
        allowsDeveloperModels
            ? entries
            : entries.filter(\.isReleaseReady)
    }
}

extension MLModelCatalogEntry {
    /// TinyCLIP ViT-40M/32 + 19M text encoder (LAION-400M), MIT-licensed by Microsoft.
    ///
    /// `downloadPlan` is `nil` until release engineering publishes a converted, checksummed
    /// CoreML artifact at an immutable URL — the upstream distribution is PyTorch/safetensors,
    /// which cannot be converted on-device. Until then TinyCLIP installs from a developer
    /// artifact only; the plan slots in here without touching lifecycle code.
    public static let tinyCLIPVit40M = MLModelCatalogEntry(
        id: MLModelID("tinyclip-vit-40m-32-text-19m"),
        displayName: "TinyCLIP 40M",
        family: "TinyCLIP",
        sourceRevision: "95ec8197b3f2fe7f747865c61ca556cf0768b2f7",
        descriptor: MLModelDescriptor(identifier: "tinyclip-vit-40m-32-text-19m", version: 1, embeddingDimension: 512),
        tokenizerID: "clip-bpe-77",
        preprocessingID: "clip-centercrop-224",
        runtimeContract: .clipDualEncoder(imagePixelSide: 224),
        license: .mit,
        releaseTrack: .production,
        estimatedInstalledBytes: 130_000_000,
        downloadPlan: nil
    )

    /// Google SigLIP2 base, patch16, 256px — the multilingual production model.
    ///
    /// Weights license: Apache-2.0 (verified 2026-07 on the HF repo metadata for
    /// `google/siglip2-base-patch16-256`; every `google/siglip2-*` repo carries apache-2.0).
    /// Redistribution and product use permitted. Upstream revision pinned for conversion:
    /// `3f9f96cb90da5dbc758b01813f2f6f1aee24c1ab`.
    ///
    /// Measured on the local reference-photo corpus (22 real photos, 8 concepts):
    /// German top-1 14/16 vs TinyCLIP's 10/16, at English parity (14/16 both) — the German
    /// gap ("Bäume", "Berg", "Menschen") closes. Lowercasing is part of the tokenizer
    /// contract (`tokenizer.json`, shipped inside the artifact and hash-verified).
    ///
    /// `downloadPlan` is `nil` until release engineering hosts the converted multi-function
    /// CoreML artifact (image+text towers, ~715 MB fp16) at an immutable URL — conversion is
    /// reproducible via `ml-model-spike.noindex/convert_siglip2.py`. Until then it installs
    /// from a developer artifact only; the plan slots in without touching lifecycle code.
    public static let sigLIP2Base256 = MLModelCatalogEntry(
        id: MLModelID("siglip2-base-patch16-256"),
        displayName: "SigLIP 2",
        family: "SigLIP2",
        sourceRevision: "3f9f96cb90da5dbc758b01813f2f6f1aee24c1ab",
        descriptor: MLModelDescriptor(identifier: "siglip2-base-patch16-256", version: 1, embeddingDimension: 768),
        tokenizerID: "gemma-sentencepiece-64",
        preprocessingID: "siglip-resize-256",
        runtimeContract: .siglipDualEncoder(imagePixelSide: 256),
        runtimeResourcePaths: ["tokenizer.json"],
        license: .apache2,
        releaseTrack: .production,
        estimatedInstalledBytes: 760_000_000,
        downloadPlan: nil
    )

    /// Apple MobileCLIP-S2. Current authoritative weights license (apple/ml-mobileclip
    /// LICENSE_MODELS) is the Apple Machine Learning Research license: research-only, no
    /// product use, no redistribution. Developer-only: local artifact installs, never
    /// downloadable, never in Release builds.
    public static let appleMobileCLIPS2Developer = MLModelCatalogEntry(
        id: MLModelID("mobileclip-s2-dev"),
        displayName: "MobileCLIP S2 (Development only)",
        family: "MobileCLIP",
        descriptor: MLModelDescriptor(identifier: "mobileclip-s2", version: 1, embeddingDimension: 512),
        tokenizerID: "clip-bpe-77",
        preprocessingID: "clip-centercrop-256",
        runtimeContract: .clipDualEncoder(imagePixelSide: 256),
        license: .appleAMLR,
        releaseTrack: .developerOnly,
        estimatedInstalledBytes: 200_000_000,
        downloadPlan: nil
    )
}

extension MLModelCatalog {
    public static let builtIn = MLModelCatalog(entries: [
        .sigLIP2Base256,
        .tinyCLIPVit40M,
        .appleMobileCLIPS2Developer,
    ])
}
