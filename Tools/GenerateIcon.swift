// Deterministic macOS icon packaging: preserve the supplied logo, add only
// a rounded white backing and transparent outer margin. No logo redrawing.
import AppKit
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count == 3, let source = NSImage(contentsOfFile: args[1]) else {
    fatalError("Usage: GenerateIcon BrandLogo.png LifelineIcon.icns")
}
let entries: [(String, Int)] = [("icp4",16),("icp5",32),("icp6",64),("ic07",128),("ic08",256),("ic09",512),("ic10",1024),("ic11",32),("ic12",64),("ic13",256),("ic14",512)]
func bigEndian(_ value: Int) -> Data {
    var n = UInt32(value).bigEndian
    return withUnsafeBytes(of:&n) { Data($0) }
}
var chunks = Data()
for (type, pixels) in entries {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:pixels,pixelsHigh:pixels,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep:bitmap)!
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    let scale = CGFloat(pixels) / 1024
    let rect = NSRect(x:100*scale,y:100*scale,width:824*scale,height:824*scale)
    NSBezierPath(roundedRect:rect,xRadius:185*scale,yRadius:185*scale).addClip()
    NSColor.white.setFill(); rect.fill()
    source.draw(in:rect,from:.zero,operation:.sourceOver,fraction:1)
    NSGraphicsContext.restoreGraphicsState()
    let png = bitmap.representation(using:.png,properties:[:])!
    chunks.append(type.data(using:.ascii)!); chunks.append(bigEndian(png.count+8)); chunks.append(png)
}
var file = Data("icns".utf8); file.append(bigEndian(chunks.count+8)); file.append(chunks)
try file.write(to:URL(fileURLWithPath:args[2]))
