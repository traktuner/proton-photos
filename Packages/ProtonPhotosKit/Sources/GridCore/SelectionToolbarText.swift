/// The center label a selection action bar shows for a given number of selected items — the shared,
/// platform-neutral policy so macOS, iOS, and any future surface phrase selection state identically.
///
/// It is a pure decision over the count only; the platform localizes the two text cases at its own edge
/// (the strings live in each app's String Catalog). The `hidden` case exists because a single selected item
/// needs no count ("1 selected" is noise) — the item's own selected decoration already says it.
public enum SelectionCenterLabel: Equatable, Sendable {
    /// Nothing selected yet → prompt the user to pick items (e.g. "Select items").
    case prompt
    /// Exactly one item selected → show no center text.
    case hidden
    /// More than one selected → show the count (e.g. "3 items selected"); the associated value is that count.
    case count(Int)
}

/// The shared selection-toolbar text policy. Both platforms call `centerLabel(selectedCount:)` and localize
/// the result, so the 0 / 1 / many rule can never drift between them.
public enum SelectionToolbarText {
    /// The center label for `selectedCount` selected items: `prompt` at zero, `hidden` at exactly one, and
    /// `count(n)` for two or more. A negative count is treated as zero (defensive; counts are never negative).
    public static func centerLabel(selectedCount: Int) -> SelectionCenterLabel {
        switch selectedCount {
        case ..<1: return .prompt
        case 1: return .hidden
        default: return .count(selectedCount)
        }
    }
}
