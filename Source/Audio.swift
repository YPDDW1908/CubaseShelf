import AVFoundation
import SwiftUI

struct AudioSummary {
    var peaks: [Float]
    var duration: Double
    var sampleRate: Double
    var channels: Int
    var loudness: LoudnessResult? = nil
    var sourceBitDepth: Int? = nil
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
        let resolved = LoudnessChannelLayout.weights(channels:Int(format.channelCount),layout:format.channelLayout)
        // An explicit unsupported stereo layout (e.g. mid/side) must not fall back to L/R.
        let meter = LoudnessMeter(rate: format.sampleRate, channels: Int(format.channelCount),weights:resolved ?? [])
        var offset: Int64 = 0
        while offset < file.length {
            try Task.checkCancellation()
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(16384, file.length - offset)))
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else {
                throw NSError(domain:"CubaseShelf",code:11,userInfo:[NSLocalizedDescriptionKey:"音频解码提前结束，未显示不完整的分析结果。"])
            }
            meter.consume(channels, count: Int(buffer.frameLength))
            for frame in 0..<Int(buffer.frameLength) {
                let index = min(bins - 1, Int(Double(offset + Int64(frame)) / Double(file.length) * Double(bins)))
                for channel in 0..<Int(format.channelCount) {
                    let value = abs(channels[channel][frame])
                    if value.isFinite { peaks[index] = max(peaks[index], value) }
                }
            }
            offset += Int64(buffer.frameLength)
        }
        return AudioSummary(peaks: peaks, duration: Double(file.length) / format.sampleRate, sampleRate: format.sampleRate, channels: Int(format.channelCount), loudness: meter.finish(), sourceBitDepth: file.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatLinearPCM ? Int(file.fileFormat.streamDescription.pointee.mBitsPerChannel) : nil)
    }
}

