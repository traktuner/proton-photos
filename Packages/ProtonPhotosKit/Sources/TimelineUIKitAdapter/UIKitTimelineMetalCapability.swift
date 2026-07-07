#if canImport(UIKit)
import Metal

/// Runtime gate for the UIKit Metal timeline host.
///
/// Real iOS/iPadOS devices must expose the shared Metal 3 floor used by the renderer.
/// The Simulator reports the Mac host GPU family, so it cannot be gated by a mobile GPU family alone even
/// when the same renderer works correctly through the Simulator's Metal bridge.
public enum UIKitTimelineMetalCapability {
    public static func supportsTimelineGrid(device: MTLDevice) -> Bool {
        #if targetEnvironment(simulator)
        true
        #else
        device.supportsFamily(.metal3)
        #endif
    }
}
#endif
