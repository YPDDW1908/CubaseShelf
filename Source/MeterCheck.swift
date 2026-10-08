// Standalone validation tool: interleaved little-endian Float32 PCM in, JSON out.
// Compile with TruePeak.swift and Loudness.swift; the app does not include this entry point.
import Foundation
@main struct MeterCheck {
    static func main() throws {
        let args = CommandLine.arguments
        guard (args.count == 4 || args.count == 5), let rate = Double(args[2]), let count = Int(args[3]), rate > 0, count > 0, count <= 64 else { fatalError("usage: MeterCheck file.f32le sampleRate channels") }
        let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: args[1])); defer { try? file.close() }
        let pointers = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: count)
        for channel in 0..<count { pointers[channel] = .allocate(capacity: 16384) }
        defer { for channel in 0..<count { pointers[channel].deallocate() }; pointers.deallocate() }
        let weights: [Double]? = args.count == 5 && args[4] == "5.1" && count == 6 ? [1,1,1,0,1.41,1.41] : nil
        let meter = LoudnessMeter(rate: rate, channels: count, weights:weights)
        while let data = try file.read(upToCount: 16384*count*4), !data.isEmpty {
            guard data.count % (count*4) == 0 else { fatalError("Truncated PCM frame") }
            let frames = data.count / (count*4)
            data.withUnsafeBytes { bytes in
                for i in 0..<frames { for c in 0..<count {
                    let bits = UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: (i*count+c)*4, as: UInt32.self))
                    pointers[c][i] = Float(bitPattern: bits)
                } }
            }
            meter.consume(pointers,count: frames)
        }
        let m = meter.finish()
        let values: [String: Any] = ["integrated": m.integrated as Any? ?? NSNull(), "range": m.range as Any? ?? NSNull(), "truePeak": m.truePeak as Any? ?? NSNull(), "samplePeak": m.samplePeak as Any? ?? NSNull()]
        let data = try JSONSerialization.data(withJSONObject: values,options:[.sortedKeys])
        print(String(decoding:data,as:UTF8.self))
    }
}
