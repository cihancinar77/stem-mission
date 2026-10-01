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

    private var process: Process?
    private var buffer = ""

    static let venvPython = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Music/_sepvenv/bin/python")

    var workerURL: URL? { Bundle.main.url(forResource: "worker", withExtension: "py") }

    func start(input: String, outputDir: String, mode: Mode) {
        guard let worker = workerURL else { error = "worker.py not found"; return }
        guard FileManager.default.isExecutableFile(atPath: Self.venvPython.path) else {
            error = "Python environment not found: \(Self.venvPython.path)"; return
        }
        progress = 0; status = "Starting…"; error = nil; resultFolder = nil
        running = true; startDate = Date(); buffer = ""

        let p = Process()
        p.executableURL = Self.venvPython
        p.arguments = ["-u", worker.path, "--input", input, "--outdir", outputDir, "--mode", mode.rawValue]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
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

// MARK: - UI

struct ContentView: View {
    @StateObject private var job = StemJob()
    @State private var input = ""
    @AppStorage("outputDir") private var outputDir = FileManager.default
        .homeDirectoryForCurrentUser.appendingPathComponent("Music/Stems").path
    @AppStorage("mode") private var modeRaw = StemJob.Mode.best.rawValue
    @State private var dropTargeted = false

    private var mode: StemJob.Mode { StemJob.Mode(rawValue: modeRaw) ?? .best }
    private var canStart: Bool { !job.running && !input.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "waveform.path").font(.title).foregroundStyle(.tint)
                Text("StemMission").font(.title2.bold())
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

            HStack {
                Button {
                    job.start(input: input, outputDir: outputDir, mode: mode)
                } label: {
                    Label("Generate Stems", systemImage: "sparkles").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(!canStart)
                .keyboardShortcut(.defaultAction)

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
                    Text(err).font(.caption.monospaced()).foregroundStyle(.red).textSelection(.enabled)
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
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

StemMissionApp.main()
