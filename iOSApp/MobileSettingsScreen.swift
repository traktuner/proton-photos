import DesignSystemCore
import PhotosCore
import SwiftUI

/// Account & settings tab. Deliberately minimal for this shell: it surfaces the library size and the sign-out
/// action. It carries no debug/internal copy.
struct MobileSettingsScreen: View {
    @EnvironmentObject private var sessionModel: MobileSessionModel
    @EnvironmentObject private var libraryModel: MobileLibraryModel
    @State private var confirmSignOut = false

    var body: some View {
        NavigationStack {
            List {
                Section("settings.section_library") {
                    LabeledContent(String(localized: "tab.photos")) {
                        Text(photoCountText)
                            .monospacedDigit()
                            .foregroundStyle(ProtonColor.textWeak)
                    }
                }

                Section {
                    Button(role: .destructive) {
                        confirmSignOut = true
                    } label: {
                        Label("action.sign_out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    // Attached to the row (not the stack), so the iPad popover anchors AT the Sign out
                    // button instead of drifting to whatever sat at the list's top. iPhone keeps the
                    // native bottom sheet.
                    .confirmationDialog(
                        String(localized: "settings.sign_out_confirm \(ProductBrand.displayName)"),
                        isPresented: $confirmSignOut,
                        titleVisibility: .visible
                    ) {
                        Button(String(localized: "action.sign_out"), role: .destructive) {
                            sessionModel.signOut()
                        }
                        Button(String(localized: "action.cancel"), role: .cancel) {}
                    }
                }

                Section {
                    EmptyView()
                } footer: {
                    HStack {
                        Spacer()
                        VStack(spacing: 8) {
                            MobileBrandLogo(height: 28)
                            Text(ProductBrand.displayName)
                                .font(.footnote)
                                .foregroundStyle(ProtonColor.textHint)
                        }
                        Spacer()
                    }
                    .padding(.top, 12)
                }
            }
            .navigationTitle(String(localized: "tab.settings"))
        }
    }

    private var photoCountText: String {
        if let count = libraryModel.loadState.knownCount {
            return "\(count)"
        }
        return String(localized: "settings.count_loading")
    }
}
