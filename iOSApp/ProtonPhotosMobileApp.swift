import DesignSystemCore
import Metal
import os
import PhotosCore
import ProtonCoreCryptoPatchedGoImplementation
import SwiftUI
import TimelineUIKitAdapter
import UIKit

@main
struct ProtonPhotosMobileApp: App {
    @StateObject private var sessionModel = MobileSessionModel()
    /// `@State` (not `@StateObject`) because `MobileLibraryModel` is `@Observable`: SwiftUI then tracks its
    /// properties individually, so non-grid tabs don't re-render on a timeline snapshot change.
    @State private var libraryModel = MobileLibraryModel()

    var body: some Scene {
        WindowGroup {
            MobileRootView()
                .environmentObject(sessionModel)
                .environment(libraryModel)
                .task {
                    libraryModel.configure(session: sessionModel.session, store: sessionModel.sessionStore)
                }
                .onChange(of: sessionModel.session) { _, session in
                    libraryModel.configure(session: session, store: sessionModel.sessionStore)
                }
        }
    }
}

/// The mobile tabs, as explicit selection values so the Photos grid can be told when it is NOT the active
/// surface (and stop its render loop). `name` feeds the `[UIHitch]` tab-transition diagnostic.
enum MobileTab: Hashable {
    case photos, collections, map, settings

    var name: String {
        switch self {
        case .photos: "photos"
        case .collections: "collections"
        case .map: "map"
        case .settings: "settings"
        }
    }
}

/// Low-noise `[UIHitch]` tab-transition log (state-change only), same subsystem/category as the grid host's
/// `[UIHitch]` lines so one `log stream` filtered to that category shows tab changes AND grid frame stalls.
enum MobileTabActivityLog {
    private static let logger = Logger(subsystem: "me.protonphotos.ios", category: "UIHitch")
    static func note(tab: MobileTab) {
        logger.notice("[UIHitch] event=tab tab=\(tab.name, privacy: .public)")
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
    /// Explicit selection so the Photos grid knows when it is NOT the active surface and can stop its render
    /// loop + ahead-warm, keeping menu/tab/settings interaction smooth while thumbnails load.
    @State private var selection: MobileTab = .photos

    var body: some View {
        TabView(selection: $selection) {
            Tab(String(localized: "tab.photos"), systemImage: "photo.on.rectangle.angled", value: MobileTab.photos) {
                MobileTimelineScreen(isActive: selection == .photos)
            }
            Tab(String(localized: "tab.collections"), systemImage: "square.stack", value: MobileTab.collections) {
                MobileCollectionsScreen()
            }
            Tab(String(localized: "tab.map"), systemImage: "map", value: MobileTab.map) {
                MobileMapScreen()
            }
            Tab(String(localized: "tab.settings"), systemImage: "gearshape", value: MobileTab.settings) {
                MobileSettingsScreen()
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tint(ProtonColor.primary)
        .onChange(of: selection) { _, tab in
            MobileTabActivityLog.note(tab: tab)
        }
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
