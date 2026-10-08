import Foundation
import Accelerate

// Eight-phase, 32-tap-per-phase Kaiser-windowed sinc interpolator. vDSP performs
// block convolution, preserving history across decoder chunks and flushing EOF.
final class TruePeakMeter {
    private var finished = false
    private let channels: Int
    private var history: [[Double]]
    private(set) var peak = 0.0
    private static func bessel0(_ x: Double) -> Double {
        var sum = 1.0, term = 1.0
        for k in 1...30 { term *= x*x/(4*Double(k*k)); sum += term }
        return sum
    }
    private static let filters: [[Double]] = (0..<8).map { phase in
        let fraction = Double(phase)/8
        var coefficients = (0..<32).map { tap -> Double in
            let t = Double(tap)-15+fraction
            let sinc = abs(t) < 1e-12 ? 1 : sin(.pi*t)/(.pi*t)
            let window = bessel0(8 * sqrt(max(0,1-(t/16)*(t/16)))) / bessel0(8)
            return sinc*window
        }
        let sum = coefficients.reduce(0,+)
        coefficients = coefficients.map { $0/sum }
        return Array(coefficients.reversed())
    }
    init(channels: Int) { self.channels = channels; history = Array(repeating:Array(repeating:0,count:31),count:channels) }
    private func process(_ values: [Double], channel: Int) {
        let input = history[channel] + values
        var output = [Double](repeating:0,count:values.count)
        input.withUnsafeBufferPointer { source in
            for filter in Self.filters {
                filter.withUnsafeBufferPointer { coefficients in
                    vDSP_convD(source.baseAddress!,1,coefficients.baseAddress!,1,&output,1,vDSP_Length(values.count),32)
                }
                var maximum = 0.0
                vDSP_maxmgvD(output,1,&maximum,vDSP_Length(values.count))
                peak = max(peak,maximum)
            }
        }
        history[channel] = Array(input.suffix(31))
    }
    func consume(_ pointers: UnsafePointer<UnsafeMutablePointer<Float>>, count: Int) {
        guard count > 0, !finished else { return }
        for c in 0..<channels { process((0..<count).map { pointers[c][$0].isFinite ? Double(pointers[c][$0]) : 0 },channel:c) }
    }
    func finish() -> Double {
        guard !finished else { return peak }; finished = true
        for c in 0..<channels { process(Array(repeating:0,count:32),channel:c) }
        return peak
    }
}
