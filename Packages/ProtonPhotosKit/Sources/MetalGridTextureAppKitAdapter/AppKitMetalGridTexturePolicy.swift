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

    package static let `default` = AppKitMetalGridTexturePolicy(
        budget: GridTextureBudget(maxUploadsPerFrame: 96, maxCachedTextures: 4096, overscanFraction: 1.2),
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
