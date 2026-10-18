import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Job runner

final class StemJob: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case best, fast
        var id: String { rawValue }
        var label: String { self == .best ? "Best quality (RoFormer)" : "Fast (Demucs)" }
    }

    enum Kind { case setup, fetch, stems }

    @Published var progress: Double = 0
    @Published var status = "Ready"
    @Published var running = false
    @Published var resultFolder: URL?
    @Published var error: String?
    @Published var startDate: Date?
    @Published private(set) var kind = Kind.stems
    @Published var isSetUp = FileManager.default.fileExists(atPath: StemJob.readyMarker.path)

    private var process: Process?
    private var buffer = ""
    private var onFetched: ((URL) -> Void)?

    // setup.sh installs Python, the separation stack and ffmpeg here
    static let homeDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("StemMission")
    static let python = homeDir.appendingPathComponent("env/bin/python")
    static let readyMarker = homeDir.appendingPathComponent("env/.stemmission-ready")
    // audio fetched from links lives here until the next fetch replaces it
    static let fetchDir = homeDir.appendingPathComponent("fetched")

    private var worker: URL? {
        let url = Bundle.main.url(forResource: "worker", withExtension: "py")
        if url == nil { error = "worker.py not found" }
        return url
    }

    func runSetup() {
        guard let script = Bundle.main.url(forResource: "setup", withExtension: "sh") else {
            error = "setup.sh not found"; return
        }
        launch(URL(fileURLWithPath: "/bin/zsh"), [script.path], kind: .setup)
    }

    /// Downloads a link's audio as a WAV into `fetchDir`, then hands its path to `done`.
    func fetch(link: String, done: @escaping (URL) -> Void) {
        guard let worker else { return }
        try? FileManager.default.removeItem(at: Self.fetchDir)
        try? FileManager.default.createDirectory(at: Self.fetchDir, withIntermediateDirectories: true)
        onFetched = done
        launch(Self.python, ["-u", worker.path, "--input", link, "--outdir", Self.fetchDir.path,
                             "--sample-rate", "auto", "--download-only"], kind: .fetch)
    }

    func start(input: String, outputDir: String, mode: Mode, sampleRate: String,
               trim: (start: Double, end: Double)? = nil) {
        guard let worker else { return }
        var args = ["-u", worker.path, "--input", input, "--outdir", outputDir,
                    "--mode", mode.rawValue, "--sample-rate", sampleRate]
        if let trim { args += ["--start", String(format: "%.3f", trim.start), "--end", String(format: "%.3f", trim.end)] }
        launch(Self.python, args, kind: .stems)
    }

    private func launch(_ executable: URL, _ arguments: [String], kind: Kind) {
        progress = 0; status = "Starting…"; error = nil; resultFolder = nil
        running = true; startDate = Date(); buffer = ""; self.kind = kind

        let p = Process()
        p.executableURL = executable
        p.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/bin:/bin"
        env["STEMMISSION_HOME"] = Self.homeDir.path
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.consume(s) }
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                pipe.fileHandleForReading.readabilityHandler = nil
                guard let self else { return }
                self.running = false
                if proc.terminationStatus != 0 && self.error == nil && self.resultFolder == nil {
                    self.error = proc.terminationReason == .uncaughtSignal || proc.terminationStatus == 130
                        ? "Cancelled" : "Process stopped unexpectedly (code \(proc.terminationStatus))"
                }
            }
        }
        do {
            try p.run()
            process = p
        } catch {
            running = false
            self.error = error.localizedDescription
        }
    }

    func clearResult() {
        guard !running else { return }
        progress = 0; status = "Ready"; error = nil; resultFolder = nil
    }

    func cancel() {
        process?.terminate()
        status = "Cancelling…"
    }

    private func consume(_ chunk: String) {
        buffer += chunk
        while let nl = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<nl])
            buffer = String(buffer[buffer.index(after: nl)...])
            handle(line)
        }
    }

    private func handle(_ line: String) {
        let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
        guard let kind = parts.first else { return }
        switch kind {
        case "PROGRESS" where parts.count >= 2:
            progress = Double(parts[1]) ?? progress
            if parts.count == 3 { status = parts[2] }
        case "DONE" where self.kind == .setup:
            progress = 1; status = "Setup complete"
            isSetUp = FileManager.default.fileExists(atPath: Self.readyMarker.path)
        case "DONE":
            let url = URL(fileURLWithPath: String(line.dropFirst(5)))
            progress = 1; status = "Done"
            if self.kind == .fetch {
                onFetched?(url); onFetched = nil
            } else {
                resultFolder = url
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        case "ERROR":
            error = String(line.dropFirst(6)).replacingOccurrences(of: " ⏎ ", with: "\n")
            status = "Error"
        default:
            break
        }
    }
}

