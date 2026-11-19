// Ink bounds: where the drawn pixels are inside each control, from a capture and its chrome dump,
// so icons (not just their buttons) are compared. Run by capture.sh:
//
//   swift ink.swift <capture.png> <dump.json>   (adds "ink": {x, top, width, height} to each control)
//
// A pixel is ink when it differs from the control's own background (the most common colour in
// its box) by more than 40 in any channel. The PNG is 2x; the dump is in points.
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let image = NSImage(contentsOfFile: args[1]),
      let rep = image.representations.first as? NSBitmapImageRep ?? NSBitmapImageRep(data: image.tiffRepresentation!),
      let data = FileManager.default.contents(atPath: args[2]),
      var dump = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      var controls = dump["controls"] as? [[String: Any]] else {
    FileHandle.standardError.write(Data("usage: swift ink.swift <capture.png> <dump.json>\n".utf8)); exit(2)
}
let scale = CGFloat(rep.pixelsWide) / CGFloat((dump["width"] as? Double) ?? 1280)
func px(_ x: Int, _ y: Int) -> [Int] {
    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return [0, 0, 0] }
    return [Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255)]
}
for i in controls.indices {
    let c = controls[i]
    guard ["split", "palette", "inspector", "title"].contains(c["id"] as? String ?? ""),
          let x = c["x"] as? Double, let top = c["top"] as? Double, let w = c["width"] as? Double, let h = c["height"] as? Double else { continue }
    let x0 = Int(CGFloat(x) * scale), y0 = Int(CGFloat(top) * scale), x1 = Int(CGFloat(x + w) * scale), y1 = Int(CGFloat(top + h) * scale)
    var counts: [[Int]: Int] = [:]
    for yy in y0..<y1 { for xx in x0..<x1 { counts[px(xx, yy), default: 0] += 1 } }
    guard let bg = counts.max(by: { $0.value < $1.value })?.key else { continue }
    var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
    for yy in y0..<y1 { for xx in x0..<x1 {
        let p = px(xx, yy)
        if zip(p, bg).contains(where: { abs($0 - $1) > 40 }) { minX = min(minX, xx); maxX = max(maxX, xx); minY = min(minY, yy); maxY = max(maxY, yy) }
    } }
    guard maxX >= 0 else { continue }
    let r1 = { (v: CGFloat) in (v * 10).rounded() / 10 }
    controls[i]["ink"] = ["x": r1(CGFloat(minX) / scale - CGFloat(x)), "top": r1(CGFloat(minY) / scale - CGFloat(top)),
                          "width": r1(CGFloat(maxX - minX + 1) / scale), "height": r1(CGFloat(maxY - minY + 1) / scale)]
}
dump["controls"] = controls
let out = try! JSONSerialization.data(withJSONObject: dump, options: [.prettyPrinted, .sortedKeys])
try! out.write(to: URL(fileURLWithPath: args[2]))
