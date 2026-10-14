import SwiftUI
import MokuKit

struct ManualControls: View {
    @Bindable var model: ManualControlModel
    private let columns = [GridItem(.adaptive(minimum: 108), spacing: 7)]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 21) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("A little rehearsal.").font(.system(size: 29, weight: .medium, design: .serif))
                        Text("Try a moment. Put a few together.").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(String(format: "CPU %.1f%% · rig %.0f fps", model.cpu, model.fps)).monospacedDigit()
                        Text(model.renderer).foregroundStyle(.secondary)
                    }.font(.caption)
                }
                Toggle("Record buttons into a chain", isOn: $model.playback.isRecording)
                    .toggleStyle(.switch).onChange(of: model.playback.isRecording) { _, recording in if recording { model.stop() } }
                group("Moods") {
                    LazyVGrid(columns: columns) { ForEach(Mood.allCases, id: \.self) { mood in
                        Button(mood.rawValue.capitalized) { model.submit(.mood(mood)) }.tint(model.mood == mood ? .green : .secondary)
                    } }
                }
                group("Work state") {
                    LazyVGrid(columns: columns) { ForEach(WorkState.allCases, id: \.self) { state in
                        Button(Self.words(state.rawValue)) { model.submit(.workState(state)) }.tint(model.workState == state ? .green : .secondary)
                    } }
                    HStack { Button("Small return") { model.submit(.returnBeat(.small)) }; Button("Full return") { model.submit(.returnBeat(.full)) } }
                }
                group("Gestures") { LazyVGrid(columns: columns) { ForEach(MokuKit.Gesture.allCases, id: \.self) { gesture in Button(Self.words(gesture.rawValue)) { model.submit(.gesture(gesture)) } } } }
                group("Gaze") {
                    HStack {
                        Button("Look at me") { model.submit(.attention(.user)) }
                        Button("Watch my work") { model.submit(.watchCursor) }.tint(model.watchesCursor ? .green : .secondary)
                        Button("Wander") { model.submit(.attention(.wander)) }
                        Text("Watching and wandering both look at the middle of Moku’s screen.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                group("Walk & visibility") {
                    HStack {
                        Button("Home") { model.submit(.move(.home)) }
                        Button("Center") { model.submit(.move(.center)) }
                        Button("Near cursor") { model.submit(.move(.near(NSEvent.mouseLocation))) }
                        Spacer()
                        Button("Hide") { model.submit(.hidden(true)) }
                        Button("Show") { model.submit(.hidden(false)) }
                    }
                }
                group("Speech") {
                    TextField("What should Moku say?", text: $model.speech).textFieldStyle(.roundedBorder)
                    HStack { ForEach(SpeechLine.Tone.allCases, id: \.self) { tone in Button(tone.rawValue.capitalized) { model.submit(.speech(model.speech, tone)) } }; Button("Dismiss") { model.submit(.dismissSpeech) } }
                }
                group("Thread label") {
                    HStack { TextField("Recognized line of work", text: $model.threadLabel).textFieldStyle(.roundedBorder); Button("Show label") { model.submit(.label(model.threadLabel)) } }
                }
                forest
                scenes
                chain
                Text(model.playback.status).font(.caption).foregroundStyle(.secondary)
            }.padding(28)
        }.frame(minWidth: 680, minHeight: 650)
            .background(Color(red: 0.975, green: 0.963, blue: 0.938))
            .foregroundStyle(Color(red: 0.22, green: 0.27, blue: 0.23)).preferredColorScheme(.light)
    }
    private var forest: some View {
        group("Forest") {
            Slider(value: $model.points, in: 0...11_000, onEditingChanged: { editing in if !editing { model.submit(.growth(model.points)) } })
                .accessibilityLabel("Forest growth points")
            LazyVGrid(columns: columns) { ForEach(ForestStage.allCases, id: \.self) { stage in Button(stage.homeTitle) { model.points = stage.threshold; model.submit(.growth(stage.threshold)) } } }
            HStack {
                Text("\(Int(model.points)) points").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Celebrate milestone") { model.submit(.celebrate(.at(points: model.points))) }
                Button("Open world") { model.submit(.openWorld) }
            }
        }
    }
    private var scenes: some View {
        group("Scenes") {
            HStack {
                Picker("Speed", selection: $model.speed) { ForEach([1.0, 5, 10, 30], id: \.self) { Text("\(Int($0))×").tag($0) } }.pickerStyle(.segmented).frame(width: 275)
                Spacer(); Button("Stop") { model.stop() }
            }
            if model.scenes.isEmpty { Text("No scenes were supplied by the app.").font(.caption).foregroundStyle(.secondary) }
            else { LazyVGrid(columns: columns) { ForEach(model.scenes) { scene in Button(scene.title) { model.submit(.scene(scene.id, model.speed)) } } } }
        }
    }
    private var chain: some View {
        group("Your chain") {
            Text("A wait of 0 starts the next step alongside this one. A positive wait finishes the group, then pauses.").font(.caption).foregroundStyle(.secondary)
            if model.playback.steps.isEmpty { Text("Turn on Record, then choose a few actions above.").font(.callout).foregroundStyle(.secondary).padding(.vertical, 6) }
            ForEach($model.playback.steps) { $step in
                HStack(spacing: 8) {
                    Text(step.action.title).font(.system(size: 12)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                    Text("then wait").font(.caption).foregroundStyle(.secondary)
                    TextField("Seconds", value: $step.wait, format: .number.precision(.fractionLength(0...2))).frame(width: 58).textFieldStyle(.roundedBorder).accessibilityLabel("Wait after \(step.action.title)")
                    Text("s").font(.caption)
                    Button { model.playback.steps.removeAll { $0.id == step.id } } label: { Image(systemName: "xmark") }.accessibilityLabel("Remove \(step.action.title)")
                }.padding(9).background(.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 9))
            }
            HStack {
                Button("Play once") { model.play(loop: false) }.disabled(model.playback.steps.isEmpty)
                Button("Loop") { model.play(loop: true) }.disabled(model.playback.steps.isEmpty)
                Button("Stop") { model.stop() }
                Spacer(); Button("Clear") { model.clear() }.disabled(model.playback.steps.isEmpty)
            }
        }
    }
    /// "longDrift" → "Long drift", "patReaction" → "Pat reaction".
    nonisolated static func words(_ name: String) -> String {
        let spaced = name.reduce(into: "") { text, letter in text += letter.isUppercase ? " " + letter.lowercased() : String(letter) }
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }
    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) { Text(title).font(.system(size: 14, weight: .semibold)); content() }.buttonStyle(.bordered).controlSize(.regular)
    }
}
