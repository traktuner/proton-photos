import SwiftUI
import PhotosCore

/// Lets the user pick where a queued batch lands: the library, an existing album, or a new album,
/// with an optional "use first uploaded photo as cover". Album options are disabled (with an honest
/// caption) when the wired backend can't perform that write — never silently degraded.
public struct UploadDestinationSheet: View {
    @Bindable private var coordinator: UploadCoordinator
    @Environment(\.dismiss) private var dismiss

    private enum Mode: Hashable { case library, existing, newAlbum }

    @State private var mode: Mode = .library
    @State private var selectedAlbumID: String?
    @State private var newAlbumName: String = ""
    @State private var useFirstAsCover = false

    public init(coordinator: UploadCoordinator) {
        self._coordinator = Bindable(coordinator)
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Destination") {
                    Picker("Destination", selection: $mode) {
                        Text("Library").tag(Mode.library)
                        Text("Existing Album").tag(Mode.existing)
                            .disabled(!coordinator.canAddToAlbum)
                        Text("New Album").tag(Mode.newAlbum)
                            .disabled(!coordinator.canCreateAlbum)
                    }
                    .pickerStyle(.radioGroup)

                    destinationDetails
                }

                if mode != .library, coordinator.canSetAlbumCover {
                    Section {
                        Toggle("Use first uploaded photo as album cover", isOn: $useFirstAsCover)
                            .toggleStyle(.checkbox)
                    }
                }

                Section {
                    Text(summary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Upload")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { coordinator.cancelDestination(); dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Upload") { confirm(); dismiss() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canConfirm)
                }
            }
        }
        .frame(width: 420, height: 360)
    }

    @ViewBuilder private var destinationDetails: some View {
        switch mode {
        case .library:
            caption("Photos will be added to your library.")
        case .existing:
            if !coordinator.canAddToAlbum {
                readOnlyAlbumsMessage
            } else if coordinator.albums.isEmpty {
                caption("No albums are available.")
            } else {
                LabeledContent("Album") {
                    Picker("Album", selection: $selectedAlbumID) {
                        Text("Choose…").tag(String?.none)
                        ForEach(coordinator.albums) { album in
                            Text(album.title).tag(String?.some(album.id))
                        }
                    }
                    .labelsHidden()
                }
            }
        case .newAlbum:
            if !coordinator.canCreateAlbum {
                readOnlyAlbumsMessage
            } else {
                LabeledContent("Album name") {
                    TextField("Album name", text: $newAlbumName)
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
    }

    private var readOnlyAlbumsMessage: some View {
        Label("Albums are currently read-only in this build.", systemImage: "lock")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var canConfirm: Bool {
        switch mode {
        case .library: return true
        case .existing: return coordinator.canAddToAlbum && selectedAlbumID != nil
        case .newAlbum: return coordinator.canCreateAlbum &&
            !newAlbumName.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private var summary: String {
        if let destination {
            "Destination: \(destination.summary)"
        } else {
            "Choose a destination"
        }
    }

    private var destination: UploadDestination? {
        let cover: UploadDestination.Cover = (useFirstAsCover && coordinator.canSetAlbumCover) ? .firstUploaded : .unchanged
        switch mode {
        case .library:
            return UploadDestination(target: .library)
        case .existing:
            guard let id = selectedAlbumID,
                  let album = coordinator.albums.first(where: { $0.id == id }) else {
                return nil
            }
            return UploadDestination(target: .existingAlbum(id: album.id, title: album.title), cover: cover)
        case .newAlbum:
            return UploadDestination(target: .newAlbum(name: newAlbumName.trimmingCharacters(in: .whitespaces)), cover: cover)
        }
    }

    private func confirm() {
        guard let destination else { return }
        coordinator.confirm(destination: destination)
    }
}
