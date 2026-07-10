import MLSearchCore
import MLSearchFeature
import PhotosCore
import SwiftUI

/// macOS Settings tab for Smart Search. Pure host chrome: the entire settings surface is the
/// shared `SmartSearchSettingsSection` (identical on iOS/iPadOS), driven by the shared
/// cross-platform controller.
struct SmartSearchSettingsTab: View {
    let controller: MLSmartSearchController

    var body: some View {
        Form {
            SmartSearchSettingsSection(controller: controller)
        }
        .formStyle(.grouped)
    }
}
