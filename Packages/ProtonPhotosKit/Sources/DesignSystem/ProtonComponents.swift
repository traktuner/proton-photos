import SwiftUI

// MARK: - Primary button (Proton style)

public struct ProtonPrimaryButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(ProtonColor.textNorm)
            .padding(.horizontal, 20)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(configuration.isPressed ? ProtonColor.primaryActive : ProtonColor.primary)
            )
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

public extension ButtonStyle where Self == ProtonPrimaryButtonStyle {
    static var proton: ProtonPrimaryButtonStyle { .init() }
}

// MARK: - Branded loading spinner

/// Proton-style circular spinner: an indeterminate arc in brand purple.
public struct ProtonSpinner: View {
    @State private var rotation = 0.0
    private let size: CGFloat
    private let lineWidth: CGFloat

    public init(size: CGFloat = 28, lineWidth: CGFloat = 3) {
        self.size = size
        self.lineWidth = lineWidth
    }

    public var body: some View {
        Circle()
            .trim(from: 0, to: 0.22)
            .stroke(
                ProtonColor.primary,
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
            )
            .frame(width: size, height: size)
            .rotationEffect(.degrees(rotation))
            .onAppear {
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
            .accessibilityLabel("Loading")
    }
}

/// Full-screen centered loading state with an optional caption.
public struct ProtonLoadingView: View {
    private let caption: String?
    public init(caption: String? = nil) { self.caption = caption }

    public var body: some View {
        VStack(spacing: 16) {
            ProtonSpinner(size: 34, lineWidth: 3.5)
            if let caption {
                Text(caption)
                    .font(.system(size: 13))
                    .foregroundStyle(ProtonColor.textWeak)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ProtonColor.backgroundNorm)
    }
}
