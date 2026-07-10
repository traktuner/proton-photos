import MLSearchCore
import MLSearchFeature
import PhotosCore
import SwiftUI

/// Dedicated Smart Search settings destination (iOS/iPadOS). Pure host chrome: the entire
/// settings surface is the shared `SmartSearchSettingsSection` (identical on macOS), driven by
/// the shared cross-platform controller.
struct MobileSmartSearchScreen: View {
    let controller: MLSmartSearchController

    var body: some View {
        List {
            SmartSearchSettingsSection(controller: controller)
        }
        .navigationTitle(L10n.string("mlsearch.settings_title"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
