import SwiftUI
import DesignSystem
import MediaCache
import TimelineFeature

struct MainView: View {
    let model: AppModel
    @State private var timelineModel: TimelineViewModel

    init(model: AppModel) {
        self.model = model
        // Placeholder data source for now; swapped for the SDK-backed repository in Phase 2.
        let repo = PlaceholderPhotosRepository()
        _timelineModel = State(
            initialValue: TimelineViewModel(
                repository: repo,
                thumbnails: repo,
                cache: ThumbnailCache()
            )
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(ProtonColor.borderWeak)
            TimelineView(model: timelineModel)
        }
        .background(ProtonColor.backgroundNorm)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Library")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(ProtonColor.textNorm)
            Spacer()
            Menu {
                Button("Sign out", role: .destructive) { model.signOut() }
            } label: {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 18))
                    .foregroundStyle(ProtonColor.textWeak)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }
}
