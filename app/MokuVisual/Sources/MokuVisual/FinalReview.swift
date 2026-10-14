import AppKit
import SwiftUI
import MokuKit

extension MokuVisualDiagnostics {
    /// A made-up world for reviews: `hours` of focus all told, today's share, and `returns` lanterns.
    static func sampleWorld(hours: Double, today: Int = 180, returns: Int) -> WorldSnapshot {
        let stones = (0..<returns).map { StoneMemory(id: "stone-\($0)",ts: Date().addingTimeInterval(Double($0-returns)*600),driftSeconds: 180,from: "x.com",followingFocusMinutes: 47,threadTitle: "Moku · A little company") }
        return WorldSnapshot(growthPoints: hours*60,todayFocusMinutes: min(today,Int(hours*60)),todayReturns: min(9,returns),longestFocusMinutesToday: min(47,today,Int(hours*60)),threads: [],unitsToday: min(18,Int(hours*6)),stones: stones,focusMinutesAllTime: Int(hours*60))
    }
    /// The popover at four points in the day, with the newest pieces landing: world-house-<age>.mp4/png.
    public static func finalWorldMovies(directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
        let scene = HomeScene()
        VisualSessionState.shared.workState = .focused
        for (today, age) in [(0, "morning"), (70, "noon"), (160, "afternoon"), (245, "done")] {
            let snapshot = sampleWorld(hours: 20, today: today, returns: 4)
            let model = WorldModel(snapshot: snapshot), state = ForestPresentation()
            let before = scene.frames
            scene.open(points: Double(today),from: max(0,Double(today)-50))
            while scene.frames == before && scene.error == nil { try await Task.sleep(for: .milliseconds(100)) }
            if let error = scene.error { throw NSError(domain: "World review",code: 1,userInfo: [NSLocalizedDescriptionKey:error]) }
            let view = NSHostingView(rootView: HomeView(model: model,state: state,scene: scene)); view.frame = CGRect(x: 0,y: 0,width: 370,height: HomeView.height)
            let panel = NSPanel(contentRect: view.frame,styleMask: .borderless,backing: .buffered,defer: false); panel.isReleasedWhenClosed = false; panel.contentView = view
            let first = try ReviewCapture.view(view); let movie = try ReviewMovie(url: directory.appendingPathComponent("world-house-\(age).mp4"),width: first.width,height: first.height,fps: 24)
            let start = CACurrentMediaTime()
            while CACurrentMediaTime()-start < 5 { try await movie.append(ReviewCapture.view(view),at: CACurrentMediaTime()-start); try await Task.sleep(for: .milliseconds(41)) }
            try await movie.finish(); try NSBitmapImageRep(cgImage: ReviewCapture.view(view)).representation(using: .png,properties: [:])!.write(to: directory.appendingPathComponent("world-house-\(age).png"))
            panel.contentView = nil; panel.close(); scene.close()
        }
    }
    public static func finalTravelMovie(stage: MokuCharacterStage,directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
        stage.show(); stage.setMood(.content); stage.setWorkState(.focused)
        while stage.totalRenderedFrames == 0 && stage.rendererError == nil { try await Task.sleep(for: .milliseconds(100)) }
        try await stage.view.real?.prepareReviewClips()
        try await Task.sleep(for: .seconds(3))
        let first = try ReviewCapture.desktop(stage: stage)
        let movie = try ReviewMovie(url: directory.appendingPathComponent("hop-drag-drift-return.mp4"),width: first.width,height: first.height,fps: 24)
        let sequence = Task { @MainActor in
            await stage.move(to: .center); await stage.move(to: .home)
            let cursor = CGPoint(x: stage.panel.frame.midX,y: stage.panel.frame.midY)
            stage.beginGrab(at: cursor,press: cursor)
            for i in 1...12 { stage.dragGrab(to: CGPoint(x: cursor.x-Double(i)*15,y: cursor.y+Double(i)*7)); try? await Task.sleep(for: .milliseconds(25)) }
            stage.releaseGrab(); try? await Task.sleep(for: .seconds(3))
            stage.setWorkState(.grace); try? await Task.sleep(for: .seconds(1)); stage.setMood(.annoyed); stage.setWorkState(.noticing)
            try? await Task.sleep(for: .seconds(4)); stage.setMood(.disappointed); stage.setWorkState(.longDrift)
            try? await Task.sleep(for: .seconds(4)); stage.celebrateReturn(.small)
            try? await Task.sleep(for: .seconds(4)); stage.setAttention(.user); try? await Task.sleep(for: .seconds(2)); stage.setAttention(.wander)
        }
        let start = CACurrentMediaTime()
        var done = false; let completion = Task { await sequence.value; done = true }
        while !done && CACurrentMediaTime()-start < 100 {
            try await movie.append(ReviewCapture.desktop(stage: stage),at: CACurrentMediaTime()-start)
            try await Task.sleep(for: .milliseconds(41))
        }
        if !done { sequence.cancel(); completion.cancel(); throw CocoaError(.validationMissingMandatoryProperty) }
        try await movie.finish(); stage.setHidden(true)
    }
    public static func finalTodayMovie(directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
        let now = Date(); let start = now.addingTimeInterval(-4*3600)
        var segments: [DaySegment] = []
        for i in 0..<9 {
            let drift = i == 2 || i == 6
            let state: Verdict.State = i == 4 ? .meeting : (drift ? .drifting : .working)
            let category: ActivityCategory = drift ? .scrolling : .building
            let begin = start.addingTimeInterval(Double(i)*1500),end = start.addingTimeInterval(Double(i+1)*1500)
            segments.append(DaySegment(id: "segment-\(i)",start: begin,end: end,state: state,app: i%2 == 0 ? "Claude" : "LinkedIn",bundleId: "com.apple.Safari",host: i%2 == 0 ? nil : "linkedin.com",activity: drift ? "scrolling the feed" : "building Moku",category: category))
        }
        let stone = StoneMemory(id: "best",ts: segments[3].start,driftSeconds: 180,from: "x.com",followingFocusMinutes: 47,threadTitle: "Moku")
        let world = WorldModel(snapshot: WorldSnapshot(growthPoints: 1260,todayFocusMinutes: 192,todayReturns: 9,longestFocusMinutesToday: 47,threads: [],unitsToday: 14,stones: [stone],focusMinutesAllTime: 1260))
        let dateFormatter = DateFormatter(); dateFormatter.dateFormat = "yyyy-MM-dd"
        let model = TodayModel(); model.summary = TodaySummary(date: dateFormatter.string(from: now),note: "A long morning making Moku. A wander, then a lovely stretch together — I added fourteen pieces to the bedroom.",focusedMinutes: 192,longestFocusMinutes: 47,returns: 9,unitsToday: 14,segments: segments,built: [ActivityRow(id: "build",app: "Claude",bundleId: "com.anthropic.claudefordesktop",activity: "building Moku",minutes: 90,segmentIds: ["segment-0"],category: .building),ActivityRow(id: "learn",app: "GitHub",bundleId: "com.apple.Safari",host: "github.com",activity: "reviewing a pull request",minutes: 22,segmentIds: ["segment-1"],category: .working)],wandered: [ActivityRow(id: "feed",app: "LinkedIn",bundleId: "com.apple.Safari",host: "linkedin.com",activity: "scrolling the feed",minutes: 18,segmentIds: ["segment-2","segment-6"],category: .scrolling)],quickCheckMinutes: 6,comebacks: [stone],bestComeback: stone,completions: [],byCategory: [CategoryTotal(category: .building,minutes: 130),CategoryTotal(category: .learning,minutes: 40),CategoryTotal(category: .working,minutes: 22),CategoryTotal(category: .scrolling,minutes: 18)])
        model.strip = (0..<7).map { i in DayTotals(date: TodayModel.key(Calendar.current.date(byAdding: .day, value: i - 6, to: now)!), focusedMinutes: [95, 210, 0, 160, 245, 60, 192][i], longestFocusMinutes: 47, returns: 9, lanterns: [3, 5, 0, 4, 6, 1, 4][i], pieces: 14) }
        model.firstDay = Calendar.current.date(byAdding: .day, value: -12, to: Calendar.current.startOfDay(for: now))
        let scene = HomeScene(); scene.open(points: Double(world.snapshot.todayFocusMinutes))
        while scene.image == nil && scene.error == nil { try await Task.sleep(for: .milliseconds(100)) }
        var corrected = [String]()
        let view = NSHostingView(rootView: TodayView(model: model,scene: scene,world: world,onCorrect: { row,work in model.correct(row,work: work) { ids,_ in corrected = ids } })); view.frame = CGRect(x: 0,y: 0,width: 1120,height: 760)
        let panel = NSPanel(contentRect: view.frame,styleMask: .borderless,backing: .buffered,defer: false); panel.isReleasedWhenClosed = false; panel.contentView = view
        let first = try ReviewCapture.view(view); let movie = try ReviewMovie(url: directory.appendingPathComponent("today.mp4"),width: first.width,height: first.height,fps: 12)
        let startTime = CACurrentMediaTime(); var changed = false
        while CACurrentMediaTime()-startTime < 7 {
            if CACurrentMediaTime()-startTime > 3 && !changed,let row = model.summary?.wandered.first { changed = true; model.correct(row,work: true) { ids,_ in corrected = ids } }
            try await movie.append(ReviewCapture.view(view),at: CACurrentMediaTime()-startTime); try await Task.sleep(for: .milliseconds(83))
        }
        try await movie.finish(); try NSBitmapImageRep(cgImage: first).representation(using: .png,properties: [:])!.write(to: directory.appendingPathComponent("today.png"))
        if let summary = model.summary,let tiff = try await Postcard.image(summary: summary,scene: scene).tiffRepresentation { try NSBitmapImageRep(data: tiff)!.representation(using: .png,properties: [:])!.write(to: directory.appendingPathComponent("postcard.png")) }
        guard corrected == ["segment-2","segment-6"],model.rows(work: false).isEmpty,model.rows(work: true).count == 3 else { throw CocoaError(.validationMissingMandatoryProperty) }
        panel.contentView = nil; panel.close(); scene.close()
        try JSONSerialization.data(withJSONObject: ["correctedSegmentIds":corrected,"rowsMoveToBuilt":true],options: .prettyPrinted).write(to: directory.appendingPathComponent("today-checks.json"))
    }
}
