import AppKit
import MokuKit
import MokuMind
import MokuSense
import MokuVisual

/// The first launch: the welcome window (the companion says hi, the film, the companions, what Moku reads, the two
/// permissions, Start). "Say hi again" in the world menu runs it again. Closing it early is fine; it's offered again on
/// the next launch until it's finished once, or left twice (WelcomeOffer).
@MainActor
enum Onboarding {
    private static let completedKey = "onboardingCompleted"

    static var isCompleted: Bool {
        get { UserDefaults.standard.bool(forKey: completedKey) }
        set { UserDefaults.standard.set(newValue, forKey: completedKey) }
    }

    /// How many times the welcome was left unfinished (Skip for now, or closed), and whether to offer it at this launch
    /// (WelcomeOffer).
    static let earlyExitsKey = "Moku.onboardingEarlyExits"
    static var shouldOffer: Bool {
        WelcomeOffer.shouldOffer(completed: isCompleted, earlyExits: UserDefaults.standard.integer(forKey: earlyExitsKey),
                                 inProgress: MokuVisualFactory.welcomeInProgress)
    }
    static func recordEarlyExit() { UserDefaults.standard.set(UserDefaults.standard.integer(forKey: earlyExitsKey) + 1, forKey: earlyExitsKey) }

    static func context() -> OnboardingContext {
        OnboardingContext(suggestedName: AppLifecycle.suggestedName,
                          permissions: { SenseHub.permissionStatus() },
                          requestPermission: { requestPermission($0) },
                          launchAtLogin: { LaunchAtLogin.isEnabled },
                          setLaunchAtLogin: { on in
                              // A development build is never added (it would open at every login from wherever it was built).
                              guard !on || LoginItemConsent.mayRegister(bundlePath: Bundle.main.bundlePath) else { AppLog.write("launch at login: not added (not in Applications)"); return }
                              LaunchAtLogin.set(on)
                          },
                          relaunch: { AppLifecycle.relaunch() })
    }

    /// macOS shows each permission prompt once per app. The first press shows it; later presses open
    /// the right page of System Settings, where the switch lives from then on.
    static func requestPermission(_ kind: PermissionKind) {
        let promptedKey = "permissionPrompted.\(kind.rawValue)"
        guard UserDefaults.standard.bool(forKey: promptedKey) else {
            UserDefaults.standard.set(true, forKey: promptedKey)
            SenseHub.requestPermission(kind)
            return
        }
        let page = kind == .accessibility ? "Privacy_Accessibility" : "Privacy_ScreenCapture"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(page)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Saves the name with the brain. On a first launch the brain may still be starting, so this keeps
    /// trying for half a minute.
    static func saveName(_ name: String, to brain: BrainClient) async {
        for _ in 0..<30 {
            if (try? await brain.setUserName(name)) != nil {
                AppLog.write("onboarding: name saved")
                return
            }
            try? await Task.sleep(for: .seconds(1))
        }
        AppLog.write("onboarding: could not save the name (brain not answering)")
    }
}
