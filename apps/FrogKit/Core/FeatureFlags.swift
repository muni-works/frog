import Foundation

/// Build-time feature switches: off here means the feature's code paths are guarded out of the
/// UI without being deleted — flipping a constant brings it back.
enum FeatureFlags {
    /// The chief of staff (`Library.makeChief`, the sidebar's chief tile and its org-tree root).
    /// Off: "it's too complex for new users" (Cam). The pattern stays available without the
    /// feature — see README, "The chief pattern": run a long-lived session in a workspace, keep
    /// it pinned, hang the sessions it started under it. A saved chief stays saved; it just
    /// doesn't render or special-case until this is on again.
    static let chief = false
}
