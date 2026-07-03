import DesignSystemCore
import MediaByteCache
import MediaCacheCore
import MediaCacheUIKitAdapter
import Metal
import PhotosCore
import ProtonAuth
import ProtonDriveBackend
import ProtonCoreCryptoPatchedGoImplementation
import SwiftUI
import TimelineUIKitAdapter
import TimelineUIKitFeature
import UIKit

@main
struct ProtonPhotosMobileApp: App {
    @StateObject private var sessionModel = MobileSessionModel()
    @StateObject private var timelineModel = MobileTimelineModel()

    var body: some Scene {
        WindowGroup {
            MobileRootView()
                .environmentObject(sessionModel)
                .environmentObject(timelineModel)
                .task {
                    timelineModel.configure(session: sessionModel.session, store: sessionModel.sessionStore)
                }
                .onChange(of: sessionModel.session) { _, session in
                    timelineModel.configure(session: session, store: sessionModel.sessionStore)
                }
        }
    }
}

private struct MobileRootView: View {
    @EnvironmentObject private var sessionModel: MobileSessionModel
    @EnvironmentObject private var timelineModel: MobileTimelineModel

    private let metalStatus = MobileMetal3Runtime.status()

    var body: some View {
        ZStack {
            ProtonColor.backgroundNorm.ignoresSafeArea()

            if !metalStatus.isSupported {
                MobileUnsupportedDeviceView(message: metalStatus.message)
            } else if sessionModel.session == nil {
                MobileLoginView()
            } else if let feed = timelineModel.thumbnailFeed {
                MobileTimelineShell(
                    email: sessionModel.accountLabel,
                    items: timelineModel.items,
                    thumbnailFeed: feed
                )
            } else {
                VStack(spacing: 10) {
                    ProgressView()
                        .tint(ProtonColor.primary)
                    Text(timelineModel.statusText)
                        .font(.footnote)
                        .foregroundStyle(ProtonColor.textWeak)
                    if let error = timelineModel.errorText {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                }
            }
        }
    }
}

private struct MobileLoginView: View {
    @EnvironmentObject private var sessionModel: MobileSessionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Proton Photos")
                .font(.largeTitle.weight(.semibold))
                .foregroundStyle(ProtonColor.textNorm)

            Text(sessionModel.statusText)
                .font(.body)
                .foregroundStyle(ProtonColor.textWeak)

            if let error = sessionModel.errorText {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            Button {
                sessionModel.signIn()
            } label: {
                HStack(spacing: 10) {
                    if sessionModel.isSigningIn {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(sessionModel.isSigningIn ? "Waiting for browser sign-in" : "Sign in with Proton")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(sessionModel.isSigningIn)
        }
        .padding(24)
        .frame(maxWidth: 520, alignment: .leading)
    }
}

private struct MobileTimelineShell: View {
    @EnvironmentObject private var sessionModel: MobileSessionModel
    @State private var selectedRoute: MobileLibraryRoute? = .allPhotos

    let email: String
    let items: [PhotoItem]
    let thumbnailFeed: UIKitThumbnailFeed

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedRoute) {
                Section {
                    NavigationLink(value: MobileLibraryRoute.allPhotos) {
                        Label("All Photos", systemImage: "square.grid.3x3.fill")
                    }
                    NavigationLink(value: MobileLibraryRoute.albums) {
                        Label("Albums", systemImage: "rectangle.stack")
                    }
                    NavigationLink(value: MobileLibraryRoute.map) {
                        Label("Map", systemImage: "map")
                    }
                }
                Section {
                    Button(role: .destructive) {
                        sessionModel.signOut()
                    } label: {
                        Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            }
            .navigationTitle("Library")
        } detail: {
            switch selectedRoute ?? .allPhotos {
            case .allPhotos:
                MobileAllPhotosView(email: email, items: items, thumbnailFeed: thumbnailFeed)
            case .albums:
                MobilePlaceholderView(
                    title: "Albums",
                    systemImage: "rectangle.stack",
                    message: "Album UI is not wired in this simulator shell yet."
                )
            case .map:
                MobilePlaceholderView(
                    title: "Map",
                    systemImage: "map",
                    message: "Map UI is not wired in this simulator shell yet."
                )
            }
        }
    }
}

private enum MobileLibraryRoute: Hashable {
    case allPhotos
    case albums
    case map
}

private struct MobileAllPhotosView: View {
    let email: String
    let items: [PhotoItem]
    let thumbnailFeed: UIKitThumbnailFeed

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("All Photos")
                        .font(.headline)
                        .foregroundStyle(ProtonColor.textNorm)
                    Text(email)
                        .font(.caption)
                        .foregroundStyle(ProtonColor.textHint)
                }
                Spacer()
                Text("\(items.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(ProtonColor.textHint)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            UIKitTimelineGrid(items: items, thumbnailFeed: thumbnailFeed)
                .ignoresSafeArea(edges: .bottom)
        }
        .background(ProtonColor.backgroundNorm)
    }
}

private struct MobilePlaceholderView: View {
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(ProtonColor.primary)
            Text(title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(ProtonColor.textNorm)
            Text(message)
                .font(.body)
                .foregroundStyle(ProtonColor.textWeak)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ProtonColor.backgroundNorm)
    }
}

private struct MobileUnsupportedDeviceView: View {
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Unsupported Device")
                .font(.title2.weight(.semibold))
                .foregroundStyle(ProtonColor.textNorm)
            Text(message)
                .font(.body)
                .foregroundStyle(ProtonColor.textWeak)
        }
        .padding(24)
        .frame(maxWidth: 520, alignment: .leading)
    }
}

