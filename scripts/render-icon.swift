// Render the actual SVG master using the subset of SVG shapes used by our icon.
// No separate hand-maintained bitmap drawing: edits to SVG colors/geometry propagate.
import AppKit
import Foundation

struct Shape { var kind: String; var attributes: [String: String] }
final class SVGReader: NSObject, XMLParserDelegate {
    var shapes: [Shape] = []
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if ["rect", "polygon"].contains(name) { shapes.append(Shape(kind: name, attributes: attributes)) }
    }
}
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let parser = XMLParser(contentsOf: root.appendingPathComponent("Design/LingoPlayer.svg"))!
let reader = SVGReader(); parser.delegate = reader
precondition(parser.parse(), "Invalid SVG")
let destination = root.appendingPathComponent("Sources/LingoPlayer/Resources/Icon")
let iconset = destination.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
func render(_ size: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: size * 4, bitsPerPixel: 32)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    context.cgContext.translateBy(x: 0, y: 1024); context.cgContext.scaleBy(x: 1, y: -1)
    for shape in reader.shapes {
        let a = shape.attributes
        let hex = a["fill"]!.dropFirst(); let value = UInt32(hex, radix: 16)!
        NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1).setFill()
        let path: NSBezierPath
        if shape.kind == "rect" {
            func n(_ key: String) -> CGFloat { CGFloat(Double(a[key] ?? "0")!) }
            path = NSBezierPath(roundedRect: NSRect(x: n("x"), y: n("y"), width: n("width"), height: n("height")), xRadius: n("rx"), yRadius: n("rx"))
        } else {
            path = NSBezierPath()
            for (index, pair) in a["points"]!.split(separator: " ").enumerated() {
                let xy = pair.split(separator: ",").map { Double($0)! }; let point = NSPoint(x: xy[0], y: xy[1])
                if index == 0 { path.move(to: point) } else { path.line(to: point) }
            }
            path.close()
        }
        path.fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}
for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
try render(256).write(to: root.appendingPathComponent("Sources/LingoPlayer/Resources/AppIcon.png"))
