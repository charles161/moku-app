import Foundation
import Testing
@testable import MokuKit

/// Moku's own errors as reports: a family and a number, never what the error says or where on the Mac it was.
@Test func anErrorIsItsFamilyAndNumberNeverItsMessage() {
    let path = "/Users/priya/Documents/Q3 board deck.key"
    let errors: [(any Error, String, Int)] = [
        (URLError(.cannotConnectToHost, userInfo: [NSURLErrorFailingURLStringErrorKey: "http://127.0.0.1:8020/v1/today"]), "url", -1004),
        (CocoaError(.fileWriteOutOfSpace, userInfo: [NSFilePathErrorKey: path]), "cocoa", 640),
        (NSError(domain: NSPOSIXErrorDomain, code: 28, userInfo: [NSLocalizedDescriptionKey: path]), "posix", 28),
        (NSError(domain: NSOSStatusErrorDomain, code: -50), "osstatus", -50),
        (NSError(domain: "SUSparkleErrorDomain", code: 2001), "sparkle", 2001),
        (NSError(domain: "MokuVisual", code: 3, userInfo: [NSLocalizedDescriptionKey: "Skeletons unavailable"]), "moku", 3),
        (NSError(domain: "WhatsApp.Messages", code: 7), "other", 7),
        (NSError(domain: NSCocoaErrorDomain, code: Int.max), "cocoa", Int(Int32.max)),
    ]
    for (error, domain, code) in errors {
        let family = ErrorReports.classify(error)
        #expect(family.domain == domain && family.code == code, "\(error)")
        #expect(ErrorReports.domains.contains(family.domain))
    }
    struct Reply: Decodable { var ok: Bool }
    for (json, code) in [("{\"ok\": 1}", 1), ("{}", 3), ("{", 4)] {
        do {
            _ = try JSONDecoder().decode(Reply.self, from: Data(json.utf8))
            Issue.record("\(json) decoded")
        } catch {
            #expect(ErrorReports.classify(error) == ("decoding", code), "\(json)")
        }
    }
}

@Test func aPlaceIsAFileAndAFunctionInOurCode() {
    #expect(ErrorReports.place(file: "MokuMind/BrainClient.swift", function: "today(date:)") == "BrainClient.swift:today")
    #expect(ErrorReports.place(file: "Moku/QuietUpdates.swift", function: "updater(_:didAbortWithError:)") == "QuietUpdates.swift:updater")
    #expect(ErrorReports.place(file: "MokuVisual/CharacterOverlay.swift", function: "start()") == "CharacterOverlay.swift:start")
    // Nothing else gets through as a place: a title, an address, a path, a name.
    for text in ["Q3 board deck — Confidential.key", "https://mail.google.com/mail/u/0/#inbox", "../etc/passwd", "WhatsApp",
                 "priya@example.com", "step two", "ABC", "BrainClient.swift", "BrainClient.swift:", "a.swift:today(date:)",
                 "/Users/priya/x.swift:today", "x.swift:to day"] {
        #expect(!ErrorReports.isPlace(text), "\(text)")
    }
    #expect(ErrorReports.place(file: "/Users/priya/Moku/x.swift", function: "go") == "x.swift:go")
    #expect(ErrorReports.place(file: "Moku/main.swift", function: "Hey, are we still on?") == "unknown.swift:unknown")
    #expect(ErrorReports.isPlace("app.go:NewHandler.func1"))
}

@MainActor
@Test func aReportGoesToTheSinkWithItsCallersPlace() async {
    var got: [ErrorReport] = []
    ErrorReports.sink = { got.append($0) }
    defer { ErrorReports.sink = nil }
    ErrorReports.report(.writeFailed, CocoaError(.fileWriteNoPermission))
    ErrorReports.report(.brain5xx, domain: "http", code: 503)
    ErrorReports.report(.relayDecode, domain: "Slack", code: 200)
    for _ in 0..<50 where got.count < 3 { await Task.yield() }
    #expect(got == [
        ErrorReport(kind: .writeFailed, domain: "cocoa", code: 513, place: "ErrorReportsTests.swift:aReportGoesToTheSinkWithItsCallersPlace"),
        ErrorReport(kind: .brain5xx, domain: "http", code: 503, place: "ErrorReportsTests.swift:aReportGoesToTheSinkWithItsCallersPlace"),
        ErrorReport(kind: .relayDecode, domain: "other", code: 200, place: "ErrorReportsTests.swift:aReportGoesToTheSinkWithItsCallersPlace"),
    ])
}