// MARK: - Theme

// Same purple-nebula palette as the app icon (tools/make_icon.py)
enum Theme {
    static let accent = Color(red: 0.60, green: 0.31, blue: 0.94)
    static let orchid = Color(red: 0.74, green: 0.45, blue: 1.00)
    static let pink = Color(red: 0.93, green: 0.51, blue: 0.94)
    static let blue = Color(red: 0.25, green: 0.42, blue: 0.95)
    static let space = Color(red: 0.024, green: 0.012, blue: 0.078)
    static let violet = Color(red: 0.13, green: 0.05, blue: 0.31)
    static let error = Color(red: 1.0, green: 0.55, blue: 0.62)
}

struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

struct NebulaBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.space, Theme.violet, Theme.space],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [Theme.accent.opacity(0.55), .clear],
                           center: UnitPoint(x: 0.22, y: 0.18), startRadius: 0, endRadius: 380)
            RadialGradient(colors: [Theme.pink.opacity(0.26), .clear],
                           center: UnitPoint(x: 0.92, y: 0.72), startRadius: 0, endRadius: 320)
            RadialGradient(colors: [Theme.blue.opacity(0.24), .clear],
                           center: UnitPoint(x: 0.82, y: 0.06), startRadius: 0, endRadius: 260)
            Canvas { ctx, size in
                var rng = SeededGenerator(state: 7)  // fixed seed: stars must not jump on redraw
                for _ in 0..<140 {
                    let x = Double.random(in: 0...1, using: &rng) * size.width
                    let y = Double.random(in: 0...1, using: &rng) * size.height
                    let b = pow(Double.random(in: 0...1, using: &rng), 3)
                    let r = 0.4 + b * 1.1
                    ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                             with: .color(.white.opacity(0.18 + b * 0.6)))
                }
            }
        }
    }
}

struct NebulaCard: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            configuration.label
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.pink)
                .padding(.horizontal, 6)
            configuration.content
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.orchid.opacity(0.35), lineWidth: 1))
    }
}

// MARK: - Step building blocks

/// A numbered section that stays collapsed until the steps before it are done.
struct StepCard<Content: View>: View {
    let number: Int
    let title: String
    let unlocked: Bool
    var done = false
    var lockedHint = ""
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(unlocked
                                  ? AnyShapeStyle(LinearGradient(colors: [Theme.pink, Theme.accent],
                                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                                  : AnyShapeStyle(Color.white.opacity(0.12)))
                    if done { Image(systemName: "checkmark").font(.caption.bold()) }
                    else { Text("\(number)").font(.caption.bold()) }
                }
                .frame(width: 22, height: 22)
                Text(title).font(.headline)
                Spacer()
                if !unlocked { Text(lockedHint).font(.caption).foregroundStyle(.secondary) }
            }
            if unlocked { content }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(unlocked ? 0.07 : 0.03), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.orchid.opacity(unlocked ? 0.35 : 0.12), lineWidth: 1))
        .opacity(unlocked ? 1 : 0.55)
    }
}

