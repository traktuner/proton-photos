import CoreGraphics
import CryptoKit
import DesignSystemCore
import ImageIO
import MediaByteCache
import MediaCacheUIKitAdapter
import Metal
import PhotosCore
import ProtonAuth
import SwiftUI
import TimelineUIKitFeature
import UIKit
import UniformTypeIdentifiers

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
                    timelineModel.configure(session: sessionModel.session)
                }
                .onChange(of: sessionModel.session) { _, session in
                    timelineModel.configure(session: session)
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
                ProgressView()
                    .tint(ProtonColor.primary)
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

    let email: String
    let items: [PhotoItem]
    let thumbnailFeed: UIKitThumbnailFeed

    var body: some View {
        NavigationSplitView {
            List {
                Section {
                    Label("All Photos", systemImage: "square.grid.3x3.fill")
                    Label("Albums", systemImage: "rectangle.stack")
                    Label("Map", systemImage: "map")
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

    private let store = SessionKeychainStore()

    var accountLabel: String {
        session?.uid ?? "Signed in"
    }

    init() {
        session = store.load()
        if session != nil {
            statusText = "Signed in"
        }
    }

    func signIn() {
        guard !isSigningIn else { return }
        isSigningIn = true
        errorText = nil
        statusText = "Requesting sign-in link"

        Task {
            do {
                let authenticator = ProtonForkAuthenticator()
                let session = try await authenticator.authenticate(
                    openURL: { url in
                        Task { @MainActor in
                            UIApplication.shared.open(url)
                        }
                    },
                    onProgress: { [weak self] progress in
                        Task { @MainActor in
                            self?.statusText = Self.label(for: progress)
                        }
                    }
                )
                store.save(session)
                self.session = session
                statusText = "Signed in"
            } catch {
                errorText = error.localizedDescription
                statusText = "Sign-in failed"
            }
            isSigningIn = false
        }
    }

    func signOut() {
        store.clear()
        session = nil
        statusText = "Sign in through Proton in Safari. The app stores only the resulting session in the iOS Keychain."
        errorText = nil
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
    @Published private(set) var items: [PhotoItem] = MobileTimelineModel.demoItems
    @Published private(set) var thumbnailFeed: UIKitThumbnailFeed?

    private var configuredUID: String?

    func configure(session: ProtonSession?) {
        let accountUID = session?.uid ?? "mobile-smoke"
        guard configuredUID != accountUID else { return }
        configuredUID = accountUID

        let cache = ThumbnailCache(
            namespace: "mobile-thumbnails",
            derivative: "thumbnail",
            configuration: UIKitMediaCachePolicy.thumbnailByteCacheConfiguration()
        )
        if let session {
            cache.configure(
                accountUID: session.uid,
                key: LocalCacheKeyDerivation.thumbnailPreviewCacheKey(
                    accountUID: session.uid,
                    keyPassword: session.keyPassword
                )
            )
        } else {
            cache.configure(accountUID: accountUID)
        }

        thumbnailFeed = UIKitThumbnailFeed(
            cache: cache,
            loader: MobileSyntheticThumbnailLoader(),
            targetPixels: 288
        )
        if let thumbnailFeed {
            Task {
                await thumbnailFeed.startPrefetch(items.map(\.uid))
            }
        }
    }

    private static let demoItems: [PhotoItem] = {
        let now = Date()
        return (0 ..< 360).map { index in
            PhotoItem(
                uid: PhotoUID(volumeID: "mobile-smoke", nodeID: "photo-\(index)"),
                captureTime: now.addingTimeInterval(TimeInterval(-index * 900)),
                mediaType: index.isMultiple(of: 11) ? "video/quicktime" : "image/jpeg",
                isLivePhoto: index.isMultiple(of: 17),
                durationSeconds: index.isMultiple(of: 11) ? 8 : nil,
                tags: index.isMultiple(of: 13) ? [.favorites] : []
            )
        }
    }()
}

private struct MobileMetal3Runtime {
    let isSupported: Bool
    let message: String

    static func status() -> Self {
        guard let device = MTLCreateSystemDefaultDevice() else {
            return Self(isSupported: false, message: "This device does not expose a Metal renderer.")
        }
        guard device.supportsFamily(.apple7) else {
            return Self(isSupported: false, message: "Proton Photos for iOS/iPadOS requires a Metal 3-capable Apple GPU.")
        }
        return Self(isSupported: true, message: device.name)
    }
}

private struct MobileSyntheticThumbnailLoader: ThumbnailBatchLoader {
    func loadThumbnails(
        for uids: [PhotoUID],
        onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
    ) async -> ThumbnailBatchLoadResult {
        for uid in uids {
            if let data = Self.thumbnailData(for: uid) {
                onLoaded(uid, data)
            }
        }
        return .delivered
    }

    private static func thumbnailData(for uid: PhotoUID) -> Data? {
        let side = 288
        let bytesPerRow = side * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * side)
        let seed = abs(uid.nodeID.hashValue)
        let r = UInt8(50 + seed % 170)
        let g = UInt8(50 + (seed / 7) % 170)
        let b = UInt8(50 + (seed / 17) % 170)

        for y in 0 ..< side {
            for x in 0 ..< side {
                let offset = y * bytesPerRow + x * 4
                let shade = UInt8((x + y + seed % 97) % 48)
                pixels[offset] = r &+ shade
                pixels[offset + 1] = g &+ shade / 2
                pixels[offset + 2] = b
                pixels[offset + 3] = 255
            }
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                width: side,
                height: side,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              )
        else { return nil }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
