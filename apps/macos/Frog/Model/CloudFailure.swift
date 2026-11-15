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
