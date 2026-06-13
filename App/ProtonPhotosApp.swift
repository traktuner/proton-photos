import SwiftUI
import DesignSystem

@main
struct ProtonPhotosApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .frame(minWidth: 720, minHeight: 480)
                .preferredColorScheme(.dark)
                .task { model.bootstrap() }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1080, height: 720)
    }
}

struct RootView: View {
    let model: AppModel

    var body: some View {
        switch model.auth {
        case .checking:
            ProtonLoadingView()
        case .signedIn:
            MainView(model: model)
        case .signedOut, .authenticating:
            LoginView(model: model)
        }
    }
}
