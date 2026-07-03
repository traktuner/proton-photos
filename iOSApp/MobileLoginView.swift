import DesignSystemCore
import PhotosCore
import SwiftUI

struct MobileLoginView: View {
    @EnvironmentObject private var sessionModel: MobileSessionModel

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "photo.stack.fill")
                .font(.system(size: 56, weight: .regular))
                .foregroundStyle(ProtonColor.primary)

            VStack(spacing: 8) {
                Text(ProductBrand.displayName)
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(ProtonColor.textNorm)
                Text(sessionModel.statusText)
                    .font(.body)
                    .foregroundStyle(ProtonColor.textWeak)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }

            if let error = sessionModel.errorText {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            Button {
                sessionModel.signIn()
            } label: {
                HStack(spacing: 10) {
                    if sessionModel.isSigningIn {
                        ProgressView().controlSize(.small).tint(.white)
                    }
                    Text(sessionModel.isSigningIn ? "Waiting for browser sign-in…" : "Sign in with Proton")
                        .font(.body.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(ProtonColor.primary)
            .disabled(sessionModel.isSigningIn)

            Text("Sign-in opens Safari. The app stores only the resulting session in the iOS Keychain.")
                .font(.caption)
                .foregroundStyle(ProtonColor.textHint)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: 460)
    }
}