@MainActor
private final class MobileSessionModel: ObservableObject {
    @Published private(set) var session: ProtonSession?
    @Published private(set) var isSigningIn = false
    @Published private(set) var statusText = "Sign in through Proton in Safari. The app stores only the resulting session in the iOS Keychain."
    @Published private(set) var errorText: String?

    let sessionStore = SessionKeychainStore()
    private let authController: ProtonAuthController

    var accountLabel: String {
        session?.uid ?? "Signed in"
    }

    init() {
        injectDefaultCryptoImplementation()
        self.authController = ProtonAuthController(
            store: sessionStore,
            authenticator: ProtonForkAuthenticator(config: .externalDriveProtonPhotos)
        )
        apply(authController.bootstrap())
    }

    func signIn() {
        authController.signIn(
            openURL: { url in
                Task { @MainActor in
                    UIApplication.shared.open(url)
                }
            },
            onStateChange: { [weak self] state in
                self?.apply(state)
            }
        )
    }

    func signOut() {
        apply(authController.signOut())
    }

    private func apply(_ state: ProtonAuthState) {
        switch state {
        case .checking:
            session = nil
            isSigningIn = false
            errorText = nil
            statusText = "Checking session"
        case let .signedOut(error):
            session = nil
            isSigningIn = false
            errorText = error
            statusText = error == nil
                ? "Sign in through Proton in Safari. The app stores only the resulting session in the iOS Keychain."
                : "Sign-in failed"
        case let .authenticating(progress):
            session = nil
            isSigningIn = true
            errorText = nil
            statusText = Self.label(for: progress)
        case let .signedIn(session):
            self.session = session
            isSigningIn = false
            errorText = nil
            statusText = "Signed in"
        }
    }

    private static func label(for progress: ProtonForkAuthenticator.Progress) -> String {
        switch progress {
        case .requestingLink: "Requesting sign-in link"
        case .waitingForBrowser: "Complete sign-in in Safari"
        case .finalizing: "Finalizing session"
        }
    }
}

@MainActor
private final class MobileTimelineModel: ObservableObject {
    @Published private(set) var items: [PhotoItem] = []
    @Published private(set) var thumbnailFeed: UIKitThumbnailFeed?
    @Published private(set) var statusText = "Preparing library"
    @Published private(set) var errorText: String?

    private var configuredUID: String?
    private var facade: ProtonClientFacade?
    private var backendTask: Task<Void, Never>?

    func configure(session: ProtonSession?, store: SessionKeychainStore) {
        backendTask?.cancel()
        guard let session else {
            configuredUID = nil
            facade = nil
            items = []
            thumbnailFeed = nil
            statusText = "Signed out"
            errorText = nil
            return
        }

        guard configuredUID != session.uid || facade == nil else { return }
        configuredUID = session.uid
        facade = nil
        items = []
        thumbnailFeed = nil
        statusText = "Preparing library"
        errorText = nil

        let cache = ThumbnailCache(
            namespace: "mobile-thumbnails",
            derivative: "thumbnail",
            configuration: UIKitMediaCachePolicy.thumbnailByteCacheConfiguration()
        )
        cache.configure(
            accountUID: session.uid,
            key: LocalCacheKeyDerivation.thumbnailPreviewCacheKey(
                accountUID: session.uid,
                keyPassword: session.keyPassword
            )
        )

        backendTask = Task { [weak self] in
            guard let self else { return }
            do {
                let client = try await ProtonDriveBackendFactory.makeFacade(
                    session: session,
                    store: store,
                    policy: .standard(
                        libraryDatabasePolicy: ProtonDriveBackendPolicy.mobileLibraryDatabasePolicy,
                        videoCacheBudgetBytes: 128 * 1024 * 1024
                    )
                )
                let backend = client.backend
                let dimensions = PhotoDimensionCoalescer(store: backend)
                let feed = UIKitThumbnailFeed(
                    cache: cache,
                    loader: backend,
                    dimensions: dimensions,
                    targetPixels: 288
                )

                self.facade = client
                self.thumbnailFeed = feed
                self.statusText = "Loading library"

                if let cached = await backend.cachedTimeline() {
                    apply(cached)
                    await feed.startPrefetch(ThumbnailCrawlOrder.newestToOldest(items))
                }

                let refreshed = try await backend.loadTimeline()
                try Task.checkCancellation()
                apply(refreshed)
                await feed.startPrefetch(ThumbnailCrawlOrder.newestToOldest(items))
                statusText = items.isEmpty ? "No photos" : "Ready"
            } catch is CancellationError {
                // A newer session/configuration replaced this task.
            } catch {
                facade = nil
                thumbnailFeed = nil
                statusText = "Library failed"
                errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func apply(_ sections: [TimelineSection]) {
        items = sections.flatMap(\.items).sorted(by: TimelineOrder.areInIncreasingOrder)
    }
}

private struct MobileMetal3Runtime {
    let isSupported: Bool
    let message: String

    static func status() -> Self {
        guard let device = MTLCreateSystemDefaultDevice() else {
            return Self(isSupported: false, message: "This device does not expose a Metal renderer.")
        }
        guard UIKitTimelineMetalCapability.supportsTimelineGrid(device: device) else {
            return Self(isSupported: false, message: "Proton Photos for iOS/iPadOS requires a Metal 3-capable Apple GPU.")
        }
        return Self(isSupported: true, message: device.name)
    }
}
