import Foundation

struct LoudnessResult {
    var integrated: Double?
    var range: Double?
    var truePeak: Double?
    var samplePeak: Double?
    var momentaryMax: Double? = nil
    var shortTermMax: Double? = nil
    var invalidSamples: Int = 0
    var fullScaleSamples: Int = 0
    var layoutSupported: Bool = true
    static func text(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "—" }
}

private struct Biquad {
    var b0: Double; var b1: Double; var b2: Double; var a1: Double; var a2: Double
    var z1 = 0.0; var z2 = 0.0
    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2; z2 = b2 * x - a2 * y
        return y
    }
    static func shelf(_ rate: Double) -> Biquad {
        let k = tan(.pi * 1681.974450955533 / rate), q = 0.7071752369554196
        let vh = pow(10, 3.999843853973347 / 20), vb = pow(vh, 0.4996667741545416)
        let a = 1 + k / q + k * k
        return Biquad(b0: (vh + vb*k/q + k*k)/a, b1: 2*(k*k-vh)/a, b2: (vh-vb*k/q+k*k)/a,
                      a1: 2*(k*k-1)/a, a2: (1-k/q+k*k)/a)
    }
    static func highpass(_ rate: Double) -> Biquad {
        let k = tan(.pi * 38.13547087602444 / rate), q = 0.5003270373238773
        let a = 1 + k/q + k*k
        return Biquad(b0: 1, b1: -2, b2: 1, a1: 2*(k*k-1)/a, a2: (1-k/q+k*k)/a)
    }
}

// Streaming loudness with optional, explicitly resolved speaker weights.
// Unknown multichannel layouts return no LUFS/LRA.
// BS.1770 K weighting + 400 ms / 100 ms gates; Tech 3342 3 s / 100 ms LRA.
final class LoudnessMeter {
    private let rate: Double
    private let channels: Int
    private var shelves: [Biquad]
    private var highpasses: [Biquad]
    private let peakMeter: TruePeakMeter
    private var frames = 0
    private var chunkFrames = 0
    private var chunkEnergy = 0.0
    private var chunks: [Double] = []
    private var peak = 0.0
    private var truePeak = 0.0
    private let step: Int
    private let weights: [Double]?
    private var invalidSamples = 0
    private var fullScaleSamples = 0
    private var finished: LoudnessResult?
    init(rate: Double, channels: Int, weights explicitWeights: [Double]? = nil) {
        let proposed = explicitWeights ?? (channels == 1 || channels == 2 ? Array(repeating:1.0,count:channels) : [])
        weights = proposed.count == channels && proposed.allSatisfy { $0.isFinite && $0 >= 0 } && proposed.contains(where: { $0 > 0 }) ? proposed : nil
        self.rate = rate; self.channels = channels; step = max(1, Int((rate * 0.1).rounded()))
        shelves = Array(repeating: .shelf(rate), count: channels)
        highpasses = Array(repeating: .highpass(rate), count: channels)
        peakMeter = TruePeakMeter(channels: channels)
    }
    func consume(_ pointers: UnsafePointer<UnsafeMutablePointer<Float>>, count: Int) {
        guard finished == nil, count > 0 else { return }
        if rate >= 44100 { peakMeter.consume(pointers,count:count) }
        for frame in 0..<count {
            var energy = 0.0
            for channel in 0..<channels {
                let raw = Double(pointers[channel][frame]), x = raw.isFinite ? raw : 0
                if !raw.isFinite { invalidSamples += 1 }
                if abs(x) >= 1 { fullScaleSamples += 1 }
                peak = max(peak, abs(x))
                let weighted = highpasses[channel].process(shelves[channel].process(x))
                energy += weighted * weighted * (weights?[channel] ?? 0)
            }
            frames += 1; chunkFrames += 1; chunkEnergy += energy
            if chunkFrames == step { chunks.append(chunkEnergy / Double(step)); chunkFrames = 0; chunkEnergy = 0 }
        }
    }
    func finish() -> LoudnessResult {
        if let finished { return finished }
        if rate >= 44100 { truePeak = peakMeter.finish() }
        func db(_ value: Double) -> Double? { value > 0 ? 20 * log10(value) : nil }
        var result = LoudnessResult(integrated: nil, range: nil, truePeak: rate >= 44100 ? db(max(peak,truePeak)) : nil, samplePeak: db(peak))
        result.invalidSamples = invalidSamples; result.fullScaleSamples = fullScaleSamples
        result.layoutSupported = weights != nil
        defer { finished = result }
        // Sanitizing invalid samples for numerical stability must not silently produce
        // an apparently trustworthy meter result or enable normalization.
        guard invalidSamples == 0 else {
            result.integrated = nil; result.range = nil; result.truePeak = nil; result.samplePeak = nil
            return result
        }
        guard weights != nil, rate >= 8000 else { return result }
        func windows(_ width: Int, _ input: [Double]) -> [Double] {
            guard input.count >= width else { return [] }
            var sum = input.prefix(width).reduce(0,+), values = [sum / Double(width)]
            for i in width..<input.count { sum += input[i] - input[i-width]; values.append(max(0,sum) / Double(width)) }
            return values
        }
        func loudness(_ energy: Double) -> Double { energy > 0 ? -0.691 + 10 * log10(energy) : -.infinity }
        func gated(_ values: [Double], relative: Double) -> [Double] {
            let absolute = values.filter { loudness($0) >= -70 }
            guard !absolute.isEmpty else { return [] }
            let gate = loudness(absolute.reduce(0,+) / Double(absolute.count)) + relative
            return absolute.filter { loudness($0) >= gate }
        }
        let momentary = windows(4,chunks)
        let shortTerm = windows(30,chunks)
        result.momentaryMax = momentary.max().flatMap { $0 > 0 ? loudness($0) : nil }
        result.shortTermMax = shortTerm.max().flatMap { $0 > 0 ? loudness($0) : nil }
        let blocks = gated(momentary, relative: -10)
        if !blocks.isEmpty { result.integrated = loudness(blocks.reduce(0,+) / Double(blocks.count)) }
        // LRA only after >=3 s of actual input; append 1.5 s of silence for file tail.
        if Double(frames)/rate >= 3 {
            // Preserve the partial last 100 ms and decay of the K filters while
            // appending 1.5 s of silence for file-based LRA, without altering LUFS-I.
            var tailChunks = chunks, tailFrames = chunkFrames, tailEnergy = chunkEnergy
            var tailShelves = shelves, tailHighpasses = highpasses
            for _ in 0..<Int((rate*1.5).rounded()) {
                for channel in 0..<channels {
                    let value = tailHighpasses[channel].process(tailShelves[channel].process(0))
                    tailEnergy += value * value * weights![channel]
                }
                tailFrames += 1
                if tailFrames == step { tailChunks.append(tailEnergy/Double(step)); tailFrames = 0; tailEnergy = 0 }
            }
            let levels = gated(windows(30,tailChunks), relative: -20).map(loudness).sorted()
            if !levels.isEmpty {
                let low = Int((Double(levels.count-1)*0.1).rounded()), high = Int((Double(levels.count-1)*0.95).rounded())
                result.range = levels[high]-levels[low]
            }
        }
        return result
    }
}
