import Foundation

/// The branch suffix a row shows next to its title (a worktree's branch name). Nested rows are
/// narrow, so the suffix is dropped when it only repeats the title — slugged titles like
/// "sandbox pro" in worktree "sandbox-pro-docs" read as "sandbox pro…" twice and squeeze the
/// title. A suffix that says something the title doesn't stays.
enum RowSuffix {
    /// The suffix `title` should show, or nil when it's redundant.
    ///
    /// Redundant when the suffix, unslugged (hyphens/underscores → spaces, case folded), is
    /// contained in the title, or the title in it: "sandbox pro" ⊂ "sandbox-pro-docs" hides the
    /// suffix; "Add tests" in worktree "feat/sidebar" keeps it.
    static func visible(_ suffix: String?, title: String) -> String? {
        guard let suffix else { return nil }
        let slug = unslug(suffix)
        guard !slug.isEmpty else { return nil }
        let t = unslug(title)
        if t.isEmpty { return suffix }
        if t.contains(slug) || slug.contains(t) { return nil }
        return suffix
    }

    /// Case-folded with hyphens and underscores as spaces, trimmed.
    static func unslug(_ s: String) -> String {
        s.replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
