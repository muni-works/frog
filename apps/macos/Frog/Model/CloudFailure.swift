import Foundation

/// The engine took the browser's key but couldn't save it (no `frog`, or it failed).
enum SignInError: Error { case notSaved }

extension CloudAccount {
    /// What a failed sign-in says, the same everywhere (sidebar, Settings › Models, Billing);
    /// nil when you cancelled it yourself. Never the system's or the server's own words.
    static func signInFailure(_ error: Error) -> String? {
        if error is CancellationError { return nil }
        if case SignInError.notSaved = error { return "Signed in, but Frog couldn't save your key. Try again." }
        if let e = error as? URLError {
            switch e.code {
            case .cancelled: return nil
            case .timedOut: return "Sign-in timed out. Try again."
            default: if CloudFailure.offline(e) { return CloudFailure.offlineText }
            }
        }
        return "Sign-in didn't finish. Try again."
    }
}

/// Plain words for Frog Cloud failures outside sign-in (Run in Frog Cloud, the session list):
/// the gateway's own error text and URLSession's "The operation couldn't be completed" never
/// reach the screen.
enum CloudFailure {
    static let offlineText = "Can't reach Frog Cloud. Check your connection and try again."

    static func offline(_ e: URLError) -> Bool {
        [.notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
         .dnsLookupFailed, .timedOut, .dataNotAllowed, .internationalRoamingOff,
         .secureConnectionFailed].contains(e.code)
    }

    /// A session the gateway lists as `error`, in words (the web's `plainError`): an OS error
    /// number becomes what it means; nothing at all is "The sandbox couldn't start."
    static func session(_ raw: String?) -> String {
        let s = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return "The sandbox couldn't start." }
        if s.range(of: #"\bno session \S+"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return "This session's history isn't in the sandbox anymore, so it couldn't reopen. Start a new session."
        }
        guard let r = s.range(of: #"\(os error (\d+)\)"#, options: [.regularExpression, .caseInsensitive]) else { return s }
        switch Int(s[r].filter(\.isNumber)) {
        case 2: return "A file Frog needed is missing, so it stopped. Try again, or start a new session."
        case 1, 13: return "Frog wasn't allowed to open a file it needs. Try again, or start a new session."
        case 28: return "The sandbox disk is full. Start a new session."
        default: return "Frog hit a system error and stopped. Try again."
        }
    }

    /// `doing` finishes "Couldn't …", e.g. "start a Frog Cloud session".
    static func text(_ error: Error, doing: String) -> String {
        if let e = error as? URLError, offline(e) { return offlineText }
        if let e = error as? CloudGateway.GatewayError {
            switch e.status {
            case 401, 403: return "Your Frog Cloud sign-in has expired. Sign in again."
            case 402: return "You're out of Frog Cloud credit. Add credit in Settings › Billing."
            case 429: return "Frog Cloud is busy. Try again in a moment."
            default: break
            }
        }
        return "Couldn't \(doing). Try again."
    }
}
