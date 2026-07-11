import SwiftUI

/// Shared native search presentation for every Apple host. Disabled Smart Search contributes no
/// search control at all; when enabled, the system renders a compact magnifier that expands into
/// its native Liquid Glass search field.
public extension View {
    func smartSearchToolbar(
        text: Binding<String>,
        isEnabled: Bool,
        placement: SearchFieldPlacement = .automatic,
        prompt: Text
    ) -> some View {
        modifier(SmartSearchToolbarModifier(
            text: text,
            isEnabled: isEnabled,
            placement: placement,
            prompt: prompt
        ))
    }
}

private struct SmartSearchToolbarModifier: ViewModifier {
    @Binding var text: String
    @State private var isPresented = false
    let isEnabled: Bool
    let placement: SearchFieldPlacement
    let prompt: Text

    @ViewBuilder
    func body(content: Content) -> some View {
        Group {
            if isEnabled {
                enabledContent(content)
            } else {
                content
            }
        }
        .onChange(of: isEnabled) { _, enabled in
            if !enabled {
                text = ""
                isPresented = false
            }
        }
        .onAppear {
            if !isEnabled { text = "" }
        }
    }

    @ViewBuilder
    private func enabledContent(_ content: Content) -> some View {
        #if os(iOS)
        content
            .searchable(text: $text, placement: placement, prompt: prompt)
            .searchToolbarBehavior(.minimize)
        #elseif os(macOS)
        if isPresented {
            content.searchable(
                text: $text,
                isPresented: $isPresented,
                placement: placement,
                prompt: prompt
            )
        } else {
            content.toolbar {
                ToolbarItem {
                    Button {
                        isPresented = true
                    } label: {
                        Label {
                            prompt
                        } icon: {
                            Image(systemName: "magnifyingglass")
                        }
                    }
                    .labelStyle(.iconOnly)
                }
            }
        }
        #else
        content.searchable(text: $text, placement: placement, prompt: prompt)
        #endif
    }
}