@MainActor final class PreviewPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var selected: FileEntry?
    @Published var projectName = ""
    @Published var playing = false
    @Published var time: Double = 0
    @Published var duration: Double = 0
    @Published var volume: Float = 0.7 { didSet { player?.setVolume(volume, fadeDuration: 0.04) } }
    @Published var summary: AudioSummary?
    @Published var loading = false
    @Published var error: String?
    @Published var normalizationEnabled = false { didSet { if oldValue != normalizationEnabled { preparePlayback() } } }
    @Published var targetLUFS: Double = -18 { didSet { if oldValue != targetLUFS && normalizationEnabled { preparePlayback() } } }
    @Published private(set) var waitingForAlignment = false
    @Published private(set) var wantsPlayback = false
    @Published private(set) var alignmentStatus = "原音试听"
    @Published private(set) var appliedGainDB: Double?
    var playbackActive: Bool { playing || (waitingForAlignment && wantsPlayback) }
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var waveformTask: Task<Void, Never>?
    private var readerTask: Task<AudioSummary, Error>?
    private var renderTask: Task<URL, Error>?
    private var renderCompletion: Task<Void, Never>?
    private var renderedURL: URL?
    private var summaryCache: [String: AudioSummary] = [:]
    private var loadedKey: String?
    private var projectID: String?
    private var generation = UUID()
    private var alignmentGeneration = UUID()

    override init() {
        super.init()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.player else { return }
                if !self.waitingForAlignment { self.time = player.currentTime; self.playing = player.isPlaying }
            }
        }
    }
    private func cacheKey(_ entry: FileEntry) -> String {
        let values = try? entry.url.resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey])
        return "\(entry.path)|\((values?.contentModificationDate ?? entry.modified).timeIntervalSince1970)|\(values?.fileSize ?? 0)"
    }
    func load(_ entry: FileEntry, project: Project, autoplay: Bool = false) {
        let currentKey = cacheKey(entry)
        guard selected != entry || loadedKey != currentKey || error != nil else { if autoplay { toggle() }; return }
        loadedKey = currentKey
        let shouldPlay = autoplay || (playbackActive && projectID == project.id)
        let previousTime = projectID == project.id ? time : 0
        player?.stop(); player = nil
        waveformTask?.cancel(); readerTask?.cancel(); cancelRender()
        if let old = renderedURL { try? FileManager.default.removeItem(at: old) }; renderedURL = nil
        generation = UUID(); let token = generation
        selected = entry; projectID = project.id; projectName = project.name
        summary = nil; playing = false; duration = 0; time = previousTime; error = nil; loading = true
        wantsPlayback = shouldPlay; appliedGainDB = nil
        do {
            let audio = try AVAudioPlayer(contentsOf: entry.url)
            audio.delegate = self; audio.volume = volume; audio.prepareToPlay()
            duration = audio.duration; time = min(previousTime,duration); audio.currentTime = time; player = audio
            waitingForAlignment = normalizationEnabled
            alignmentStatus = normalizationEnabled ? "等待分析后对齐；不会先播放原音" : "原音试听"
            if shouldPlay && !normalizationEnabled && time < duration { startPlayback() }
            let key = cacheKey(entry)
            if let cached = summaryCache[key] { summary = cached; loading = false; preparePlayback(); return }
            let task = Task.detached(priority: .utility) { try WaveformReader.read(entry.url) }; readerTask = task
            waveformTask = Task { [weak self] in
                do {
                    let result = try await task.value
                    guard let self, !Task.isCancelled, self.generation == token else { return }
                    guard self.cacheKey(entry) == key else { self.error = "音频在分析期间发生变化，请重新选择。"; self.loading = false; self.waitingForAlignment = false; self.wantsPlayback = false; return }
                    if self.summaryCache.count >= 8 { self.summaryCache.removeAll() }
                    self.summaryCache[key] = result; self.summary = result; self.loading = false
                    if self.normalizationEnabled { self.preparePlayback() }
                } catch {
                    guard let self, !Task.isCancelled, self.generation == token else { return }
                    self.loading = false
                    if self.normalizationEnabled { self.waitingForAlignment = false; self.wantsPlayback = false; self.alignmentStatus = "分析失败；关闭对齐可原音试听" }
                    if !(error is CancellationError) { self.error = "音频分析失败：\(error.localizedDescription)" }
                }
            }
        } catch { loading = false; wantsPlayback = false; waitingForAlignment = false; self.error = "无法播放 \(entry.name)：\(error.localizedDescription)" }
    }
    private func cancelRender() {
        alignmentGeneration = UUID(); renderTask?.cancel(); renderCompletion?.cancel()
    }
    private func install(_ url: URL, normalized: Bool) throws {
        let audio = try AVAudioPlayer(contentsOf: url)
        audio.delegate = self; audio.volume = volume; audio.prepareToPlay()
        audio.currentTime = min(time,audio.duration)
        player?.stop(); player = audio
        let previous = renderedURL; renderedURL = normalized ? url : nil
        if let previous, previous != url { try? FileManager.default.removeItem(at: previous) }
        waitingForAlignment = false
        if wantsPlayback && time < duration { startPlayback() }
    }
    private func preparePlayback() {
        guard let entry = selected else { return }
        if playing { time = player?.currentTime ?? time; wantsPlayback = true }
        player?.pause(); playing = false; cancelRender(); appliedGainDB = nil
        if !normalizationEnabled {
            alignmentStatus = "原音试听"; waitingForAlignment = false
            do { try install(entry.url,normalized: false) } catch { self.error = error.localizedDescription; wantsPlayback = false }
            return
        }
        waitingForAlignment = true
        guard !loading else { alignmentStatus = "等待分析后对齐；不会先播放原音"; return }
        guard let plan = AlignmentPlan.make(summary?.loudness,target: targetLUFS) else {
            waitingForAlignment = false; wantsPlayback = false
            alignmentStatus = "无法对齐：静音、短音频或不支持的格式；关闭对齐可原音试听"; return
        }
        let token = alignmentGeneration
        let key = cacheKey(entry)
        alignmentStatus = "正在准备对齐试听…"
        let task = Task.detached(priority: .utility) { try AlignedAudioRenderer.render(entry.url,gain: plan.multiplier) }
        renderTask = task
        renderCompletion = Task { [weak self] in
            do {
                let url = try await task.value
                guard let self, !Task.isCancelled, self.alignmentGeneration == token else { try? FileManager.default.removeItem(at: url); return }
                guard self.cacheKey(entry) == key else { try? FileManager.default.removeItem(at: url); throw NSError(domain: "CubaseShelf",code:10,userInfo:[NSLocalizedDescriptionKey:"音频在对齐期间发生变化，请重新选择。"]) }
                do { try self.install(url,normalized: true) }
                catch { try? FileManager.default.removeItem(at: url); throw error }
                self.appliedGainDB = plan.gainDB
                self.alignmentStatus = String(format:"增益 %+.1f dB · 预计 %.1f LUFS%@",plan.gainDB,plan.expectedLUFS,plan.limited ? " · 受峰值／+12 dB 上限限制，未达到目标" : " · 已对齐")
            } catch {
                guard let self, !Task.isCancelled, self.alignmentGeneration == token else { return }
                self.waitingForAlignment = false; self.wantsPlayback = false
                self.alignmentStatus = "对齐失败；关闭开关可原音试听"
                self.error = error.localizedDescription
            }
        }
    }
    private func startPlayback() {
        guard let player else { return }
        playing = player.play(); wantsPlayback = playing
        if !playing { error = "无法开始播放，请检查音频输出设备。" }
    }
    func toggle() {
        guard let player else { return }
        if waitingForAlignment { wantsPlayback.toggle(); return }
        if player.isPlaying { player.pause(); playing = false; wantsPlayback = false }
        else {
            if normalizationEnabled && appliedGainDB == nil { wantsPlayback = true; preparePlayback(); return }
            if player.currentTime >= player.duration-0.05 { player.currentTime = 0; time = 0 }
            startPlayback()
        }
    }
    func stop() { wantsPlayback = false; player?.stop(); player?.currentTime = 0; time = 0; playing = false }
    func seek(_ seconds: Double) { time = min(max(0, seconds), duration); player?.currentTime = time }
    func shutdown() {
        stop(); timer?.invalidate(); waveformTask?.cancel(); readerTask?.cancel(); cancelRender()
        if let url = renderedURL { try? FileManager.default.removeItem(at: url) }; renderedURL = nil
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard self.player === player else { return }
            self.playing = false; self.wantsPlayback = false; self.time = self.duration
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
                    context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(Double(index) / Double(peaks.count) <= fraction ? ShelfTheme.accent : ShelfTheme.accent.opacity(0.3)))
                }
                let x = CGFloat(fraction) * size.width
                context.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)), with: .color(.primary.opacity(0.8)))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                player.seek(Double(value.location.x / max(1, geometry.size.width)) * player.duration)
            })
            .overlay { if player.loading { ProgressView("正在分析波形与响度…").font(.caption) } }
        }
        .accessibilityLabel("音频波形，拖动可定位播放位置")
    }
}

func formatTime(_ seconds: Double) -> String {
    let total = Int(max(0, seconds.isFinite ? seconds : 0))
    return String(format: "%d:%02d", total / 60, total % 60)
}
