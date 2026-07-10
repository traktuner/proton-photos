import MLSearchCore
import PhotosCore
import SwiftUI

/// The one Smart Search settings surface, shared verbatim by the macOS Settings tab and the
/// iOS/iPadOS settings screen. Pure SwiftUI over the shared controller: every wording, state
/// and confirmation decision lives in Core; hosts only choose the surrounding container.
public struct SmartSearchSettingsSection: View {
    private let controller: MLSmartSearchController
    @State private var pendingModelSwitch: MLModelCatalogEntry?
    @State private var confirmingDisable = false
    @State private var pickingDeveloperArtifact = false

    public init(controller: MLSmartSearchController) {
        self.controller = controller
    }

    public var body: some View {
        Section {
            Toggle(isOn: enabledBinding) {
                Text(L10n.string("mlsearch.settings_title"))
            }
            .accessibilityIdentifier("smartsearch.toggle")

            if controller.snapshot.isEnabled {
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
            if case .success(let url) = result, let selected = controller.snapshot.selectedModelID {
                let accessing = url.startAccessingSecurityScopedResource()
                controller.installDeveloperModel(from: url, for: selected)
                if accessing { url.stopAccessingSecurityScopedResource() }
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
                    // Disabling deletes local models and the index; always confirm.
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
                    // Switching rebuilds local search data; never do it silently.
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

        LabeledContent(L10n.string("mlsearch.status_label")) {
            Text(presentation.statusText)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)

        // Stable progress block: one determinate bar with a fixed slot, no spinner churn and
        // no layout jump between phases.
        if let fraction = presentation.progressFraction {
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .accessibilityLabel(Text(presentation.statusText))
        }
        if let detail = presentation.detailText {
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        if let size = presentation.installedSizeText {
            LabeledContent(L10n.string("mlsearch.model_size_label")) {
                Text(size)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        if presentation.canRetry {
            Button(L10n.string("action.retry")) {
                controller.retry()
            }
        }
        if showsDeveloperInstall {
            Button(L10n.string("mlsearch.install_dev_model")) {
                pickingDeveloperArtifact = true
            }
        }
    }

    /// The local-artifact install path appears only when the environment exposes
    /// developer-only catalog entries (never in Release builds) and the selected model has no
    /// hosted download.
    private var showsDeveloperInstall: Bool {
        let snapshot = controller.snapshot
        guard snapshot.availableModels.contains(where: { $0.releaseTrack == .developerOnly }) else { return false }
        guard case .notInstalled = snapshot.phase else { return false }
        return true
    }
}