/// A selectable card; the recommended (default) choice carries a badge so it stands out.
struct OptionCard: View {
    var icon: String?
    let title: String
    let detail: String
    var recommended = false
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                // badge sits next to the title, or above it when the card is too narrow
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) { titleRow; badge }
                    VStack(alignment: .leading, spacing: 4) { badge; titleRow }
                }
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(selected ? Theme.accent.opacity(0.22) : .white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(selected ? Theme.pink.opacity(0.8) : .white.opacity(0.12), lineWidth: selected ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private var titleRow: some View {
        HStack(spacing: 6) {
            Image(systemName: icon ?? (selected ? "largecircle.fill.circle" : "circle"))
                .foregroundStyle(selected ? Theme.pink : .secondary)
            Text(title).font(.callout.weight(.semibold))
        }
        .fixedSize()
    }

    @ViewBuilder private var badge: some View {
        if recommended {
            Text("Recommended")
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Theme.accent, in: Capsule())
                .fixedSize()
        }
    }
}

// MARK: - UI

struct ContentView: View {
    enum Source { case link, file }

    @StateObject private var job = StemJob()
    @StateObject private var clip = AudioClip()
    @State private var source: Source?
    @State private var link = ""
    @State private var audio: URL?          // step 1 result: a local audio file
    @State private var trimDone = false     // step 2 confirmed, step 3 opens
    @State private var savedAudio: URL?
    @State private var saveError: String?
    @AppStorage("outputDir") private var outputDir = FileManager.default
        .homeDirectoryForCurrentUser.appendingPathComponent("Music/Stems").path
    @AppStorage("mode") private var modeRaw = StemJob.Mode.best.rawValue
    @AppStorage("sampleRate") private var sampleRate = "auto"
    @State private var dropTargeted = false

    // fits all three steps open on most screens, but never taller than the screen itself
    static let windowHeight = min(860, (NSScreen.main?.visibleFrame.height ?? 900) - 40)

