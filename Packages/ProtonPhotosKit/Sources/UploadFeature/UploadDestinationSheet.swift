import SwiftUI
import PhotosCore
import UploadCore

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
                Section(L10n.string("upload.destination_section")) {
                    Picker(L10n.string("upload.destination_section"), selection: $mode) {
                        Text(L10n.string("upload.destination_library")).tag(Mode.library)
                        Text(L10n.string("upload.destination_existing_album")).tag(Mode.existing)
                            .disabled(!coordinator.canAddToAlbum)
                        Text(L10n.string("upload.destination_new_album")).tag(Mode.newAlbum)
                            .disabled(!coordinator.canCreateAlbum)
                    }
                    #if os(macOS)
                    .pickerStyle(.radioGroup)
                    #else
                    .pickerStyle(.inline)
                    #endif

                    destinationDetails
                }

                if mode != .library, coordinator.canSetAlbumCover {
                    Section {
                        Toggle(L10n.string("upload.use_first_as_cover"), isOn: $useFirstAsCover)
                            #if os(macOS)
                            .toggleStyle(.checkbox)
                            #endif
                    }
                }

                Section {
                    Text(summary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(L10n.string("upload.title"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("action.cancel")) { coordinator.cancelDestination(); dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("upload.confirm")) { confirm(); dismiss() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canConfirm)
                }
            }
        }
        #if os(macOS)
        .frame(width: 420, height: 360)
        #endif
    }

    @ViewBuilder private var destinationDetails: some View {
        switch mode {
        case .library:
            caption(L10n.string("upload.library_caption"))
        case .existing:
            if !coordinator.canAddToAlbum {
                readOnlyAlbumsMessage
            } else if coordinator.albums.isEmpty {
                caption(L10n.string("upload.no_albums"))
            } else {
                LabeledContent(L10n.string("upload.album_label")) {
                    Picker(L10n.string("upload.album_label"), selection: $selectedAlbumID) {
                        Text(L10n.string("upload.choose_placeholder")).tag(String?.none)
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
                LabeledContent(L10n.string("upload.album_name")) {
                    TextField(L10n.string("upload.album_name"), text: $newAlbumName)
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
    }

    private var readOnlyAlbumsMessage: some View {
        Label(L10n.string("upload.albums_readonly"), systemImage: "lock")
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
            L10n.string("upload.destination_summary \(destination.summary)")
        } else {
            L10n.string("upload.choose_destination")
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
