import AppKit
import CoreGraphics
_ = NSApplication.shared
let pid = Int(CommandLine.arguments[1])!
func win() -> CGRect? {
    let l = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
    for w in l where (w[kCGWindowOwnerPID as String] as? Int) == pid && (w[kCGWindowLayer as String] as? Int) == 3 {
        let b = w[kCGWindowBounds as String] as! [String: CGFloat]
        return CGRect(x: b["X"]!, y: b["Y"]!, width: b["Width"]!, height: b["Height"]!)
    }
    return nil
}
func post(_ t: CGEventType, _ p: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: p, mouseButton: .left)!.post(tap: .cghidEventTap)
}
let positions: [(String, NSCursor.FrameResizePosition)] = [("top", .top), ("bottom", .bottom), ("left", .left), ("right", .right),
    ("topLeft", .topLeft), ("topRight", .topRight), ("bottomLeft", .bottomLeft), ("bottomRight", .bottomRight)]
let sigs = positions.map { ($0.0, NSCursor.frameResize(position: $0.1, directions: .all).image.tiffRepresentation) }
let arrowSig = NSCursor.arrow.image.tiffRepresentation
func cursorName() -> String {
    guard let cur = NSCursor.currentSystem?.image.tiffRepresentation else { return "?" }
    if cur == arrowSig { return "arrow" }
    return sigs.first { $0.1 == cur }?.0 ?? "other"
}
/// top/bottom, left/right and the two diagonals share one image each.
func cursorClass(_ n: String) -> String {
    switch n { case "top", "bottom": return "↕"; case "left", "right": return "↔"
    case "topLeft", "bottomRight": return "⤡"; case "topRight", "bottomLeft": return "⤢"; default: return n }
}
// Screen space around the window (CG coords, y down) so drags never push against a screen edge.
func room(_ r: CGRect) -> (l: CGFloat, r: CGFloat, t: CGFloat, b: CGFloat) {
    let s = NSScreen.screens.map { sc -> CGRect in let f = sc.frame; return CGRect(x: f.minX, y: mainH - f.maxY, width: f.width, height: f.height) }
        .first { $0.contains(CGPoint(x: r.midX, y: r.midY)) } ?? .zero
    return (r.minX - s.minX, s.maxX - r.maxX, r.minY - s.minY - 40, s.maxY - r.maxY) // 40 ≈ menu bar
}
let original = NSEvent.mouseLocation
let mainH = NSScreen.screens[0].frame.height
guard let start = win() else { print("no overlay window"); exit(1) }
print("start frame", start)
let inset: CGFloat = 4, d: CGFloat = 30
// (name, point on the edge, outward drag vector in CG coords (y down))
func cases(_ r: CGRect) -> [(String, CGPoint, CGVector)] {[
    ("top", CGPoint(x: r.midX, y: r.minY + inset), CGVector(dx: 0, dy: -d)),
    ("bottom", CGPoint(x: r.midX, y: r.maxY - inset), CGVector(dx: 0, dy: d)),
    ("left", CGPoint(x: r.minX + inset, y: r.midY), CGVector(dx: -d, dy: 0)),
    ("right", CGPoint(x: r.maxX - inset, y: r.midY), CGVector(dx: d, dy: 0)),
    ("topLeft", CGPoint(x: r.minX + inset, y: r.minY + inset), CGVector(dx: -d, dy: -d)),
    ("topRight", CGPoint(x: r.maxX - inset, y: r.minY + inset), CGVector(dx: d, dy: -d)),
    ("bottomLeft", CGPoint(x: r.minX + inset, y: r.maxY - inset), CGVector(dx: -d, dy: d)),
    ("bottomRight", CGPoint(x: r.maxX - inset, y: r.maxY - inset), CGVector(dx: d, dy: d)),
]}
func drag(_ p: CGPoint, _ v: CGVector) {
    post(.leftMouseDown, p); usleep(60_000)
    for i in 1...6 { post(.leftMouseDragged, CGPoint(x: p.x + v.dx * CGFloat(i) / 6, y: p.y + v.dy * CGFloat(i) / 6)); usleep(25_000) }
    post(.leftMouseUp, CGPoint(x: p.x + v.dx, y: p.y + v.dy)); usleep(450_000)
}
var failures = 0
for (name, _, _) in cases(start) {
    guard let r = win(), let c = cases(r).first(where: { $0.0 == name }) else { continue }
    post(.mouseMoved, CGPoint(x: c.1.x + 30 * (c.1.x < r.midX ? 1 : -1), y: r.midY)); usleep(120_000) // approach from inside
    post(.mouseMoved, c.1); usleep(250_000)
    let cur = cursorName()
    // Grow when there is room on that side, otherwise shrink.
    let rm = room(r)
    var v = c.2
    if v.dx < 0 && rm.l < d + 4 || v.dx > 0 && rm.r < d + 4 { v.dx = -v.dx }
    if v.dy < 0 && rm.t < d + 4 || v.dy > 0 && rm.b < d + 4 { v.dy = -v.dy }
    drag(c.1, v)
    guard let r2 = win() else { continue }
    // Expected: dragged edges move outward by d, the opposite edges stay.
    let dl = r2.minX - r.minX, dr = r2.maxX - r.maxX, dt = r2.minY - r.minY, db = r2.maxY - r.maxY
    let wantL: CGFloat = name.lowercased().contains("left") ? v.dx : 0
    let wantR: CGFloat = name.lowercased().contains("right") ? v.dx : 0
    let wantT: CGFloat = name.hasPrefix("top") ? v.dy : 0
    let wantB: CGFloat = name.hasPrefix("bottom") ? v.dy : 0
    // A shrink may stop at the layout's minimum size; the opposite edges must never move.
    let minStop = { (got: CGFloat, want: CGFloat) in abs(got - want) <= 2 || (want != 0 && got.sign == want.sign && abs(got) < abs(want)) || (want != 0 && got == 0) }
    let ok = minStop(dl, wantL) && minStop(dr, wantR) && minStop(dt, wantT) && minStop(db, wantB)
        && (wantL != 0 || dl == 0) && (wantR != 0 || dr == 0) && (wantT != 0 || dt == 0) && (wantB != 0 || db == 0)
    let cursorOK = cursorClass(cur) == cursorClass(name)
    if !ok || !cursorOK { failures += 1 }
    func pad(_ s: String) -> String { s.padding(toLength: 11, withPad: " ", startingAt: 0) }
    print("\(pad(name)) cursor=\(cursorClass(cur))\(cursorOK ? " ok" : " WRONG") moved L\(Int(dl)) R\(Int(dr)) T\(Int(dt)) B\(Int(db))  " + (ok ? "OK" : "WRONG (want L\(Int(wantL)) R\(Int(wantR)) T\(Int(wantT)) B\(Int(wantB)))"))
    // Drag back to where we started.
    let back = cases(r2).first { $0.0 == name }!
    drag(back.1, CGVector(dx: -v.dx, dy: -v.dy))
}
// Middle of the window must still move it (not resize).
if let r = win() {
    let p = CGPoint(x: r.midX, y: r.midY)
    post(.mouseMoved, p); usleep(200_000)
    let cur = cursorName()
    drag(p, CGVector(dx: -40, dy: -40)); usleep(300_000)
    if let r2 = win() { print("middle      cursor=\(cur) moved dx\(Int(r2.minX - r.minX)) dy\(Int(r2.minY - r.minY)) size \(Int(r2.width - r.width))x\(Int(r2.height - r.height))") }
    if let r3 = win() { drag(CGPoint(x: r3.midX, y: r3.midY), CGVector(dx: 40, dy: 40)) }
}
print("end frame", win() ?? .zero, "failures:", failures)
post(.mouseMoved, CGPoint(x: original.x, y: mainH - original.y))
