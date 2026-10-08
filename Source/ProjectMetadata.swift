import Foundation

struct SignatureEvent: Codable, Equatable {
    var numerator: Int
    var denominator: Int
    var bar: Int
    var text: String { "\(numerator)/\(denominator)" }
}

struct ProjectMetadata: Codable, Equatable {
    static let currentRevision = 2
    var parserRevision: Int? = currentRevision
    var sampleRate: Double?
    var bitDepth: Int?
    var signatures: [SignatureEvent]?

    var applicationVersion: String?
    var tempos: [Double] = []
    var tempoSource: String?
    var channelNames: [String] = []
    var pluginNames: [String] = []
    var message: String?
    var audioFormatText: String {
        (sampleRate.map { String(format:"%.1f kHz",$0/1000) } ?? "采样率未识别") + " · " + (bitDepth.map { "\($0) bit" } ?? "位深未识别")
    }
    var initialSignatureText: String {
        guard let first = signatures?.first, first.bar == 0 else { return "未识别" }
        return first.text
    }
    var signatureEventsText: String { (signatures ?? []).map { "第 \($0.bar+1) 小节 \($0.text)" }.joined(separator:" → ") }
    var bpmText: String { tempos.first.map { String(format: "%.2f", $0) } ?? "未识别" }
}

