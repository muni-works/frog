import FoundationModels

/// Apple's on-device model, as frog runs it through its `frog-apple` sidecar.
enum AppleIntelligence {
    static let spec = "apple/on-device"

    /// Whether this Mac can run it now (Apple Intelligence on, and the model ready).
    static var available: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }
}
