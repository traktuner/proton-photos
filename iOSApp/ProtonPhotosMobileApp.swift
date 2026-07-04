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

/// Top-level mobile routes. They are shared by the compact iPhone tab shell and the regular-width iPad sidebar
/// shell, so navigation chrome can adapt without duplicating feature screens or Core logic.
enum MobileTab: CaseIterable, Hashable, Identifiable {
    case photos, collections, map, settings

    var id: Self { self }

    var name: String {
        switch self {
        case .photos: "photos"
        case .collections: "collections"
        case .map: "map"
        case .settings: "settings"
        }
    }

    var title: String {
        switch self {
        case .photos: String(localized: "tab.photos")
        case .collections: String(localized: "tab.collections")
        case .map: String(localized: "tab.map")
        case .settings: String(localized: "tab.settings")
        }
    }

    var systemImage: String {
        switch self {
        case .photos: "photo.on.rectangle.angled"
        case .collections: "square.stack"
        case .map: "map"
        case .settings: "gearshape"
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

/// Adaptive navigation: compact widths get the native bottom tab bar, while regular-width iPadOS uses a native
/// split-view sidebar. The selected route is the only state; every feature screen below stays shared.
private struct MobileMainTabView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selection: MobileTab = .photos

    var body: some View {
        if horizontalSizeClass == .regular {
            MobilePadSidebarShell(selection: $selection)
        } else {
            MobilePhoneTabShell(selection: $selection)
        }
    }
}

private struct MobilePhoneTabShell: View {
    @Binding var selection: MobileTab
    /// Bumped when the already-active Photos tab is retapped, so the timeline scrolls to the newest photos.
    @State private var photosScrollSignal = 0

    /// A custom selection binding so retapping the ALREADY-active Photos tab is observable: a retap routes the
    /// same value through the setter (which `.onChange(of:)` cannot see, since the value doesn't change). We
    /// only bump a scroll signal — the route, library, grid level and selection are all left untouched.
    private var tabSelection: Binding<MobileTab> {
        Binding {
            selection
        } set: { newValue in
            if newValue == .photos, selection == .photos {
                photosScrollSignal &+= 1
            }
            selection = newValue
        }
    }

    var body: some View {
        TabView(selection: tabSelection) {
            Tab(MobileTab.photos.title, systemImage: MobileTab.photos.systemImage, value: MobileTab.photos) {
                MobileTimelineScreen(isActive: selection == .photos, scrollToLatestSignal: photosScrollSignal)
            }
            Tab(MobileTab.collections.title, systemImage: MobileTab.collections.systemImage, value: MobileTab.collections) {
                MobileCollectionsScreen()
            }
            Tab(MobileTab.map.title, systemImage: MobileTab.map.systemImage, value: MobileTab.map) {
                MobileMapScreen()
            }
            Tab(MobileTab.settings.title, systemImage: MobileTab.settings.systemImage, value: MobileTab.settings) {
                MobileSettingsScreen()
            }
        }
        .tint(ProtonColor.primary)
        .onChange(of: selection) { _, tab in
            MobileTabActivityLog.note(tab: tab)
        }
    }
}

private struct MobilePadSidebarShell: View {
    @Binding var selection: MobileTab
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    /// Bumped when the already-selected Photos row is re-selected, so the timeline scrolls to newest.
    @State private var photosScrollSignal = 0

    private var optionalSelection: Binding<MobileTab?> {
        Binding {
            selection
        } set: { tab in
            guard let tab else { return }
            if tab == .photos, selection == .photos { photosScrollSignal &+= 1 }
            selection = tab
        }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(MobileTab.allCases, selection: optionalSelection) { tab in
                Label(tab.title, systemImage: tab.systemImage)
                    .tag(tab)
            }
            .listStyle(.sidebar)
            .navigationTitle(ProductBrand.displayName)
            .navigationSplitViewColumnWidth(
                min: SidebarMetrics.minWidth,
                ideal: SidebarMetrics.defaultWidth,
                max: SidebarMetrics.maxWidth
            )
        } detail: {
            // NavigationSplitView already renders the ONE native sidebar toggle in the detail's top bar; a
            // second manual `sidebar.left` button here produced the duplicate toggle in landscape. Rely on the
            // system control only (predictable, and it animates the column the standard way).
            MobileRouteScreen(tab: selection, isPhotosActive: selection == .photos, photosScrollSignal: photosScrollSignal)
        }
        .tint(ProtonColor.primary)
        .onChange(of: selection) { _, tab in
            MobileTabActivityLog.note(tab: tab)
        }
    }
}

private struct MobileRouteScreen: View {
    let tab: MobileTab
    let isPhotosActive: Bool
    var photosScrollSignal: Int = 0

    var body: some View {
        switch tab {
        case .photos:
            MobileTimelineScreen(isActive: isPhotosActive, scrollToLatestSignal: photosScrollSignal)
        case .collections:
            MobileCollectionsScreen()
        case .map:
            MobileMapScreen()
        case .settings:
            MobileSettingsScreen()
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
