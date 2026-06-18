import SwiftUI
import DesignSystem

struct LoginView: View {
    let model: AppModel

    var body: some View {
        ZStack {
            ProtonColor.backgroundNorm.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()
                brand
                    .padding(.bottom, 36)
                content
                    .frame(maxWidth: 320)
                Spacer()
                footer
            }
            .padding(40)
        }
    }

    private var brand: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(ProtonColor.primary.opacity(0.16))
                    .frame(width: 84, height: 84)
                Image(systemName: "photo.stack.fill")
                    .font(.system(size: 38, weight: .medium))
                    .foregroundStyle(ProtonColor.primary)
            }
            Text("Proton Photos")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(ProtonColor.textNorm)
            Text("Your photos, end-to-end encrypted.")
                .font(.system(size: 13))
                .foregroundStyle(ProtonColor.textWeak)
        }
    }

    @ViewBuilder private var content: some View {
        switch model.auth {
        case let .authenticating(status):
            VStack(spacing: 16) {
                ProgressView().controlSize(.large)
                Text(status)
                    .font(.system(size: 13))
                    .foregroundStyle(ProtonColor.textWeak)
                    .multilineTextAlignment(.center)
                Button("Cancel") { model.cancelSignIn() }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(ProtonColor.textHint)
            }
        default:
            VStack(spacing: 14) {
                Button {
                    model.signIn()
                } label: {
                    Text("Sign in with Proton")
                }
                .buttonStyle(.glassProminent)

                if case let .signedOut(error?) = model.auth {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(ProtonColor.danger)
                        .multilineTextAlignment(.center)
                }

                Text("Opens your browser to sign in securely. No password is ever entered in this app.")
                    .font(.system(size: 11))
                    .foregroundStyle(ProtonColor.textHint)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var footer: some View {
        Text("Proton AG · Encrypted by default")
            .font(.system(size: 11))
            .foregroundStyle(ProtonColor.textHint)
    }
}
