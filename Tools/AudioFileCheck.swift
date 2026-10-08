import Foundation
@main struct AudioFileCheck {
    static func main() throws {
        let s = try WaveformReader.read(URL(fileURLWithPath:CommandLine.arguments[1]))
        let m = s.loudness!
        let values: [String: Any] = ["integrated":m.integrated as Any? ?? NSNull(),"range":m.range as Any? ?? NSNull(),"truePeak":m.truePeak as Any? ?? NSNull(),"momentaryMax":m.momentaryMax as Any? ?? NSNull(),"shortTermMax":m.shortTermMax as Any? ?? NSNull(),"invalidSamples":m.invalidSamples,"fullScaleSamples":m.fullScaleSamples,"layoutSupported":m.layoutSupported,"channels":s.channels,"sampleRate":s.sampleRate,"bitDepth":s.sourceBitDepth as Any? ?? NSNull()]
        print(String(decoding:try JSONSerialization.data(withJSONObject:values,options:.sortedKeys),as:UTF8.self))
    }
}
