import CoreGraphics
import GridCore

package enum UIKitMetalGridTextureSurfaceClass: String, Sendable {
    case compact
    case regular
    case expanded

    package static func resolving(viewportSize: CGSize) -> Self {
        let shortestSide = min(viewportSize.width, viewportSize.height)
        if shortestSide < 430 { return .compact }
        if shortestSide < 768 { return .regular }
        return .expanded
    }
}

package struct UIKitMetalGridTexturePolicy: Equatable, Sendable {
    package let budget: GridTextureBudget
    package let maxTexturePixels: Int

    package init(budget: GridTextureBudget, maxTexturePixels: Int) {
        self.budget = budget
        self.maxTexturePixels = maxTexturePixels
    }
}

package enum UIKitMetalGridTexturePolicies {
    package static let compact = UIKitMetalGridTexturePolicy(
        budget: GridTextureBudget(maxUploadsPerFrame: 24, maxCachedTextures: 768, overscanFraction: 0.75),
        maxTexturePixels: 224
    )

    package static let regular = UIKitMetalGridTexturePolicy(
        budget: GridTextureBudget(maxUploadsPerFrame: 32, maxCachedTextures: 1024, overscanFraction: 0.9),
        maxTexturePixels: 256
    )

    package static let expanded = UIKitMetalGridTexturePolicy(
        budget: GridTextureBudget(maxUploadsPerFrame: 48, maxCachedTextures: 1536, overscanFraction: 1.0),
        maxTexturePixels: 288
    )

    package static func policy(for surfaceClass: UIKitMetalGridTextureSurfaceClass) -> UIKitMetalGridTexturePolicy {
        switch surfaceClass {
        case .compact: compact
        case .regular: regular
        case .expanded: expanded
        }
    }

    package static func policy(forViewportSize viewportSize: CGSize) -> UIKitMetalGridTexturePolicy {
        policy(for: UIKitMetalGridTextureSurfaceClass.resolving(viewportSize: viewportSize))
    }
}
