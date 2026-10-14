import Foundation
import Testing
import MokuKit
@testable import MokuVisual

/// Settings › Moku’s brain: "Get Moku Pro" opens Dodo's checkout, then waits for the payment to land, with no code to type
/// (docs/specs/payments.md).
@MainActor @Suite struct ProCheckoutTests {
    @Test func afterTheCheckoutOpensSettingsWaitsAndThenSaysProIsOn() async throws {
        let model = SettingsModel()
        model.access = AccessStatus(plan: .trial, expiresAt: Date().addingTimeInterval(86_400))
        var asked: [String] = []
        let paid = LockedFlag()
        model.startCheckout = { plan in asked.append(plan); return .success(()) }
        model.loadAccess = { paid.isSet ? AccessStatus(plan: .pro, expiresAt: Date().addingTimeInterval(30 * 86_400)) : AccessStatus(plan: .trial, expiresAt: Date().addingTimeInterval(86_400)) }
        model.proCheckEvery = .milliseconds(20)
        await model.getPro(plan: "yearly")
        #expect(asked == ["yearly"])
        #expect(model.proMessage.contains("checkout"))
        try await Task.sleep(for: .milliseconds(60))
        #expect(model.access?.plan == .trial)
        paid.set()
        try await Task.sleep(for: .milliseconds(80))
        #expect(model.access?.plan == .pro)
        #expect(model.proMessage.contains("Moku Pro is on"))
    }

    @Test func aCheckoutThatCouldNotOpenSaysWhy() async {
        let model = SettingsModel()
        model.startCheckout = { _ in .failure(InviteError("Couldn’t reach Moku’s servers. Check your connection and try again?")) }
        await model.getPro(plan: "monthly")
        #expect(model.proMessage.hasPrefix("Couldn’t reach"))
    }
}

@MainActor private final class LockedFlag { private(set) var isSet = false; func set() { isSet = true } }
