import AppKit
import AVFoundation
import SwiftUI

// MARK: - Library store

/// Finished stem folders found in the output folder, newest first.
final class StemLibrary: ObservableObject {
    struct Section: Hashable {
        let start: Double
        let beatsPerBar: Int
        let bars: Int
    }

    struct Item: Identifiable, Hashable {
        let folder: URL
        let date: Date
        let stems: [URL]
        let bpm: Double?
        let sections: [Section]
        /// "4/4" for one meter throughout, "Mixed meter" when it changes; nil when unknown.
        var meter: String? {
            let all = Set(sections.map(\.beatsPerBar))
            guard let only = all.first else { return nil }
            return all.count == 1 ? "\(only)/4" : "Mixed meter"
        }
        var id: URL { folder }
        var click: URL? { stems.first { $0.deletingPathExtension().lastPathComponent.hasSuffix(" Click") } }
        // "Song - Stems (2)" -> "Song (2)"
        var title: String { folder.lastPathComponent.replacingOccurrences(of: " - Stems", with: "") }
    }

    @Published private(set) var items: [Item] = []

    func refresh(in dir: String) {
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: dir),
                                                   includingPropertiesForKeys: [.creationDateKey],
                                                   options: .skipsHiddenFiles)) ?? []
        items = folders.compactMap { f -> Item? in
            guard f.lastPathComponent.contains(" - Stems") else { return nil }
            let wavs = ((try? fm.contentsOfDirectory(at: f, includingPropertiesForKeys: nil,
                                                     options: .skipsHiddenFiles)) ?? [])
                .filter { $0.pathExtension.lowercased() == "wav" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            guard !wavs.isEmpty else { return nil }  // unfinished or failed run (only _work inside)
            let date = (try? f.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            // written by the worker's smart metronome; missing for older runs
            let analysis = (try? Data(contentsOf: f.appendingPathComponent("analysis.json")))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let sections = (analysis?["sections"] as? [[String: Any]] ?? []).compactMap { d -> Section? in
                guard let start = d["start"] as? Double, let m = d["beats_per_bar"] as? Int,
                      let bars = d["bars"] as? Int else { return nil }
                return Section(start: start, beatsPerBar: m, bars: bars)
            }
            return Item(folder: f, date: date, stems: wavs, bpm: analysis?["bpm"] as? Double, sections: sections)
        }
        .sorted { $0.date > $1.date }
    }

    func trash(_ item: Item) throws {
        try FileManager.default.trashItem(at: item.folder, resultingItemURL: nil)
        items.removeAll { $0 == item }
    }
}

// MARK: - Playback and waveforms

/// Plays one stem at a time, optionally with the click track in sync.
final class StemPlayer: ObservableObject {
    @Published private(set) var playing: URL?
    @Published private(set) var position: Double = 0  // 0...1 of the playing file
    @Published private(set) var click: URL?

    private var player: AVAudioPlayer?
    private var clickPlayer: AVAudioPlayer?
    private var timer: Timer?

    /// Turn the click on (with its file) or off; a playing stem restarts in place with the new setting.
    func setClick(_ url: URL?) {
        click = url
        if let playing { let at = position; stop(keepClick: true); play(playing, from: at) }
    }

    func toggle(_ url: URL) {
        if playing == url { stop() } else { play(url, from: 0) }
    }