    private var mode: StemJob.Mode { StemJob.Mode(rawValue: modeRaw) ?? .best }
    private var linkIsValid: Bool { link.trimmingCharacters(in: .whitespaces).range(of: "^https?://", options: .regularExpression) != nil }
    private var audioReady: Bool { audio != nil && !clip.loading }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 40, height: 40)
                Text("StemMission").font(.title2.bold())
                    .foregroundStyle(LinearGradient(colors: [.white, Theme.pink],
                                                    startPoint: .leading, endPoint: .trailing))
                Spacer()
                Button(action: startOver) {
                    Label("Start Over", systemImage: "arrow.counterclockwise")
                }
                .disabled(job.running || (source == nil && job.resultFolder == nil && job.error == nil))
                .help("Clear the song, trim and results. Quality, sample rate and output folder are kept.")
            }

            // steps scroll inside a fixed-height window; the Generate button stays pinned below
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if !job.isSetUp { setupBox }

                        StepCard(number: 1, title: "Choose your song", unlocked: job.isSetUp, done: audio != nil,
                                 lockedHint: "after setup") { sourceStep }
                            .id(1)

                        StepCard(number: 2, title: "Trim (optional)", unlocked: audioReady, done: trimDone,
                                 lockedHint: "after step 1") { trimStep }
                            .disabled(job.running)
                            .id(2)

                        StepCard(number: 3, title: "Settings", unlocked: audioReady && trimDone,
                                 lockedHint: "after step 2") { qualityStep }
                            .disabled(job.running)
                            .id(3)
                    }
                }
                .scrollIndicators(.automatic)
                // bring a step into view as soon as it opens
                .onChange(of: audioReady) { if audioReady { withAnimation { proxy.scrollTo(2, anchor: .bottom) } } }
                .onChange(of: trimDone) { if trimDone { withAnimation { proxy.scrollTo(3, anchor: .bottom) } } }
            }

            Button {
                clip.stop()
                job.start(input: audio!.path, outputDir: outputDir, mode: mode, sampleRate: sampleRate,
                          trim: clip.isTrimmed ? (clip.start, clip.end) : nil)
            } label: {
                Label("Generate Stems", systemImage: "sparkles")
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .controlSize(.extraLarge)
            .buttonStyle(.borderedProminent)
            .disabled(!(audioReady && trimDone) || job.running)
            .keyboardShortcut(.defaultAction)

            if job.kind == .stems { jobStatus }

            if let folder = job.resultFolder {
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(folder.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                }
            }
        }
        .padding(22)
        .frame(width: 560, height: Self.windowHeight)
        .groupBoxStyle(NebulaCard())
        .tint(Theme.accent)
        .background(NebulaBackground().ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onChange(of: link) { if source == .link { setAudio(nil) } }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard job.isSetUp, !job.running, let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { DispatchQueue.main.async { choose(.file); setAudio(url) } }
            }
            return true
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 10).stroke(.tint, lineWidth: 3).padding(4)
            }
        }
    }

    // MARK: Sections

    private var setupBox: some View {
        GroupBox("One-time setup") {
            VStack(alignment: .leading, spacing: 10) {
                Text("StemMission needs its audio engine before the first run. It downloads Python, the separation libraries and ffmpeg (about 1.2 GB installed) into Application Support. Nothing else on your Mac is touched.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                Text("The first Best-quality run also downloads the AI models (about 1.5 GB).")
                    .font(.caption).foregroundStyle(.secondary)
                Button {
                    job.runSetup()
                } label: {
                    Label("Install", systemImage: "arrow.down.circle").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(job.running)
                if job.kind == .setup { jobStatus }
            }
            .padding(6)
        }
    }

    @ViewBuilder private var sourceStep: some View {
        sourceInputs.disabled(job.running)
        if job.kind == .fetch { jobStatus }
        audioSummary.disabled(job.running)
    }

    @ViewBuilder private var sourceInputs: some View {
        HStack(spacing: 10) {
            OptionCard(icon: "link", title: "Video link", detail: "YouTube or another video site",
                       selected: source == .link) { choose(.link) }
            OptionCard(icon: "waveform", title: "Audio file", detail: "mp3, wav, m4a, flac… from your Mac",
                       selected: source == .file) { choose(.file) }
        }
        .fixedSize(horizontal: false, vertical: true)

        switch source {
        case .link:
            HStack {
                TextField("Paste a link", text: $link)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if linkIsValid { fetch() } }
                Button("Get Audio", action: fetch)
                    .buttonStyle(.borderedProminent)
                    .disabled(!linkIsValid)
            }
        case .file:
            HStack {
                Button("Choose File…", action: pickFile)
                Text("or drop a file on this window").font(.caption).foregroundStyle(.secondary)
            }
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder private var audioSummary: some View {
        if let audio, !(job.kind == .fetch && job.running) {
            HStack(spacing: 8) {
                Image(systemName: "music.note").foregroundStyle(Theme.pink)
                Text(audio.deletingPathExtension().lastPathComponent).lineLimit(1).truncationMode(.middle)
                Spacer()
                if source == .link {
                    Button {
                        saveAudioOnly()
                    } label: {
                        Label("Download without Stems", systemImage: "arrow.down.circle")
                    }
                    .help("Save this audio as a WAV in the output folder and stop here.")
                }
            }
            .font(.callout)
            if let savedAudio {
                Text("Saved to \(savedAudio.deletingLastPathComponent().path)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            if let saveError {
                Text(saveError).font(.caption).foregroundStyle(Theme.error)
            }
        }
    }

    @ViewBuilder private var trimStep: some View {
        TrimPanel(clip: clip)
        if !trimDone {
            HStack {
                Spacer()
                Button {
                    trimDone = true
                } label: {
                    Label(clip.isTrimmed ? "Use Selection" : "Use Whole Song", systemImage: "chevron.right")
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    @ViewBuilder private var qualityStep: some View {
        Text("Quality").font(.caption.weight(.semibold)).foregroundStyle(Theme.pink)
        HStack(spacing: 10) {
            OptionCard(title: "Best", detail: "RoFormer: cleanest stems, slower", recommended: true,
                       selected: mode == .best) { modeRaw = StemJob.Mode.best.rawValue }
            OptionCard(title: "Fast", detail: "Demucs: a few times faster, a bit less clean",
                       selected: mode == .fast) { modeRaw = StemJob.Mode.fast.rawValue }
        }
        .fixedSize(horizontal: false, vertical: true)

        Text("Sample rate").font(.caption.weight(.semibold)).foregroundStyle(Theme.pink)
        HStack(spacing: 10) {
            OptionCard(title: "Auto", detail: "Same as the song", recommended: true,
                       selected: sampleRate == "auto") { sampleRate = "auto" }
            OptionCard(title: "44.1 kHz", detail: "Music projects",
                       selected: sampleRate == "44100") { sampleRate = "44100" }
            OptionCard(title: "48 kHz", detail: "Video projects",
                       selected: sampleRate == "48000") { sampleRate = "48000" }
        }
        .fixedSize(horizontal: false, vertical: true)
        .help("Separation always runs at 44.1 kHz; stems are then written at this rate. Match your DAW project.")

        Text("Save stems to").font(.caption.weight(.semibold)).foregroundStyle(Theme.pink)
        HStack {
            Text(outputDir).font(.callout).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Change…", action: pickOutput)
        }
    }

    @ViewBuilder private var jobStatus: some View {
        if job.running || job.error != nil {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: job.progress)
                HStack {
                    Text(job.status).font(.callout)
                    Spacer()
                    if let start = job.startDate, job.running {
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            Text(elapsed(from: start, to: ctx.date)).monospacedDigit()
                        }
                        .font(.callout).foregroundStyle(.secondary)
                        Button("Cancel", role: .cancel) { job.cancel() }.controlSize(.small)
                    }
                }
                if let err = job.error {
                    ScrollView {
                        Text(err).font(.caption.monospaced()).foregroundStyle(Theme.error).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 90)
                }
            }
        }
    }

    // MARK: Actions

    private func startOver() {
        source = nil
        link = ""
        setAudio(nil)
        job.clearResult()
    }

    private func choose(_ s: Source) {
        guard s != source else { return }
        source = s
        setAudio(nil)
    }

    /// Step 1 result changed: later steps start over.
    private func setAudio(_ url: URL?) {
        audio = url
        trimDone = false
        savedAudio = nil; saveError = nil
        clip.load(path: url?.path ?? "")
    }

    private func fetch() {
        setAudio(nil)
        job.fetch(link: link.trimmingCharacters(in: .whitespaces)) { url in setAudio(url) }
    }

    private func saveAudioOnly() {
        guard let audio else { return }
        let dir = URL(fileURLWithPath: outputDir)
        let name = audio.deletingPathExtension().lastPathComponent
        var dest = dir.appendingPathComponent("\(name).wav")
        var i = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = dir.appendingPathComponent("\(name) (\(i)).wav"); i += 1
        }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: audio, to: dest)
            savedAudio = dest; saveError = nil
            NSWorkspace.shared.activateFileViewerSelecting([dest])
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func elapsed(from: Date, to: Date) -> String {
        let s = Int(to.timeIntervalSince(from))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie, .mpeg4Movie]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { setAudio(url) }
    }

    private func pickOutput() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: outputDir)
        if panel.runModal() == .OK, let url = panel.url { outputDir = url.path }
    }
}

struct StemMissionApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    var body: some Scene {
        WindowGroup("StemMission") { ContentView() }
            .windowResizability(.contentSize)
            .windowStyle(.hiddenTitleBar)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

StemMissionApp.main()
