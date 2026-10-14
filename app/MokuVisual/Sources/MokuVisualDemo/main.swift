import AppKit
import SwiftUI
import MokuKit
import MokuVisual

@MainActor
final class DemoDelegate: NSObject, NSApplicationDelegate {
    let model = DemoModel()
    var stage: MokuCharacterStage { model.stage }
    var window: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        stage.show()
        if CommandLine.arguments.contains("--offscreen") {
            model.monitor?.invalidate(); model.monitor = nil
            Task {
                for flag in ["--firstuse", "--dayhouse-look", "--popover-look", "--popover-open", "--look", "--look-pairs", "--look-cost", "--goal-day", "--daytree-look", "--clip-exit-check", "--fidget-frames", "--gesture-frames", "--live-today", "--live-house", "--wake-check", "--cancel-check", "--home-memory", "--live-home", "--home-look", "--ear-check", "--look-up-check", "--drag-check", "--manpu-check", "--home-states", "--stand-keep-check", "--return-check", "--speech-check", "--speech-look", "--size-check", "--wave-check", "--stand-movie", "--stand-check", "--ladder-check", "--caption-check", "--gaze-check", "--capture", "--capture-all", "--benchmark", "--stress", "--brief2", "--v1-p0", "--v1-perf", "--audit", "--feedback3", "--drift-check", "--quick-fix", "--transitions", "--onboarding", "--welcome-look", "--welcome-wow-frames", "--welcome-cost", "--welcome-movie", "--welcome-spotlight", "--spotlight-geometry", "--energy-minute", "--morph-probe", "--companion-check", "--robot-look", "--final-world", "--final-travel", "--final-today", "--hover-check", "--notice-check", "--memory-profile", "--idle-energy", "--soak", "--spam", "--whats-new-look", "--sharpness", "--drift-gaze"] {
                    guard let i = CommandLine.arguments.firstIndex(of: flag), CommandLine.arguments.count > i+1 else { continue }
                    let path = CommandLine.arguments[i+1]
                    if flag == "--stand-movie" { do { try await MokuVisualDiagnostics.standMovie(stage: stage, directory: URL(fileURLWithPath: path)) } catch { NSLog("Stand movie failed: %@", error.localizedDescription); exit(1) } }
                    if flag == "--firstuse" { do { try await MokuVisualDiagnostics.firstUseCheck(directory: URL(fileURLWithPath: path)) } catch { NSLog("First use check failed: %@", error.localizedDescription); exit(1) } }
                    if flag == "--stand-check" { do { try await MokuVisualDiagnostics.standCheck(stage: stage, directory: URL(fileURLWithPath: path)) } catch { NSLog("Stand check failed: %@", error.localizedDescription); exit(1) } }
                    if flag == "--ladder-check" { do { try await MokuVisualDiagnostics.ladderCheck(stage: stage, directory: URL(fileURLWithPath: path)) } catch { NSLog("Ladder check failed: %@", error.localizedDescription); exit(1) } }
                    if flag == "--cancel-check" { do { try await MokuVisualDiagnostics.cancelCheck(stage: stage, directory: URL(fileURLWithPath: path)) } catch { NSLog("Cancel check failed: %@", error.localizedDescription) } }
                    if flag == "--wake-check" { do { try await MokuVisualDiagnostics.wakeCheck(stage: stage, directory: URL(fileURLWithPath: path)) } catch { NSLog("Wake check failed: %@", error.localizedDescription) } }
                    if flag == "--live-house" { do { try await MokuVisualDiagnostics.liveHouseCheck(directory: URL(fileURLWithPath: path)) } catch { NSLog("Live house failed: %@", error.localizedDescription); exit(1) } }
                    if flag == "--live-today" { do { try await MokuVisualDiagnostics.liveTodayCheck(directory: URL(fileURLWithPath: path)) } catch { NSLog("Live today failed: %@", error.localizedDescription); exit(1) } }
                    if flag == "--home-memory" { do { try await MokuVisualDiagnostics.homeMemoryCheck(directory: URL(fileURLWithPath: path)) } catch { NSLog("Home memory failed: %@", error.localizedDescription); exit(1) } }
                    if flag == "--live-home" { do { try await MokuVisualDiagnostics.liveHomeCheck(directory: URL(fileURLWithPath: path)) } catch { NSLog("Live home failed: %@", error.localizedDescription); exit(1) } }
                    if flag == "--home-look" { do { try await MokuVisualDiagnostics.homeLookCheck(directory: URL(fileURLWithPath: path)) } catch { NSLog("Home look failed: %@", error.localizedDescription); exit(1) } }
                    if flag == "--ear-check" { do { try await MokuVisualDiagnostics.earCheck(stage: stage, directory: URL(fileURLWithPath: path)) } catch { NSLog("Ear check failed: %@", error.localizedDescription); exit(1) } }
                    if flag == "--look-up-check" { do { try await MokuVisualDiagnostics.lookUpCheck(stage: stage, directory: URL(fileURLWithPath: path)) } catch { NSLog("Look-up check failed: %@", error.localizedDescription); exit(1) } }
                    if flag == "--drag-check" { do { try await MokuVisualDiagnostics.dragCheck(stage: stage, directory: URL(fileURLWithPath: path)) } catch { NSLog("Drag check failed: %@", error.localizedDescription); exit(1) } }
                    if flag == "--manpu-check" { do { try await MokuVisualDiagnostics.manpuCheck(stage: stage, directory: URL(fileURLWithPath: path)) } catch { NSLog("Manpu check failed: %@", error.localizedDescription); exit(1) } }
                    if flag == "--home-states" { do { try await MokuVisualDiagnostics.homeStatesCheck(directory: URL(fileURLWithPath: path)) } catch { NSLog("Home states failed: %@", error.localizedDescription); exit(1) } }
                    if flag == "--stand-keep-check" { do { try await MokuVisualDiagnostics.standKeepCheck(stage: stage, directory: URL(fileURLWithPath: path)) } catch { NSLog("Stand keep check failed: %@", error.localizedDescription); exit(1) } }
                    if flag == "--return-check" { do { try await MokuVisualDiagnostics.returnCheck(stage: stage, directory: URL(fileURLWithPath: path)) } catch { NSLog("Return check failed: %@", error.localizedDescription); exit(1) } }
                    if flag == "--whats-new-look" { do { try await MokuVisualDiagnostics.whatsNewLook(directory: URL(fileURLWithPath: path)) } catch { NSLog("What's new look failed: %@", error.localizedDescription); exit(1) } }
                    if flag == "--speech-look" { do { try await MokuVisualDiagnostics.speechLook(directory: URL(fileURLWithPath: path)) } catch { NSLog("Speech look failed: %@", error.localizedDescription); exit(1) } }
                    if flag == "--speech-check" { do { try await MokuVisualDiagnostics.speechCheck(stage: stage, directory: URL(fileURLWithPath: path)) } catch { NSLog("Speech check failed: %@", error.localizedDescription); exit(1) } }
                    if flag == "--wave-check" { do { try await MokuVisualDiagnostics.waveCheck(stage: stage, directory: URL(fileURLWithPath: path)) } catch { NSLog("Wave check failed: %@", error.localizedDescription); exit(1) } }
                    if flag == "--size-check" { do { try await MokuVisualDiagnostics.sizeCheck(stage: stage, directory: URL(fileURLWithPath: path)) } catch { NSLog("Size check failed: %@", error.localizedDescription); exit(1) } }
                    if flag == "--caption-check" { do { try await MokuVisualDiagnostics.captionCheck(stage: stage, directory: URL(fileURLWithPath: path)) } catch { NSLog("Caption check failed: %@", error.localizedDescription); exit(1) } }
                    if flag == "--sharpness" { do { try await MokuVisualDiagnostics.sharpness(stage: stage, directory: URL(fileURLWithPath: path)) } catch { NSLog("Sharpness check failed: %@", error.localizedDescription); exit(1) } }
                    if flag == "--gaze-check" { do { try await MokuVisualDiagnostics.gazeCheck(stage: stage, directory: URL(fileURLWithPath: path)) } catch { NSLog("Gaze check failed: %@", error.localizedDescription); exit(1) } }
                    if flag == "--feedback3" { do { try await MokuVisualDiagnostics.feedback3(stage: stage, directory: URL(fileURLWithPath: path)) } catch { NSLog("Capture failed: %@", error.localizedDescription); exit(1) } }
                    if flag == "--audit" { do { try await MokuVisualDiagnostics.auditFrames(stage: stage, directory: URL(fileURLWithPath: path)) } catch { NSLog("Audit failed: %@", error.localizedDescription); exit(1) } }
                    if flag == "--final-world" { do { try await MokuVisualDiagnostics.finalWorldMovies(directory: URL(fileURLWithPath: path)) } catch { NSLog("World review failed: %@",error.localizedDescription); exit(1) } }
                    if flag == "--final-travel" { do { try await MokuVisualDiagnostics.finalTravelMovie(stage: stage,directory: URL(fileURLWithPath: path)) } catch { NSLog("Travel review failed: %@",error.localizedDescription); exit(1) } }
                    if flag == "--final-today" { do { try await MokuVisualDiagnostics.finalTodayMovie(directory: URL(fileURLWithPath: path)) } catch { NSLog("Today review failed: %@",error.localizedDescription); exit(1) } }
                    if flag == "--transitions" { do { try await MokuVisualDiagnostics.auditTransitions(stage: stage, directory: URL(fileURLWithPath: path)) } catch { NSLog("Transition audit failed: %@", error.localizedDescription); exit(1) } }
                    if flag == "--onboarding" || flag == "--welcome-movie" { do { try await MokuVisualDiagnostics.welcomeMovie(stage: stage, directory: URL(fileURLWithPath: path)) } catch { NSLog("Onboarding review failed: %@", error.localizedDescription); exit(1) } }
                    if flag == "--robot-look" { do { try await MokuVisualDiagnostics.robotLook(stage: stage, directory: URL(fileURLWithPath: path)) } catch { NSLog("Robot look failed: %@", error.localizedDescription); exit(1) } }
                    if flag == "--notice-check" { do { try await MokuVisualDiagnostics.noticeCheck(stage: stage, directory: URL(fileURLWithPath: path)) } catch { NSLog("Notice check failed: %@", error.localizedDescription); exit(1) } }
                    if flag == "--hover-check" { do { try await MokuVisualDiagnostics.hoverCheck(stage: stage, directory: URL(fileURLWithPath: path)) } catch { NSLog("Hover check failed: %@", error.localizedDescription); exit(1) } }
                    if flag == "--companion-check" { do { try await MokuVisualDiagnostics.companionCheck(stage: stage, directory: URL(fileURLWithPath: path)) } catch { NSLog("Companion check failed: %@", error.localizedDescription); exit(1) } }
                    if flag == "--welcome-spotlight" { do { try await MokuVisualDiagnostics.welcomeSpotlight(stage: stage, directory: URL(fileURLWithPath: path)) } catch { NSLog("Welcome spotlight failed: %@", error.localizedDescription); exit(1) } }
                    if flag == "--spotlight-geometry" { do { try await MokuVisualDiagnostics.spotlightGeometry(directory: URL(fileURLWithPath: path)) } catch { NSLog("Spotlight geometry failed: %@", error.localizedDescription); exit(1) } }
                    if flag == "--welcome-look" { do { try await MokuVisualDiagnostics.welcomeLook(stage: stage, directory: URL(fileURLWithPath: path)) } catch { NSLog("Welcome look failed: %@", error.localizedDescription); exit(1) } }
                    if flag == "--welcome-wow-frames" { do { try await MokuVisualDiagnostics.welcomeWowFrames(stage: stage, directory: URL(fileURLWithPath: path)) } catch { NSLog("Welcome wow frames failed: %@", error.localizedDescription); exit(1) } }
                    if flag == "--memory-profile" { do { try await MokuVisualDiagnostics.memoryProfile(stage: stage, directory: URL(fileURLWithPath: path)) } catch { NSLog("Memory profile failed: %@", error.localizedDescription); exit(1) } }
                    if flag == "--soak" { do { try await MokuVisualDiagnostics.soak(stage: stage, directory: URL(fileURLWithPath: path)) } catch { NSLog("Soak failed: %@", error.localizedDescription); exit(1) } }
                    if flag == "--spam" { do { try await MokuVisualDiagnostics.interactionSpam(stage: stage, directory: URL(fileURLWithPath: path)) } catch { NSLog("Spam failed: %@", error.localizedDescription); exit(1) } }
                    if flag == "--idle-energy" { do { try await MokuVisualDiagnostics.idleEnergy(stage: stage, directory: URL(fileURLWithPath: path)) } catch { NSLog("Idle energy failed: %@", error.localizedDescription); exit(1) } }
                    if flag == "--welcome-cost" { do { try await MokuVisualDiagnostics.welcomeCost(stage: stage, directory: URL(fileURLWithPath: path)) } catch { NSLog("Welcome cost failed: %@", error.localizedDescription); exit(1) } }
                    if flag == "--energy-minute" { do { try await MokuVisualDiagnostics.energyMinute(stage: stage, directory: URL(fileURLWithPath: path)) } catch { NSLog("Energy minute failed: %@", error.localizedDescription); exit(1) } }
                    if flag == "--morph-probe" { do { try await MokuVisualDiagnostics.morphProbe(directory: URL(fileURLWithPath: path)) } catch { NSLog("Morph probe failed: %@", "\(error)"); exit(1) } }
                    if flag == "--quick-fix" { do { try await MokuVisualDiagnostics.quickFixMovie(stage: stage, directory: URL(fileURLWithPath: path)) } catch { NSLog("Quick fix review failed: %@", error.localizedDescription); exit(1) } }
                    if flag == "--drift-gaze" { do { try await captureDriftGaze(model: model, directory: path) } catch { NSLog("Drift gaze failed: %@", error.localizedDescription); exit(1) } }
                    if flag == "--drift-check" { do { try await captureImmediateDrift(model: model, directory: path) } catch { NSLog("Drift check failed: %@", error.localizedDescription); exit(1) } }
                    if flag == "--capture" { try? await Task.sleep(for: .seconds(3)); try? stage.capture(to: URL(fileURLWithPath: path)) }
                    if flag == "--capture-all" { await captureAll(model: model, window: nil, directory: path) }
                    if flag == "--fidget-frames" { await fidgetFrames(model: model, directory: path) }
                    if flag == "--dayhouse-look" { do { try await MokuVisualDiagnostics.dayHouseLookCheck(directory: URL(fileURLWithPath: path)) } catch { NSLog("Day house look failed: %@", error.localizedDescription); exit(1) } }
                    if flag == "--look-cost" { do { try await MokuVisualDiagnostics.lookCost(stage: stage, directory: URL(fileURLWithPath: path)) } catch { NSLog("Look cost failed: %@", error.localizedDescription); exit(1) } }
                    if flag == "--look-pairs" { do { try await MokuVisualDiagnostics.lookPairs(stage: stage, directory: URL(fileURLWithPath: path)) } catch { NSLog("Look pairs failed: %@", error.localizedDescription); exit(1) } }
                    if flag == "--look" { do { try await MokuVisualDiagnostics.lookCheck(stage: stage, directory: URL(fileURLWithPath: path)) } catch { NSLog("Look check failed: %@", error.localizedDescription); exit(1) } }
                    if flag == "--goal-day" { do { try await MokuVisualDiagnostics.goalDayLook(directory: URL(fileURLWithPath: path)) } catch { NSLog("Goal day failed: %@", error.localizedDescription); exit(1) } }
                    if flag == "--popover-open" { do { try await MokuVisualDiagnostics.popoverOpenCheck(directory: URL(fileURLWithPath: path)) } catch { NSLog("Popover open check failed: %@", error.localizedDescription); exit(1) } }
                    if flag == "--popover-look" { do { try await MokuVisualDiagnostics.popoverLook(directory: URL(fileURLWithPath: path)) } catch { NSLog("Popover look failed: %@", error.localizedDescription); exit(1) } }
                    if flag == "--daytree-look" { do { try await MokuVisualDiagnostics.dayTreeLookCheck(directory: URL(fileURLWithPath: path)) } catch { NSLog("Day tree look failed: %@", error.localizedDescription); exit(1) } }
                    if flag == "--clip-exit-check" { do { try await MokuVisualDiagnostics.clipExitCheck(stage: stage, gesture: .drinkWater, from: 10.5, to: 14.5, directory: URL(fileURLWithPath: path)) } catch { NSLog("Clip exit check failed: %@", error.localizedDescription); exit(1) } }
                    if flag == "--gesture-frames", CommandLine.arguments.count > i + 2 { await gestureFrames(model: model, name: path, directory: CommandLine.arguments[i + 2], seconds: 13) }
                    if flag == "--benchmark" { await benchmark(model: model, window: nil, path: path) }
                    if flag == "--v1-p0" { await captureV1(model: model, directory: path) }
                    if flag == "--v1-perf" { await benchmarkV1(model: model, path: path) }
                    if flag == "--brief2" { await captureBrief2(model: model, directory: path) }
                    if flag == "--stress" { await stress(model: model, path: path) }
                }
                for (flag, run) in [("--life-reel", MokuVisualDiagnostics.lifeReel), ("--life-cpu", MokuVisualDiagnostics.lifeCPU), ("--life-moves", MokuVisualDiagnostics.lifeMoves),
                                    ("--smile-survey", MokuVisualDiagnostics.smileSurvey), ("--pleased-reel", MokuVisualDiagnostics.pleasedReel), ("--arms-check", MokuVisualDiagnostics.armsCheck), ("--talents", MokuVisualDiagnostics.talentsCheck), ("--moments-reel", MokuVisualDiagnostics.momentsReel), ("--smile-turn", MokuVisualDiagnostics.smileTurnCheck), ("--qa-motion", MokuVisualDiagnostics.qaMotion), ("--beam-check", MokuVisualDiagnostics.beamCheck), ("--qa-switch", MokuVisualDiagnostics.qaSwitch), ("--qa-spam", MokuVisualDiagnostics.qaSpam)] {
                    guard let i = CommandLine.arguments.firstIndex(of: flag), CommandLine.arguments.count > i + 1 else { continue }
                    do { try await run(stage, URL(fileURLWithPath: CommandLine.arguments[i + 1])) } catch { NSLog("%@ failed: %@", flag, error.localizedDescription); exit(1) }
                }
                // "Today counted" (DayCounted.swift): its look, and its memory and motion.
                for (flag, run) in [("--today-counted", MokuVisualDiagnostics.dayCountedLook), ("--today-counted-cost", MokuVisualDiagnostics.dayCountedCost), ("--today-counted-stills", MokuVisualDiagnostics.dayCountedStills)] {
                    guard let i = CommandLine.arguments.firstIndex(of: flag), CommandLine.arguments.count > i + 1 else { continue }
                    do { try await run(stage, URL(fileURLWithPath: CommandLine.arguments[i + 1])) } catch { NSLog("%@ failed: %@", flag, error.localizedDescription); exit(1) }
                }
                NSApp.terminate(nil)
            }
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--capture"), CommandLine.arguments.count > i + 1 {
            let path = CommandLine.arguments[i+1]
            Task { try? await Task.sleep(for: .seconds(4)); try? stage.capture(to: URL(fileURLWithPath: path)) }
        }
        model.openManualControl()

    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
// The demo shares its defaults with the real Moku: a companion chosen in a check stays in this process.
CompanionChoice.keepInMemory()
let app = NSApplication.shared
app.setActivationPolicy(CommandLine.arguments.contains("--offscreen") ? .prohibited : .regular)
let menu = NSMenu(); let appMenu = NSMenu(); let item = NSMenuItem(); item.submenu = appMenu
appMenu.addItem(withTitle: "Quit Moku Visual Studio", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
menu.addItem(item); app.mainMenu = menu
let delegate = DemoDelegate()
app.delegate = delegate
app.run()
