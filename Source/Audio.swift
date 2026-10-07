import AVFoundation
import SwiftUI

struct AudioSummary {
    var peaks: [Float]
    var duration: Double
    var sampleRate: Double
    var channels: Int
}

enum WaveformReader {
    static func read(_ url: URL, bins: Int = 600) throws -> AudioSummary {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        guard file.length > 0, format.sampleRate > 0, bins > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16384) else {
            throw NSError(domain: "CubaseShelf", code: 2, userInfo: [NSLocalizedDescriptionKey: "音频为空或格式不受支持。"])
        }
        var peaks = [Float](repeating: 0, count: bins)
        var offset: Int64 = 0
        while offset < file.length {
            try Task.checkCancellation()
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(16384, file.length - offset)))
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }
            for frame in 0..<Int(buffer.frameLength) {
                let index = min(bins - 1, Int(Double(offset + Int64(frame)) / Double(file.length) * Double(bins)))
                for channel in 0..<Int(format.channelCount) {
                    let value = abs(channels[channel][frame])
                    if value.isFinite { peaks[index] = max(peaks[index], value) }
                }
            }
            offset += Int64(buffer.frameLength)
        }
        return AudioSummary(peaks: peaks, duration: Double(file.length) / format.sampleRate, sampleRate: format.sampleRate, channels: Int(format.channelCount))
    }
}

@MainActor final class PreviewPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var selected: FileEntry?
    @Published var projectName = ""
    @Published var playing = false
    @Published var time: Double = 0
    @Published var duration: Double = 0
    @Published var volume: Float = 0.7 { didSet { player?.volume = volume } }
    @Published var summary: AudioSummary?
    @Published var loading = false
    @Published var error: String?
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var waveformTask: Task<Void, Never>?
    private var readerTask: Task<AudioSummary, Error>?
    private var projectID: String?
    private var generation = UUID()

    override init() {
        super.init()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.player else { return }
                self.time = player.currentTime
                self.playing = player.isPlaying
            }
        }
    }

    func load(_ entry: FileEntry, project: Project, autoplay: Bool = false) {
        guard selected?.path != entry.path else { if autoplay { toggle() }; return }
        let shouldPlay = autoplay || (playing && projectID == project.id)
        let previousTime = projectID == project.id ? time : 0
        player?.stop(); player = nil
        waveformTask?.cancel(); readerTask?.cancel()
        generation = UUID()
        let token = generation
        selected = entry; projectID = project.id; projectName = project.name
        summary = nil; playing = false; duration = 0; time = 0; error = nil; loading = false
        do {
            let audio = try AVAudioPlayer(contentsOf: entry.url)
            audio.delegate = self; audio.volume = volume; audio.prepareToPlay()
            duration = audio.duration
            audio.currentTime = min(previousTime, max(0, duration))
            time = audio.currentTime; player = audio
            if shouldPlay && previousTime < duration { playing = audio.play() }
            loading = true
            let task = Task.detached(priority: .utility) { try WaveformReader.read(entry.url) }
            readerTask = task
            waveformTask = Task { [weak self] in
                do {
                    let result = try await task.value
                    guard let self, !Task.isCancelled, self.generation == token else { return }
                    self.summary = result; self.loading = false
                } catch {
                    guard let self, !Task.isCancelled, self.generation == token else { return }
                    self.loading = false
                    if !(error is CancellationError) { self.error = "波形分析失败：\(error.localizedDescription)" }
                }
            }
        } catch { self.error = "无法播放 \(entry.name)：\(error.localizedDescription)" }
    }

    func toggle() {
        guard let player else { return }
        if player.isPlaying { player.pause(); playing = false }
        else {
            if player.currentTime >= player.duration - 0.05 { player.currentTime = 0 }
            playing = player.play()
            if !playing { error = "无法开始播放，请检查音频输出设备。" }
        }
    }
    func stop() { player?.stop(); player?.currentTime = 0; time = 0; playing = false }
    func seek(_ seconds: Double) { time = min(max(0, seconds), duration); player?.currentTime = time }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard self.player === player else { return }
            self.playing = false; self.time = self.duration
            if !flag { self.error = "音频播放未正常完成。" }
        }
    }
}

struct WaveformView: View {
    @ObservedObject var player: PreviewPlayer
    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                let peaks = player.summary?.peaks ?? []
                guard !peaks.isEmpty else { return }
                let width = size.width / CGFloat(peaks.count)
                let fraction = player.duration > 0 ? player.time / player.duration : 0
                for (index, peak) in peaks.enumerated() {
                    let height = max(2, CGFloat(min(1, peak)) * size.height * 0.9)
                    let rect = CGRect(x: CGFloat(index) * width, y: (size.height - height) / 2, width: max(1, width * 0.72), height: height)
                    context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(Double(index) / Double(peaks.count) <= fraction ? .mint : .mint.opacity(0.3)))
                }
                let x = CGFloat(fraction) * size.width
                context.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)), with: .color(.white.opacity(0.8)))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                player.seek(Double(value.location.x / max(1, geometry.size.width)) * player.duration)
            })
            .overlay { if player.loading { ProgressView("正在生成波形…").font(.caption) } }
        }
        .accessibilityLabel("音频波形，拖动可定位播放位置")
    }
}

func formatTime(_ seconds: Double) -> String {
    let total = Int(max(0, seconds.isFinite ? seconds : 0))
    return String(format: "%d:%02d", total / 60, total % 60)
}