    func play(_ url: URL, from fraction: Double) {
        if playing != url {
            stop()
            guard let p = try? AVAudioPlayer(contentsOf: url) else { return }
            player = p; playing = url
            let t = Timer(timeInterval: 1 / 30, repeats: true) { [weak self] _ in
                guard let self, let p = self.player else { return }
                if p.isPlaying { self.position = p.currentTime / max(p.duration, 0.001) } else { self.stop() }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
        guard let p = player else { return }
        let at = fraction * p.duration
        p.currentTime = at
        position = fraction
        clickPlayer?.stop(); clickPlayer = nil
        if let click, click != url, let c = try? AVAudioPlayer(contentsOf: click) {
            // stems share one length, so the same offset lines the click up with the stem
            c.currentTime = at
            let start = p.deviceCurrentTime + 0.05
            p.play(atTime: start); c.play(atTime: start)
            clickPlayer = c
        } else {
            p.play()
        }
    }

    func stop(keepClick: Bool = true) {
        player?.stop(); player = nil
        clickPlayer?.stop(); clickPlayer = nil
        timer?.invalidate(); timer = nil
        playing = nil; position = 0
        if !keepClick { click = nil }
    }
}

/// Small un-normalised waveforms for stem rows, read once per file in the background.
final class PeakCache: ObservableObject {
    @Published private(set) var peaks: [URL: [Float]] = [:]
    @Published private(set) var durations: [URL: Double] = [:]
    private var pending: Set<URL> = []

    func request(_ url: URL) {
        guard peaks[url] == nil, !pending.contains(url) else { return }
        pending.insert(url)
        DispatchQueue.global(qos: .utility).async {
            let r = try? AudioClip.readPeaks(url, bins: 110, normalize: false)
            DispatchQueue.main.async {
                self.pending.remove(url)
                self.peaks[url] = r?.0 ?? []
                self.durations[url] = r?.1
            }
        }
    }
}

struct MiniWaveform: View {
    let peaks: [Float]
    var progress: Double?
    var onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                guard !peaks.isEmpty else { return }
                let step = size.width / CGFloat(peaks.count)
                let played = CGFloat(progress ?? 0) * size.width
                for (i, p) in peaks.enumerated() {
                    // sqrt lifts quiet passages so they stay visible without normalising
                    let bh = max(1, CGFloat(sqrt(p)) * size.height)
                    let x = CGFloat(i) * step
                    let bar = Path(CGRect(x: x, y: (size.height - bh) / 2, width: max(1, step - 1), height: bh))
                    ctx.fill(bar, with: .color(progress != nil && x < played ? Theme.pink : .white.opacity(0.32)))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { loc in onSeek(min(max(0, Double(loc.x / geo.size.width)), 1)) }
        }
    }
}

// MARK: - Views

struct LibraryView: View {
    @ObservedObject var library: StemLibrary
    let outputDir: String
    var onCreate: () -> Void

    @State private var selected: StemLibrary.Item?
    @StateObject private var player = StemPlayer()
    @StateObject private var cache = PeakCache()

    var body: some View {
        Group {
            if let item = selected, library.items.contains(item) {
                LibraryDetail(item: item, library: library, player: player, cache: cache) {
                    player.stop(keepClick: false); selected = nil
                }
            } else if library.items.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onDisappear { player.stop(keepClick: false) }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Library").font(.title2.bold())
                Text("\(library.items.count)").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button { library.refresh(in: outputDir) } label: { Image(systemName: "arrow.clockwise") }
                    .help("Rescan the output folder")
            }
            .padding(.top, 8)
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(library.items) { item in
                        Button { selected = item } label: { row(item) }.buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func row(_ item: StemLibrary.Item) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(LinearGradient(colors: [Theme.pink, Theme.accent, Theme.blue],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "waveform").font(.title3.bold())
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.callout.weight(.semibold)).lineLimit(2)
                Text("\(item.date.formatted(.relative(presentation: .named))) · \(item.stems.count) files"
                     + (item.bpm.map { " · \(Int($0.rounded())) BPM" } ?? "")
                     + (item.meter.map { " · \($0)" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.orchid.opacity(0.25), lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "square.stack.3d.up").font(.system(size: 44)).foregroundStyle(Theme.orchid)
            Text("No stems yet").font(.title3.bold())
            Text("Stems you generate are saved in\n\(outputDir)\nand show up here.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button(action: onCreate) { Label("Create Stems", systemImage: "sparkles") }
                .buttonStyle(.borderedProminent).controlSize(.large)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

struct LibraryDetail: View {
    let item: StemLibrary.Item
    @ObservedObject var library: StemLibrary
    @ObservedObject var player: StemPlayer
    @ObservedObject var cache: PeakCache
    var onBack: () -> Void

    @State private var confirmTrash = false
    @State private var trashError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: onBack) { Label("Library", systemImage: "chevron.left") }
                .buttonStyle(.plain).foregroundStyle(Theme.pink)
                .padding(.top, 8)
            Text(item.title).font(.title3.bold()).lineLimit(3)
            HStack {
                Text(item.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
                if let bpm = item.bpm { pill("\(Int(bpm.rounded())) BPM") }
                if let meter = item.meter { pill(meter) }
                Spacer()
                if let clickURL = item.click {
                    Toggle(isOn: Binding(get: { player.click != nil },
                                         set: { player.setClick($0 ? clickURL : nil) })) {
                        Label("Click", systemImage: "metronome")
                    }
                    .toggleStyle(.button)
                    .help("Play the click together with any stem")
                }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.folder]) }
                Button(role: .destructive) { confirmTrash = true } label: { Image(systemName: "trash") }
                    .help("Move this folder to the Trash")
            }
            if let trashError { Text(trashError).font(.caption).foregroundStyle(Theme.error) }
            if Set(item.sections.map(\.beatsPerBar)).count > 1 {
                // where the meter changes, e.g. "0:01 4/4 ×3 → 0:06 7/4 ×2"
                Text(item.sections.map { "\(clock($0.start)) \($0.beatsPerBar)/4 ×\($0.bars)" }.joined(separator: "  →  "))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Click a waveform to play from there. Drag a row into your DAW.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(item.stems, id: \.self) { stemRow($0) }
                }
            }
        }
        .confirmationDialog("Move \"\(item.title)\" to the Trash?", isPresented: $confirmTrash) {
            Button("Move to Trash", role: .destructive) {
                player.stop()
                do { try library.trash(item); onBack() } catch { trashError = error.localizedDescription }
            }
        }
    }

