import AppKit
_ = NSApplication.shared
let pid = Int(CommandLine.arguments[1])!
func win() -> CGRect? {
    let l = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
    for w in l where (w[kCGWindowOwnerPID as String] as? Int) == pid && (w[kCGWindowLayer as String] as? Int) == 3 {
        let b = w[kCGWindowBounds as String] as! [String: CGFloat]; return CGRect(x: b["X"]!, y: b["Y"]!, width: b["Width"]!, height: b["Height"]!)
    }
    return nil
}
func post(_ t: CGEventType, _ p: CGPoint) { CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: p, mouseButton: .left)!.post(tap: .cghidEventTap) }
let original = NSEvent.mouseLocation, mainH = NSScreen.screens[0].frame.height
guard let r = win() else { print("no window"); exit(1) }
let p = CGPoint(x: r.midX, y: r.midY + 20)
post(.mouseMoved, p); usleep(200_000)
post(.leftMouseDown, p); usleep(60_000)
for i in 1...10 { post(.leftMouseDragged, CGPoint(x: p.x, y: p.y + CGFloat(i) * 80)); usleep(25_000) }
post(.leftMouseUp, CGPoint(x: p.x, y: p.y + 800)); usleep(600_000)
let r2 = win()!
// Screen containing the window (CG coords)
let s = NSScreen.screens.map { sc -> (CGRect, CGRect) in
    let f = sc.frame, v = sc.visibleFrame
    return (CGRect(x: f.minX, y: mainH - f.maxY, width: f.width, height: f.height), CGRect(x: v.minX, y: mainH - v.maxY, width: v.width, height: v.height)) }
    .first { $0.0.contains(CGPoint(x: r.midX, y: r.midY)) }! // the display it started on
if !s.0.contains(CGPoint(x: r2.midX, y: r2.midY)) { print("JUMPED to another display ✗", r2) }
print("window bottom:", r2.maxY, " screen bottom:", s.0.maxY, " dock top (visible bottom):", s.1.maxY)
print(r2.maxY > s.1.maxY ? "OVER THE DOCK ✓ (\(Int(s.0.maxY - r2.maxY))pt above screen edge)" : "stopped above the Dock ✗")
// put it back
post(.leftMouseDown, CGPoint(x: r2.midX, y: r2.midY)); usleep(60_000)
for i in 1...10 { post(.leftMouseDragged, CGPoint(x: r2.midX + (r.midX - r2.midX) * CGFloat(i) / 10, y: r2.midY + (r.midY - r2.midY) * CGFloat(i) / 10)); usleep(25_000) }
post(.leftMouseUp, CGPoint(x: r.midX, y: r.midY)); usleep(500_000)
print("restored:", win()!, "orig:", r)
post(.mouseMoved, CGPoint(x: original.x, y: mainH - original.y))
