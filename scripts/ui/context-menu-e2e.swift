import AppKit
_ = NSApplication.shared
let pid = Int(CommandLine.arguments[1])!
func wins() -> [[String: Any]] { (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]).filter { ($0[kCGWindowOwnerPID as String] as? Int) == pid } }
func rect(_ w: [String: Any]) -> CGRect { let b = w[kCGWindowBounds as String] as! [String: CGFloat]; return CGRect(x: b["X"]!, y: b["Y"]!, width: b["Width"]!, height: b["Height"]!) }
guard let o = wins().first(where: { ($0[kCGWindowLayer as String] as? Int) == 3 }) else { print("no overlay"); exit(1) }
let r = rect(o), p = CGPoint(x: r.midX, y: r.midY)
let orig = NSEvent.mouseLocation, mainH = NSScreen.screens[0].frame.height
CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .right)!.post(tap: .cghidEventTap); usleep(150_000)
CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown, mouseCursorPosition: p, mouseButton: .right)!.post(tap: .cghidEventTap); usleep(60_000)
CGEvent(mouseEventSource: nil, mouseType: .rightMouseUp, mouseCursorPosition: p, mouseButton: .right)!.post(tap: .cghidEventTap); usleep(600_000)
if let m = wins().first(where: { ($0[kCGWindowLayer as String] as? Int ?? 0) > 20 }) {
    let mr = rect(m); print("menu window:", Int(mr.width), "x", Int(mr.height), "id", m[kCGWindowNumber as String]!)
    let t = Process(); t.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture"); t.arguments = ["-x", "-o", "-l\(m[kCGWindowNumber as String]!)", CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "/tmp/nowplaying-menu.png"]; try! t.run(); t.waitUntilExit()
} else { print("no menu window") }
let esc = CGEvent(keyboardEventSource: nil, virtualKey: 0x35, keyDown: true)!; esc.post(tap: .cghidEventTap)
CGEvent(keyboardEventSource: nil, virtualKey: 0x35, keyDown: false)!.post(tap: .cghidEventTap)
CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: orig.x, y: mainH - orig.y), mouseButton: .left)!.post(tap: .cghidEventTap)