    private func pill(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.bold)).monospacedDigit()
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Theme.accent, in: Capsule())
    }

    private func clock(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }

    private func stemRow(_ url: URL) -> some View {
        let isPlaying = player.playing == url
        // "03 Bass" -> "Bass"
        let name = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: #"^\d+\s+"#, with: "", options: .regularExpression)
        return HStack(spacing: 10) {
            Button { player.toggle(url) } label: {
                Image(systemName: isPlaying ? "stop.fill" : "play.fill").frame(width: 14)
            }
            Text(name).font(.callout).lineLimit(1).frame(width: 130, alignment: .leading)
            MiniWaveform(peaks: cache.peaks[url] ?? [], progress: isPlaying ? player.position : nil) {
                player.play(url, from: $0)
            }
            .frame(height: 26)
            Text(cache.durations[url].map(formatTime) ?? "")
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(isPlaying ? Theme.accent.opacity(0.18) : .white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        .onAppear { cache.request(url) }
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
    }
}

// MARK: - Sidebar

enum AppSection { case create, library }

struct Sidebar: View {
    @Binding var section: AppSection
    let libraryCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            item(.create, "New Stems", "sparkles")
            item(.library, "Library", "square.stack.3d.up", badge: libraryCount)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.top, 48)  // clear the traffic-light buttons of the hidden title bar
    }

    private func item(_ s: AppSection, _ title: String, _ icon: String, badge: Int = 0) -> some View {
        Button { section = s } label: {
            HStack(spacing: 8) {
                Image(systemName: icon).frame(width: 18)
                Text(title)
                Spacer()
                if badge > 0 {
                    Text("\(badge)").font(.caption2.weight(.bold))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.white.opacity(0.15), in: Capsule())
                }
            }
            .font(.callout.weight(section == s ? .semibold : .regular))
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(section == s ? Theme.accent.opacity(0.35) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Root

let defaultOutputDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music/Stems").path

struct RootView: View {
    @State private var section = AppSection.create
    @StateObject private var library = StemLibrary()
    @AppStorage("outputDir") private var outputDir = defaultOutputDir

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(section: $section, libraryCount: library.items.count)
                .frame(width: 170)
                .background(.black.opacity(0.22))
            Rectangle().fill(Theme.orchid.opacity(0.2)).frame(width: 1)
            ZStack(alignment: .topLeading) {
                // kept alive while hidden so a running job and the chosen song survive switching
                ContentView(onFinished: { library.refresh(in: outputDir) })
                    .opacity(section == .create ? 1 : 0)
                    .allowsHitTesting(section == .create)
                    .disabled(section != .create)
                if section == .library {
                    LibraryView(library: library, outputDir: outputDir) { section = .create }
                }
            }
            .frame(width: 560)
        }
        .frame(height: ContentView.windowHeight)
        .background(NebulaBackground().ignoresSafeArea())
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .onAppear { library.refresh(in: outputDir) }
        .onChange(of: outputDir) { library.refresh(in: outputDir) }
        .onChange(of: section) { if section == .library { library.refresh(in: outputDir) } }
    }
}
