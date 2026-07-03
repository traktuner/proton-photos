#if canImport(UIKit)
import Metal

/// Runtime gate for the UIKit Metal timeline host.
///
/// Real iOS/iPadOS devices must expose the Apple GPU family that maps to the app's Metal 3 floor.
/// The Simulator reports the Mac host GPU family, so it cannot be gated by `.apple7` alone even
/// when the same renderer works correctly through the Simulator's Metal bridge.
public enum UIKitTimelineMetalCapability {
    public static func supportsTimelineGrid(device: MTLDevice) -> Bool {
        #if targetEnvironment(simulator)
        true
        #else
        device.supportsFamily(.apple7)
        #endif
    }
}
#endif
