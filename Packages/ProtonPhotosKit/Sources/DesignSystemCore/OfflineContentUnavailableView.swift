import SwiftUI

public struct OfflineContentUnavailableView: View {
    public init() {}

    public var body: some View {
        ContentUnavailableView {
            Label("offline.content_title", systemImage: "bolt.slash")
        } description: {
            Text("offline.content_message")
        }
    }
}
