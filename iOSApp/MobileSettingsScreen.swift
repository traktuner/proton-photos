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
                Section("Library") {
                    LabeledContent("Photos") {
                        Text(photoCountText)
                            .monospacedDigit()
                            .foregroundStyle(ProtonColor.textWeak)
                    }
                }

                Section {
                    Button(role: .destructive) {
                        confirmSignOut = true
                    } label: {
                        Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            }
            .navigationTitle("Settings")
            .confirmationDialog("Sign out of \(ProductBrand.displayName)?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) { sessionModel.signOut() }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private var photoCountText: String {
        if let count = libraryModel.loadState.knownCount {
            return "\(count)"
        }
        return String(localized: "Loading…")
    }
}
