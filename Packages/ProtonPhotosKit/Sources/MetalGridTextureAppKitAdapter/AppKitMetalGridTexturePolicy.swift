import CoreGraphics
import GridCore

package struct AppKitMetalGridTexturePolicy: Equatable, Sendable {
    package let budget: GridTextureBudget
    package let maxTexturePixels: Int

    package init(budget: GridTextureBudget, maxTexturePixels: Int) {
        self.budget = budget
        self.maxTexturePixels = maxTexturePixels
    }
}

package enum AppKitMetalGridTexturePolicies {
    package static let defaultMaxTexturePixels = 320

    /// macOS desktop budget. Bytes are the binding limits; counts are backstops:
    /// - `maxResidentBytes` 512 MiB ≈ 1,310 worst-case (320×320) textures — several visible+overscan
    ///   bands at the normal zoom levels for scroll-reversal reuse, but far below the unbounded ~1.15 GB
    ///   the count-only budget allowed in practice.
    /// - `maxUploadBytesPerFrame` 6 MiB ≈ ~15 worst-case 320 px uploads ≈ single-digit-ms of main-thread
    ///   normalization + `replaceRegion` copy per frame (measured ~0.6 ms per 400 KiB upload), so a cold
    ///   viewport fills over a few frames instead of stalling one frame for 40–60 ms.
    package static let `default` = AppKitMetalGridTexturePolicy(
        budget: GridTextureBudget(maxUploadsPerFrame: 48, maxUploadBytesPerFrame: 6_291_456, maxCachedTextures: 4096, maxResidentBytes: 536_870_912, overscanFraction: 1.2),
        maxTexturePixels: defaultMaxTexturePixels
    )

    package static func policy(
        budget: GridTextureBudget,
        maxTexturePixels: Int = defaultMaxTexturePixels
    ) -> AppKitMetalGridTexturePolicy {
        AppKitMetalGridTexturePolicy(budget: budget, maxTexturePixels: maxTexturePixels)
    }
}

package extension GridTextureBudget {
    /// macOS adapter default. Other adapters must inject their own measured policy.
    static let `default` = AppKitMetalGridTexturePolicies.default.budget
}
