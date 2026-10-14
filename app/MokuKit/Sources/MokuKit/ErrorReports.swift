import Foundation

/// An error Moku carried on from but shouldn't have had: the brain not answering, an answer it couldn't read, an update
/// that failed, a file it couldn't load or save. It goes out as the usage event `app_error`, which the relay passes to
/// PostHog as an `$exception` with level "error", so it's seen before anyone has to write in.
///
/// Fixed words and numbers only, like every usage event: what kind of thing failed, the error's family and number, and
/// where in Moku's own code (a file and a function). Never the error's message, a path, or anything about the screen,
/// the person or their work.
public struct ErrorReport: Sendable, Equatable {
    /// What failed.
    public enum Kind: String, Sendable, CaseIterable {
        /// The app asking its brain: no answer (not running, refused), no answer in time, a 5xx, a 4xx it shouldn't
        /// get (the app and the brain disagree), or an answer that doesn't match the contract.
        case brainUnreachable = "brain_unreachable", brainTimeout = "brain_timeout", brain5xx = "brain_5xx"
        case brainRefused = "brain_refused", brainDecode = "brain_decode"
        /// The relay answered 200 with something the app can't read (a token, the switches).
        case relayDecode = "relay_decode"
        /// The Mac said it could attest to Apple (App Attest) and Apple or the Mac refused: a build whose entitlement or
        /// profile is wrong, or Apple's service down. The trial goes on without a statement.
        case attestFailed = "attest_failed"
        /// Sparkle couldn't check, download or install an update.
        case sparkle
        /// A character, clip or house piece didn't load.
        case assetLoad = "asset_load"
        /// A file in ~/.moku couldn't be written.
        case writeFailed = "write_failed"
        /// The brain's own errors, counted there and read from its /health (brain-go errors.go): a request that failed
        /// inside it, a background task, giving disk space back, a damaged database set aside.
        case brainRequest = "brain_request", brainTask = "brain_task", brainDisk = "brain_disk", brainStore = "brain_store"
    }

    public var kind: Kind
    /// The error's family, one of `ErrorReports.domains`.
    public var domain: String
    /// The error's number in its family (an HTTP status for "http").
    public var code: Int
    /// Where in Moku's code: "BrainClient.swift:today" or "app.go:NewHandler.func1".
    public var place: String
    /// How many times (the brain's counts can hold several).
    public var count: Int

    public init(kind: Kind, domain: String, code: Int, place: String, count: Int = 1) {
        self.kind = kind; self.domain = domain; self.code = code; self.place = place; self.count = count
    }
}

/// Where `ErrorReport`s come from: any part of Moku calls `report` where it catches an error it carries on from.
public enum ErrorReports {
    /// Where reports go: the app sets it at launch (MokuMind's `ErrorLog`). Unset (tests, the demo), nothing is sent.
    @MainActor public static var sink: (@MainActor (ErrorReport) -> Void)?

    /// The error families a report may name.
    public static let domains: Set<String> = ["url", "http", "decoding", "cocoa", "posix", "osstatus", "sparkle", "moku", "go", "other"]

    /// Whether `text` is a place in Moku's own code: a source file's name, a colon, and a function's name. The relay
    /// checks the same (proxy/api/_lib/events.js, PLACE).
    public static func isPlace(_ text: String) -> Bool {
        text.wholeMatch(of: /[A-Za-z0-9_+]{1,48}\.(?:swift|go):[A-Za-z_][A-Za-z0-9_.]{0,63}/) != nil
    }

    /// Reports `error` (or, without one, `domain` and `code`) from wherever it was caught, on any thread. The file and
    /// function are the caller's own.
    public static func report(_ kind: ErrorReport.Kind, _ error: (any Error)? = nil, domain: String? = nil, code: Int? = nil,
                              file: String = #fileID, function: String = #function) {
        let family = error.map(classify) ?? (domain: "moku", code: 0)
        let report = ErrorReport(kind: kind, domain: domain.map { domains.contains($0) ? $0 : "other" } ?? family.domain,
                                 code: code ?? family.code, place: place(file: file, function: function))
        Task { @MainActor in sink?(report) }
    }

    /// An error's family and number: what kind of error it is, never what it says.
    public static func classify(_ error: any Error) -> (domain: String, code: Int) {
        if let decoding = error as? DecodingError {
            switch decoding {
            case .typeMismatch: return ("decoding", 1)
            case .valueNotFound: return ("decoding", 2)
            case .keyNotFound: return ("decoding", 3)
            case .dataCorrupted: return ("decoding", 4)
            @unknown default: return ("decoding", 0)
            }
        }
        let error = error as NSError
        let domain = switch error.domain {
        case NSURLErrorDomain: "url"
        case NSCocoaErrorDomain: "cocoa"
        case NSPOSIXErrorDomain: "posix"
        case NSOSStatusErrorDomain: "osstatus"
        case "SUSparkleErrorDomain": "sparkle"
        case let name where name.hasPrefix("Moku"): "moku"  // our own: "MokuMind.BrainError", "MokuVisual"
        default: "other"
        }
        return (domain, min(max(error.code, Int(Int32.min)), Int(Int32.max)))
    }

    /// "MokuMind/BrainClient.swift" and "today(date:)" → "BrainClient.swift:today"; anything that doesn't look like a
    /// place in code is "unknown".
    public static func place(file: String, function: String) -> String {
        let name = file.split(separator: "/").last.map(String.init) ?? file
        let function = function.prefix { $0 != "(" }
        let place = "\(name):\(function)"
        return isPlace(place) ? place : "unknown.swift:unknown"
    }
}
