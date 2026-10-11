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

    @Published var progress: Double = 0
    @Published var status = "Ready"
    @Published var running = false
    @Published var resultFolder: URL?
    @Published var error: String?
    @Published var startDate: Date?
    @Published var isSetUp = FileManager.default.fileExists(atPath: StemJob.readyMarker.path)

    private var process: Process?
    private var buffer = ""
    private var isSetupRun = false

    // setup.sh installs Python, the separation stack and ffmpeg here
    static let homeDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("StemMission")
    static let python = homeDir.appendingPathComponent("env/bin/python")
    static let readyMarker = homeDir.appendingPathComponent("env/.stemmission-ready")

    func runSetup() {
        guard let script = Bundle.main.url(forResource: "setup", withExtension: "sh") else {
            error = "setup.sh not found"; return
        }
        launch(URL(fileURLWithPath: "/bin/zsh"), [script.path], setup: true)
    }

    func start(input: String, outputDir: String, mode: Mode, sampleRate: String, downloadOnly: Bool = false) {
        guard let worker = Bundle.main.url(forResource: "worker", withExtension: "py") else {
            error = "worker.py not found"; return
        }
        launch(Self.python, ["-u", worker.path, "--input", input, "--outdir", outputDir,
                             "--mode", mode.rawValue, "--sample-rate", sampleRate]
                            + (downloadOnly ? ["--download-only"] : []), setup: false)
    }

    private func launch(_ executable: URL, _ arguments: [String], setup: Bool) {
        progress = 0; status = "Starting…"; error = nil; resultFolder = nil
        running = true; startDate = Date(); buffer = ""; isSetupRun = setup

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
        case "DONE" where isSetupRun:
            progress = 1; status = "Setup complete"
            isSetUp = FileManager.default.fileExists(atPath: Self.readyMarker.path)
        case "DONE":
            let path = String(line.dropFirst(5))
            resultFolder = URL(fileURLWithPath: path)
            progress = 1; status = "Done"
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
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

// MARK: - UI

struct ContentView: View {
    @StateObject private var job = StemJob()
    @State private var input = ""
    @AppStorage("outputDir") private var outputDir = FileManager.default
        .homeDirectoryForCurrentUser.appendingPathComponent("Music/Stems").path
    @AppStorage("mode") private var modeRaw = StemJob.Mode.best.rawValue
    @AppStorage("sampleRate") private var sampleRate = "auto"
    @State private var dropTargeted = false

    private var mode: StemJob.Mode { StemJob.Mode(rawValue: modeRaw) ?? .best }
    private var canStart: Bool { job.isSetUp && !job.running && !input.trimmingCharacters(in: .whitespaces).isEmpty }
    private var isLink: Bool { input.trimmingCharacters(in: .whitespaces).range(of: "^https?://", options: .regularExpression) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 40, height: 40)
                Text("StemMission").font(.title2.bold())
                    .foregroundStyle(LinearGradient(colors: [.white, Theme.pink],
                                                    startPoint: .leading, endPoint: .trailing))
            }

            if !job.isSetUp {
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
                    }
                    .padding(6)
                }
            }

            GroupBox("Source") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("Paste a YouTube link, or type / drop a file path", text: $input)
                            .textFieldStyle(.roundedBorder)
                        Button("Choose File…", action: pickFile)
                    }
                    Text("mp3, wav, m4a, flac… or any YouTube link")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(6)
            }

            GroupBox("Output folder") {
                HStack {
                    Text(outputDir).lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Change…", action: pickOutput)
                }
                .padding(6)
            }

            Picker("Mode", selection: $modeRaw) {
                ForEach(StemJob.Mode.allCases) { Text($0.label).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .disabled(job.running)

            Picker("Sample rate", selection: $sampleRate) {
                Text("Auto").tag("auto")
                Text("44.1 kHz").tag("44100")
                Text("48 kHz").tag("48000")
            }
            .pickerStyle(.segmented)
            .disabled(job.running)
            .help("Separation always runs at 44.1 kHz; stems and downloads are then written at this rate. Match your DAW project.")

            HStack {
                Button {
                    job.start(input: input, outputDir: outputDir, mode: mode, sampleRate: sampleRate)
                } label: {
                    Label("Generate Stems", systemImage: "sparkles").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(!canStart)
                .keyboardShortcut(.defaultAction)

                Button {
                    job.start(input: input, outputDir: outputDir, mode: mode, sampleRate: sampleRate, downloadOnly: true)
                } label: {
                    Label("Download Only", systemImage: "arrow.down.circle")
                }
                .controlSize(.large)
                .disabled(!canStart || !isLink)
                .help("Save the link's audio as a WAV in the output folder, without making stems.")

                if job.running {
                    Button("Cancel", role: .cancel) { job.cancel() }.controlSize(.large)
                }
            }

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
                    } else {
                        Text("\(Int(job.progress * 100))%").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }

            if let err = job.error {
                ScrollView {
                    Text(err).font(.caption.monospaced()).foregroundStyle(Theme.error).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 90)
            }

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
        .frame(width: 560)
        .groupBoxStyle(NebulaCard())
        .tint(Theme.accent)
        .background(NebulaBackground().ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { DispatchQueue.main.async { input = url.path } }
            }
            return true
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 10).stroke(.tint, lineWidth: 3).padding(4)
            }
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
        if panel.runModal() == .OK, let url = panel.url { input = url.path }
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
