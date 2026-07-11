import MLSearchCore
import PhotosCore
import SwiftUI

/// Shared Smart Search settings for macOS, iOS and iPadOS.
public struct SmartSearchSettingsSection: View {
    private let controller: MLSmartSearchController
    @State private var pendingModelSwitch: MLModelCatalogEntry?
    @State private var confirmingDisable = false
    @State private var pickingDeveloperArtifact = false

    public init(controller: MLSmartSearchController) {
        self.controller = controller
    }

    public var body: some View {
        let hasSelectableModel = !controller.snapshot.availableModels.isEmpty
        Section {
            Toggle(isOn: enabledBinding) {
                Text(L10n.string("mlsearch.settings_title"))
            }
            .accessibilityIdentifier("smartsearch.toggle")
            .disabled(!hasSelectableModel)

            if !hasSelectableModel {
                Text(L10n.string("mlsearch.status_not_downloadable"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if controller.snapshot.isEnabled {
                modelPicker
                statusRows
            }
        } footer: {
            Text(MLSmartSearchPresentation.privacyStatement)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .confirmationDialog(
            L10n.string("mlsearch.disable_confirm_title"),
            isPresented: $confirmingDisable,
            titleVisibility: .visible
        ) {
            Button(L10n.string("mlsearch.disable_confirm_action"), role: .destructive) {
                controller.disableAndPurge()
            }
            Button(L10n.string("action.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.string("mlsearch.disable_confirm_message"))
        }
        .confirmationDialog(
            L10n.string("mlsearch.switch_confirm_title"),
            isPresented: Binding(
                get: { pendingModelSwitch != nil },
                set: { if !$0 { pendingModelSwitch = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.string("mlsearch.switch_confirm_action")) {
                if let target = pendingModelSwitch {
                    controller.select(target.id)
                }
                pendingModelSwitch = nil
            }
            Button(L10n.string("action.cancel"), role: .cancel) { pendingModelSwitch = nil }
        } message: {
            Text(L10n.string("mlsearch.switch_confirm_message"))
        }
        .fileImporter(
            isPresented: $pickingDeveloperArtifact,
            allowedContentTypes: [.folder]
        ) { result in
            // The controller keeps the security scope open until installation completes.
            if case .success(let url) = result, let selected = controller.snapshot.selectedModelID {
                controller.installDeveloperModel(from: url, for: selected)
            }
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { controller.snapshot.isEnabled },
            set: { enable in
                if enable {
                    controller.setEnabled(true)
                } else {
                    confirmingDisable = true
                }
            }
        )
    }

    @ViewBuilder
    private var modelPicker: some View {
        let snapshot = controller.snapshot
        Picker(
            L10n.string("mlsearch.model_picker"),
            selection: Binding(
                get: { snapshot.selectedModelID },
                set: { newValue in
                    guard let newValue, newValue != snapshot.selectedModelID else { return }
                    pendingModelSwitch = snapshot.availableModels.first { $0.id == newValue }
                }
            )
        ) {
            ForEach(snapshot.availableModels) { model in
                Text(model.displayName).tag(Optional(model.id))
            }
        }
        .disabled(controller.presentation.isBusy)

        if let selected = snapshot.availableModels.first(where: { $0.id == snapshot.selectedModelID }),
           selected.releaseTrack == .developerOnly {
            Text(MLSmartSearchPresentation.developerModelNote)
                .font(.footnote)
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var statusRows: some View {
        let presentation = controller.presentation

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: statusSymbolName)
                    .foregroundStyle(statusColor)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(presentation.statusText)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail = presentation.detailText {
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            ProgressView(value: presentation.progressFraction ?? 0)
                .progressViewStyle(.linear)
                .opacity(presentation.progressFraction == nil ? 0 : 1)
                .accessibilityHidden(presentation.progressFraction == nil)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(presentation.statusText))
        .accessibilityValue(Text(presentation.detailText ?? ""))

        if let size = presentation.modelSizeText {
            LabeledContent(L10n.string("mlsearch.model_size_label")) {
                Text(size)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        if presentation.canRetry {
            Button {
                controller.retry()
            } label: {
                Label(L10n.string("action.retry"), systemImage: "arrow.clockwise")
            }
        }
        if showsDeveloperInstall {
            Button {
                pickingDeveloperArtifact = true
            } label: {
                Label(L10n.string("mlsearch.install_dev_model"), systemImage: "folder.badge.plus")
            }
        }
    }

    private var statusSymbolName: String {
        switch controller.snapshot.phase {
        case .disabled: "minus.circle"
        case .notInstalled: "arrow.down.circle"
        case .downloading: "arrow.down.circle.fill"
        case .verifying: "checkmark.shield"
        case .installing: "square.and.arrow.down"
        case .preparingModel: "cpu"
        case .indexing: "sparkles"
        case .waiting: "pause.circle"
        case .ready: "checkmark.circle.fill"
        case .switchingModel: "arrow.triangle.2.circlepath"
        case .deleting: "trash"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch controller.snapshot.phase {
        case .failed: .orange
        case .ready: .green
        default: .secondary
        }
    }

    private var showsDeveloperInstall: Bool {
        let snapshot = controller.snapshot
        guard snapshot.availableModels.contains(where: { $0.releaseTrack == .developerOnly }) else { return false }
        guard case .notInstalled = snapshot.phase else { return false }
        return true
    }
}