// Read-only, bounded recognition of observed CPR fields. This is not a full
// proprietary-format decoder. Never scan arbitrary doubles or default to 120.
enum CPRMetadataReader {
    static func read(_ url: URL) -> ProjectMetadata {
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 128 * 1024 * 1024 else { return ProjectMetadata(message: "工程超过 128 MB，跳过信息解析。") }
            return parse(try Data(contentsOf: url, options: .mappedIfSafe))
        } catch { return ProjectMetadata(message: "工程不可访问，无法读取信息。") }
    }
    static func parse(_ data: Data) -> ProjectMetadata {
        guard data.starts(with: Data("RIF2".utf8)) else { return ProjectMetadata(message: "尚不支持此 CPR 结构。") }
        func positions(_ bytes: Data) -> [Int] {
            var result: [Int] = [], start = 0
            while start < data.count, let range = data.range(of: bytes, in: start..<data.count) {
                result.append(range.lowerBound); start = range.upperBound
            }
            return result
        }
        func number(_ start: Int, _ count: Int) -> UInt64? {
            guard start >= 0, count <= 8, start <= data.count-count else { return nil }
            return data[start..<start+count].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        }
        func fieldString(_ offset: Int, key: String) -> (String, Int)? {
            let prefix = Data((key + "\0").utf8), start = offset + prefix.count
            guard number(start,2) == 8, let size = number(start+2,4), size > 0, size <= 4096,
                  start+6+Int(size) <= data.count else { return nil }
            let bytes = data[start+6..<start+6+Int(size)].prefix { $0 != 0 }
            guard let value = String(data: bytes, encoding: .utf8), !value.isEmpty,
                  !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
            return (value, start+6+Int(size))
        }
        // Require exact named-field boundaries and types; never interpret a nearby
        // number or a plugin XML attribute as project settings.
        func scalar(_ cursor: inout Int, key: String, type: UInt64, limit: Int) -> UInt64? {
            let name = Data((key + "\0").utf8)
            guard cursor >= 0, cursor + 4 + name.count + 10 <= limit,
                  number(cursor,4) == UInt64(name.count),
                  data[cursor+4..<cursor+4+name.count] == name,
                  number(cursor+4+name.count,2) == type,
                  let value = number(cursor+6+name.count,8) else { return nil }
            cursor += 14 + name.count
            return value
        }
        var result = ProjectMetadata()
        var rates = Set<Double>(), depths = Set<Int>()
        for offset in positions(Data("ID\0\0\u{8}".utf8)) {
            guard let (name, end) = fieldString(offset,key: "ID"),
                  name == "AudioSampleRate" || name == "AudioSampleSize" else { continue }
            // The enclosing media-attribute marker distinguishes this from preset text.
            guard data.range(of: Data("StMedia::PStringIDMediaAttribute\0".utf8), in: max(0,offset-96)..<offset) != nil else { continue }
            var cursor = end
            guard let kind = scalar(&cursor,key:"Type",type:1,limit:data.count),
                  scalar(&cursor,key:"Flags",type:1,limit:data.count) != nil else { continue }
            if name == "AudioSampleRate", kind == 4, let bits = scalar(&cursor,key:"Float",type:4,limit:data.count) {
                let rate = Double(bitPattern:bits)
                if rate.isFinite, (8000...384000).contains(rate) { rates.insert(rate) }
            }
            if name == "AudioSampleSize", kind == 1, let bits = scalar(&cursor,key:"Long",type:1,limit:data.count), [8,16,24,32,64].contains(bits) { depths.insert(Int(bits)) }
        }
        if rates.count == 1 { result.sampleRate = rates.first }
        if depths.count == 1 { result.bitDepth = depths.first }
        var signatures: [SignatureEvent] = []
        let signatureMarker = Data("MSignatureTrackEvent\0".utf8)
        for offset in positions(signatureMarker) {
            let header = offset + signatureMarker.count
            guard number(header,2) == 3, let length = number(header+2,8),
                  length <= UInt64(max(0,data.count-header-10)) else { continue }
            let limit = header + 10 + Int(length)
            let eventMarker = Data("MTimeSignatureEvent\0".utf8)
            var seek = header + 10
            while seek < limit, let range = data.range(of:eventMarker,in:seek..<limit) {
                seek = range.upperBound
                let first = Data([0,0,0,6]) + Data("Flags\0".utf8)
                guard let field = data.range(of:first,in:seek..<min(limit,seek+32)) else { continue }
                var cursor = field.lowerBound
                guard scalar(&cursor,key:"Flags",type:1,limit:limit) != nil,
                      let position = scalar(&cursor,key:"Start",type:4,limit:limit),
                      scalar(&cursor,key:"Length",type:4,limit:limit) != nil,
                      let bar = scalar(&cursor,key:"Bar",type:1,limit:limit), bar < 1_000_000,
                      let n = scalar(&cursor,key:"Numerator",type:1,limit:limit), (1...64).contains(n),
                      let d = scalar(&cursor,key:"Denominator",type:1,limit:limit), [1,2,4,8,16,32,64].contains(d),
                      Double(bitPattern:position).isFinite, Double(bitPattern:position) >= 0 else { continue }
                signatures.append(SignatureEvent(numerator:Int(n),denominator:Int(d),bar:Int(bar)))
                seek = cursor
            }
        }
        let byBar = Dictionary(grouping:signatures,by: \.bar)
        // Conflicting saved variations cannot safely establish a single signature map.
        if !signatures.isEmpty, byBar.values.allSatisfy({ Set($0.map(\.text)).count == 1 }) {
            result.signatures = byBar.keys.sorted().compactMap { byBar[$0]?.first }
        }

        let header = String(decoding: data.prefix(2048), as: UTF8.self)
        if let range = header.range(of: #"Version [0-9]+\.[0-9]+\.[0-9]+"#, options: .regularExpression) {
            result.applicationVersion = String(header[range]).replacingOccurrences(of: "Version ", with: "")
        }
        let marker = Data("MTempoTrackEvent\0".utf8)
        for offset in positions(marker).prefix(1) {
            let start = offset + marker.count
            // Observed Cubase 15 event layout: flags, 64-bit block length,
            // count, then 22-byte records (seconds/beat Float32, two Doubles, flags).
            if number(start,2) == 3, let length = number(start+2,8), let count = number(start+10,4),
               count > 0, count <= 10000, length <= UInt64(data.count-start-10), length >= 4+count*22,
               start+14+Int(count)*22+4 <= data.count {
                var values: [Double] = []
                for index in 0..<Int(count) {
                    let record = start+14+index*22
                    let seconds = Double(Float(bitPattern: UInt32(number(record,4) ?? 0)))
                    let position = Double(bitPattern: number(record+4,8) ?? 0)
                    let auxiliary = Double(bitPattern: number(record+12,8) ?? 0)
                    guard seconds.isFinite, seconds >= 0.06, seconds <= 6,
                          position.isFinite, auxiliary.isFinite, position >= 0, auxiliary >= 0, (index != 0 || position == 0) else { values = []; break }
                    values.append(60/seconds)
                }
                if !values.isEmpty { result.tempos = values; result.tempoSource = "速度轨事件（实验性读取）" }
            }
        }
        if result.tempos.isEmpty {
            let key = Data("BPM\0\0\u{4}".utf8)
            for offset in positions(Data("MTempoEvent\0".utf8)) {
                if let field = data.range(of: key, in: offset..<min(data.count,offset+512)),
                   let bits = number(field.upperBound,8) {
                    let bpm = Double(bitPattern: bits)
                    if bpm.isFinite && (10...1000).contains(bpm) { result.tempos.append(bpm) }
                }
            }
            if !result.tempos.isEmpty { result.tempoSource = "BPM 命名字段（实验性读取）" }
        }
        let channelPrefix = Data("Name\0\0\u{2}\0\u{6}\0\0\0\u{1}\0\0\0\u{7}String\0\0\u{8}".utf8)
        var names: [String] = []
        for offset in positions(channelPrefix) {
            let field = offset + channelPrefix.count - Data("String\0\0\u{8}".utf8).count
            if let (name,end) = fieldString(field,key: "String"),
               data.range(of: Data("InputFilter\0".utf8), in: end..<min(data.count,end+80)) != nil { names.append(name) }
        }
        result.channelNames = Array(Set(names)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let builtins: Set<String> = ["Input Filter","EQ","Standard Panner","Stereo Combined Panner","Mono Panner","Surround Panner"]
        result.pluginNames = Array(Set(positions(Data("Plugin Name\0".utf8)).compactMap { fieldString($0,key: "Plugin Name")?.0 }.filter { !builtins.contains($0) && !result.channelNames.contains($0) })).sorted()
        result.message = (rates.count > 1 || depths.count > 1 ? "存在冲突的音频属性，未选取任意值。" : "") + "CPR 实验性读取：通道名去重且可能包含输入／输出；插件为文件内引用，不代表当前启用状态。未识别字段不会猜测。"
        return result
    }
}
