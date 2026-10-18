import AVFoundation
import SwiftUI

// MARK: - Clip (waveform, trim range, preview)

final class AudioClip: ObservableObject {
    @Published private(set) var url: URL?
    @Published private(set) var peaks: [Float] = []
    @Published private(set) var duration: Double = 0
    @Published private(set) var loading = false
    @Published private(set) var loadError: String?
    @Published var start: Double = 0
    @Published var end: Double = 0
    @Published private(set) var playhead: Double?

    static let minLength = 1.0
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var loadID = UUID()

    var isPlaying: Bool { playhead != nil }
    var isTrimmed: Bool { duration > 0 && (start > 0.01 || end < duration - 0.01) }

    /// Loads the waveform when `path` is an existing local file; clears it otherwise (e.g. a link).
    func load(path: String) {
        let p = (path.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        let newURL: URL? = FileManager.default.fileExists(atPath: p) ? URL(fileURLWithPath: p) : nil
        guard newURL != url else { return }
        stop()
        url = newURL; peaks = []; duration = 0; start = 0; end = 0; loadError = nil
        guard let newURL else { loading = false; return }

        loading = true
        let id = UUID(); loadID = id
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try Self.readPeaks(newURL, bins: 320) }
            DispatchQueue.main.async {
                guard self.loadID == id else { return }  // a newer file was chosen meanwhile
                self.loading = false
                switch result {
                case .success(let (peaks, duration)):
                    self.peaks = peaks; self.duration = duration; self.end = duration
                case .failure:
                    self.loadError = "No waveform for this file type; the whole file will be used."
                }
            }
        }
    }

    func resetTrim() { start = 0; end = duration }

    func togglePreview() {
        if isPlaying { stop(); return }
        guard let url, let p = try? AVAudioPlayer(contentsOf: url) else { return }
        p.currentTime = start
        p.play()
        player = p
        playhead = start
        // .common mode keeps the playhead moving while a trim handle is being dragged
        let t = Timer(timeInterval: 1 / 30, repeats: true) { [weak self] _ in
            guard let self, let player = self.player else { return }
            if !player.isPlaying || player.currentTime >= self.end { self.stop() } else { self.playhead = player.currentTime }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        player?.stop(); player = nil
        timer?.invalidate(); timer = nil
        playhead = nil
    }

    /// Max |sample| per bin over all channels; normalised to 0...1 unless `normalize` is false
    /// (stems keep their real level, so a near-silent stem looks near-silent).
    static func readPeaks(_ url: URL, bins: Int, normalize: Bool = true) throws -> ([Float], Double) {
        let file = try AVAudioFile(forReading: url)
        let total = file.length
        let format = file.processingFormat
        guard total > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1 << 16) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var peaks = [Float](repeating: 0, count: bins)
        let perBin = max(1, Int((total + Int64(bins) - 1) / Int64(bins)))
        var pos = 0
        while file.framePosition < total {  // read(into:) throws at EOF instead of returning 0 frames
            try file.read(into: buf)
            let n = Int(buf.frameLength)
            if n == 0 { break }
            for c in 0..<Int(format.channelCount) {
                let d = buf.floatChannelData![c]
                for i in 0..<n {
                    let b = min(bins - 1, (pos + i) / perBin)
                    peaks[b] = max(peaks[b], abs(d[i]))
                }
            }
            pos += n
        }
        if normalize, let top = peaks.max(), top > 0 { peaks = peaks.map { $0 / top } }
        if !normalize { peaks = peaks.map { min(1, $0) } }
        return (peaks, Double(total) / format.sampleRate)
    }
}

func formatTime(_ s: Double) -> String {
    let t = max(0, s)
    return String(format: "%d:%04.1f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60))
}

// MARK: - Waveform with trim handles

struct WaveformView: View {
    @ObservedObject var clip: AudioClip
    @State private var draggingStart: Bool?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let x = { (t: Double) in clip.duration > 0 ? CGFloat(t / clip.duration) * w : 0 }
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    let n = clip.peaks.count
                    guard n > 0 else { return }
                    let step = size.width / CGFloat(n)
                    let sel = (x(clip.start), x(clip.end))
                    for (i, p) in clip.peaks.enumerated() {
                        let bx = CGFloat(i) * step
                        let bh = max(1.5, CGFloat(p) * (size.height - 6))
                        let bar = Path(roundedRect: CGRect(x: bx, y: (size.height - bh) / 2,
                                                           width: max(1, step - 1), height: bh), cornerRadius: 1)
                        let inside = bx + step / 2 >= sel.0 && bx + step / 2 <= sel.1
                        ctx.fill(bar, with: inside
                                 ? .linearGradient(Gradient(colors: [Theme.pink, Theme.orchid, Theme.accent]),
                                                   startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: size.height))
                                 : .color(.white.opacity(0.18)))
                    }
                }

                // selected region outline
                RoundedRectangle(cornerRadius: 4)
                    .fill(Theme.accent.opacity(0.10))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.orchid.opacity(0.6), lineWidth: 1))
                    .frame(width: max(0, x(clip.end) - x(clip.start)), height: h)
                    .offset(x: x(clip.start))

                handle.offset(x: x(clip.start) - 5)
                handle.offset(x: x(clip.end) - 5)

                if let t = clip.playhead {
                    Rectangle().fill(.white).frame(width: 1.5, height: h).offset(x: x(t))
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    guard clip.duration > 0 else { return }
                    let t = min(max(0, Double(g.location.x / w) * clip.duration), clip.duration)
                    // grab whichever handle is closer to where the drag began
                    let isStart = draggingStart ?? (abs(t - clip.start) <= abs(t - clip.end))
                    draggingStart = isStart
                    if isStart { clip.start = min(t, clip.end - AudioClip.minLength) }
                    else { clip.end = max(t, clip.start + AudioClip.minLength) }
                    clip.start = max(0, clip.start); clip.end = min(clip.duration, clip.end)
                }
                .onEnded { _ in draggingStart = nil })
        }
        .frame(height: 76)
    }

    private var handle: some View {
        Capsule().fill(.white)
            .frame(width: 4, height: 34)
            .padding(.horizontal, 3)
            .frame(maxHeight: .infinity)
            .shadow(color: Theme.accent, radius: 3)
    }
}

// MARK: - Trim panel (waveform + times + preview)

struct TrimPanel: View {
    @ObservedObject var clip: AudioClip

    var body: some View {
        if clip.loading {
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Reading audio…") }
                .font(.caption).foregroundStyle(.secondary)
        } else if let err = clip.loadError {
            Text(err).font(.caption).foregroundStyle(.secondary)
        } else if clip.duration > 0 {
            VStack(alignment: .leading, spacing: 6) {
                WaveformView(clip: clip)
                HStack(spacing: 14) {
                    Button { clip.togglePreview() } label: {
                        Image(systemName: clip.isPlaying ? "stop.fill" : "play.fill").frame(width: 14)
                    }
                    .help("Preview the selected part")
                    timeLabel("Start", clip.start)
                    timeLabel("End", clip.end)
                    timeLabel("Length", clip.end - clip.start)
                    Spacer()
                    if clip.isTrimmed {
                        Button("Reset") { clip.resetTrim() }.controlSize(.small)
                    }
                }
                .font(.caption)
                Text(clip.isTrimmed ? "Only the selected part will be separated." : "Drag the edges to separate only part of the song.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func timeLabel(_ title: String, _ t: Double) -> some View {
        HStack(spacing: 4) {
            Text(title).foregroundStyle(.secondary)
            Text(formatTime(t)).monospacedDigit()
        }
    }
}
