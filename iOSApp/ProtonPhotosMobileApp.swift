import DesignSystemCore
import Metal
import PhotosCore
import ProtonCoreCryptoPatchedGoImplementation
import SwiftUI
import TimelineUIKitAdapter
import UIKit

@main
struct ProtonPhotosMobileApp: App {
    @StateObject private var sessionModel = MobileSessionModel()
    @StateObject private var libraryModel = MobileLibraryModel()

    var body: some Scene {
        WindowGroup {
            MobileRootView()
                .environmentObject(sessionModel)
                .environmentObject(libraryModel)
                .task {
                    libraryModel.configure(session: sessionModel.session, store: sessionModel.sessionStore)
                }
                .onChange(of: sessionModel.session) { _, session in
                    libraryModel.configure(session: session, store: sessionModel.sessionStore)
                }
        }
    }
}

/// Top-level presentation gate: unsupported GPU → an honest message; signed out → login; signed in → the app.
private struct MobileRootView: View {
    @EnvironmentObject private var sessionModel: MobileSessionModel

    private let metalStatus = MobileMetal3Runtime.status()

    var body: some View {
        ZStack {
            ProtonColor.backgroundNorm.ignoresSafeArea()

            if !metalStatus.isSupported {
                MobileUnsupportedDeviceView(message: metalStatus.message)
            } else if sessionModel.session == nil {
                MobileLoginView()
            } else {
                MobileMainTabView()
            }
        }
    }
}

/// Adaptive navigation: on a compact iPhone this renders a native bottom tab bar; on iPad and other regular-width
/// surfaces `.sidebarAdaptable` promotes the same tabs to a sidebar/split layout — one declaration, no per-model
/// branching, no stretched-iPhone iPad UI.
private struct MobileMainTabView: View {
    var body: some View {
        TabView {
            Tab(String(localized: "tab.photos"), systemImage: "photo.on.rectangle.angled") {
                MobileTimelineScreen()
            }
            Tab(String(localized: "tab.albums"), systemImage: "rectangle.stack") {
                MobileAlbumsScreen()
            }
            Tab(String(localized: "tab.map"), systemImage: "map") {
                MobileMapScreen()
            }
            Tab(String(localized: "tab.settings"), systemImage: "gearshape") {
                MobileSettingsScreen()
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tint(ProtonColor.primary)
    }
}

private struct MobileUnsupportedDeviceView: View {
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(ProtonColor.warning)
            Text("device.unsupported_title")
                .font(.title2.weight(.semibold))
                .foregroundStyle(ProtonColor.textNorm)
            Text(message)
                .font(.body)
                .foregroundStyle(ProtonColor.textWeak)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: 520)
    }
}

/// Metal 3 capability gate (a genuine hardware capability check, not a platform fork — the simulator reports
/// capable via `UIKitTimelineMetalCapability`).
enum MobileMetal3Runtime {
    struct Status {
        let isSupported: Bool
        let message: String
    }

    static func status() -> Status {
        guard let device = MTLCreateSystemDefaultDevice() else {
            return Status(isSupported: false,
                          message: String(localized: "device.no_metal_renderer"))
        }
        guard UIKitTimelineMetalCapability.supportsTimelineGrid(device: device) else {
            return Status(isSupported: false,
                          message: String(localized: "device.requires_metal3 \(ProductBrand.displayName)"))
        }
        return Status(isSupported: true, message: device.name)
    }
}
