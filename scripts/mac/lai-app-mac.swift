// Điều khiển chuột, phím THẬT trên máy Mac để thử bản cài như người dùng. Trước mỗi cú bấm, kéo, gõ đều kiểm cửa sổ nhận
// đúng là của tiến trình được chỉ định; sai thì dừng (mã 2), không bấm nhầm sang app khác. Cần quyền Trợ năng sẵn có.
// Biên dịch: swiftc scripts/thu-sua-tay/lai-app-mac.swift -o <chỗ tạm>/lai
//   lai win <pid>                          liệt kê cửa sổ: mã, x y rộng cao, tên
//   lai find <pid> <chữ>                   tìm phần tử (cây trợ năng): vai, x y tâm, rộng cao, chữ
//   lai click|right|ctrl|shift <pid> <x> <y>
//   lai drag <pidNguon> <x1> <y1> <pidDich> <x2> <y2>
//   lai key <pid> <mã phím> [cmd,shift]
//   lai text <pid> <chữ>
//   lai set <pid> <chữ>                    điền thẳng vào ô đang được chọn
//   lai at <pid> <x> <y>                   phần tử tại điểm và các khung bao ngoài (x y rộng cao)
import AppKit
import ApplicationServices

let a = Array(CommandLine.arguments.dropFirst())
func die(_ m: String) -> Never { FileHandle.standardError.write((m + "\n").data(using: .utf8)!); exit(2) }
func num(_ i: Int) -> Double { guard i < a.count, let v = Double(a[i]) else { die("thiếu số ở tham số \(i)") }; return v }
func pidArg(_ i: Int) -> pid_t { pid_t(num(i)) }
func wait(_ ms: Int) { usleep(useconds_t(ms * 1000)) }

func windows() -> [[String: Any]] {
    CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
}
func bounds(_ w: [String: Any]) -> CGRect { CGRect(dictionaryRepresentation: w[kCGWindowBounds as String] as! CFDictionary) ?? .zero }
func ownerPid(_ w: [String: Any]) -> pid_t { pid_t(w[kCGWindowOwnerPID as String] as? Int ?? -1) }
// cửa sổ thường (lớp 0) nằm trên cùng tại điểm đó
func guardPoint(_ pid: pid_t, _ p: CGPoint) {
    let top = windows().first { ($0[kCGWindowLayer as String] as? Int) == 0 && ($0[kCGWindowAlpha as String] as? Double ?? 1) > 0.05 && bounds($0).contains(p) }
    guard let w = top, ownerPid(w) == pid else {
        die("dừng: tại (\(Int(p.x)), \(Int(p.y))) đang là \(top?[kCGWindowOwnerName as String] as? String ?? "không có cửa sổ"), không phải tiến trình \(pid)")
    }
}
func guardFront(_ pid: pid_t) {
    let f = NSWorkspace.shared.frontmostApplication
    if f?.processIdentifier != pid { die("dừng: app đang ở trên cùng là \(f?.localizedName ?? "?"), không phải tiến trình \(pid)") }
}

let src = CGEventSource(stateID: .hidSystemState)
func mouse(_ t: CGEventType, _ p: CGPoint, _ b: CGMouseButton = .left, _ flags: CGEventFlags = []) {
    let e = CGEvent(mouseEventSource: src, mouseType: t, mouseCursorPosition: p, mouseButton: b)!
    e.flags = flags
    if t != .mouseMoved { e.setIntegerValueField(.mouseEventClickState, value: 1) }
    e.post(tap: .cghidEventTap)
}
func click(_ pid: pid_t, _ p: CGPoint, right: Bool = false, ctrl: Bool = false, shift: Bool = false) {
    guardPoint(pid, p); mouse(.mouseMoved, p); wait(150); guardPoint(pid, p)
    let flags: CGEventFlags = ctrl ? .maskControl : shift ? .maskShift : []
    mouse(right ? .rightMouseDown : .leftMouseDown, p, right ? .right : .left, flags); wait(60)
    mouse(right ? .rightMouseUp : .leftMouseUp, p, right ? .right : .left, flags); wait(150)
}

func axValue(_ e: AXUIElement, _ k: String) -> AnyObject? { var v: AnyObject?; return AXUIElementCopyAttributeValue(e, k as CFString, &v) == .success ? v : nil }
func axFrame(_ e: AXUIElement) -> CGRect? {
    guard let p = axValue(e, kAXPositionAttribute), let s = axValue(e, kAXSizeAttribute) else { return nil }
    var pt = CGPoint.zero, sz = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &pt); AXValueGetValue(s as! AXValue, .cgSize, &sz)
    return CGRect(origin: pt, size: sz)
}

guard let cmd = a.first else { die("thiếu lệnh") }
switch cmd {
case "win":
    for w in windows() where ownerPid(w) == pidArg(1) {
        let r = bounds(w)
        print(w[kCGWindowNumber as String] as? Int ?? 0, Int(r.minX), Int(r.minY), Int(r.width), Int(r.height), w[kCGWindowName as String] as? String ?? "")
    }
case "find":
    guard a.count > 2 else { die("thiếu chữ cần tìm") }
    let want = a[2].precomposedStringWithCanonicalMapping.lowercased()
    var queue = [AXUIElementCreateApplication(pidArg(1))], seen = 0
    while !queue.isEmpty && seen < 30000 {
        let e = queue.removeFirst(); seen += 1
        let texts = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, "AXFilename"].compactMap { axValue(e, $0) as? String }.filter { !$0.isEmpty }
        if let t = texts.first(where: { $0.precomposedStringWithCanonicalMapping.lowercased().contains(want) }), let r = axFrame(e), r.width > 0 {
            print(axValue(e, kAXRoleAttribute) as? String ?? "?", Int(r.midX), Int(r.midY), Int(r.width), Int(r.height), t.prefix(80))
        }
        if let kids = axValue(e, kAXChildrenAttribute) as? [AXUIElement] { queue.append(contentsOf: kids) }
    }
case "at": // phần tử tại điểm và các khung bao ngoài nó (để biết khung xem nằm đâu)
    var el: AXUIElement?
    if AXUIElementCopyElementAtPosition(AXUIElementCreateApplication(pidArg(1)), Float(num(2)), Float(num(3)), &el) != .success { die("không có phần tử ở đó") }
    while let e = el, let r = axFrame(e) {
        print(axValue(e, kAXRoleAttribute) as? String ?? "?", Int(r.minX), Int(r.minY), Int(r.width), Int(r.height))
        el = axValue(e, kAXParentAttribute).map { $0 as! AXUIElement }
    }
case "click", "right", "ctrl", "shift": // shift: gộp cửa sổ ở dải Stage Manager vào màn đang mở
    click(pidArg(1), CGPoint(x: num(2), y: num(3)), right: cmd == "right", ctrl: cmd == "ctrl", shift: cmd == "shift")
case "drag":
    let from = pidArg(1), p = CGPoint(x: num(2), y: num(3)), to = pidArg(4), q = CGPoint(x: num(5), y: num(6))
    guardPoint(from, p); guardPoint(to, q) // đích phải đang lộ ra trước khi cầm tệp lên
    mouse(.mouseMoved, p); wait(250); guardPoint(from, p)
    mouse(.leftMouseDown, p); wait(400)
    for i in 1...6 { mouse(.leftMouseDragged, CGPoint(x: p.x + CGFloat(i) * 4, y: p.y + CGFloat(i) * 2)); wait(60) }
    for i in 1...30 { let k = CGFloat(i) / 30; mouse(.leftMouseDragged, CGPoint(x: p.x + (q.x - p.x) * k, y: p.y + (q.y - p.y) * k)); wait(25) }
    mouse(.leftMouseDragged, CGPoint(x: q.x + 2, y: q.y)); wait(700)
    let top = windows().first { ($0[kCGWindowLayer as String] as? Int) == 0 && bounds($0).contains(q) }
    if top.map(ownerPid) != to { mouse(.leftMouseDragged, p); wait(200); mouse(.leftMouseUp, p); die("dừng: đích kéo không còn là cửa sổ của \(to); đã thả lại chỗ cũ") }
    mouse(.leftMouseUp, q); wait(300)
case "key":
    let pid = pidArg(1), code = CGKeyCode(num(2))
    var flags: CGEventFlags = []
    if a.count > 3 { for m in a[3].split(separator: ",") { if m == "cmd" { flags.insert(.maskCommand) }; if m == "shift" { flags.insert(.maskShift) } } }
    guardFront(pid)
    // nhấn và NHẢ phím bổ trợ như bàn phím thật: không nhả thì ⌘⇧ kẹt, chữ gõ sau thành phím tắt (kể cả phím tắt của app khác)
    func gui(_ k: CGKeyCode, _ down: Bool, _ f: CGEventFlags) { let e = CGEvent(keyboardEventSource: src, virtualKey: k, keyDown: down)!; e.flags = f; e.post(tap: .cghidEventTap); wait(60) }
    let botro: [(CGKeyCode, CGEventFlags)] = [(55, .maskCommand), (56, .maskShift)].filter { flags.contains($0.1) }
    var dang: CGEventFlags = []
    for (k, f) in botro { dang.insert(f); gui(k, true, dang) }
    gui(code, true, flags); gui(code, false, flags)
    for (k, f) in botro.reversed() { dang.remove(f); gui(k, false, dang) }
case "text":
    let pid = pidArg(1)
    guard a.count > 2 else { die("thiếu chữ cần gõ") }
    for ch in a[2] {
        guardFront(pid)
        var u = Array(String(ch).utf16)
        for down in [true, false] { let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down)!; e.flags = []; e.keyboardSetUnicodeString(stringLength: u.count, unicodeString: &u); e.post(tap: .cghidEventTap) }
        wait(45)
    }
case "set":
    // điền thẳng vào ô đang được chọn (ô đường dẫn của hộp chọn tệp): bộ gõ tiếng Việt làm sai chữ gõ giả
    let pid = pidArg(1)
    guard a.count > 2 else { die("thiếu chữ cần điền") }
    guardFront(pid)
    guard let f = axValue(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute) else { die("không có ô nào đang được chọn") }
    if AXUIElementSetAttributeValue(f as! AXUIElement, kAXValueAttribute as CFString, a[2] as CFString) != .success { die("không điền được vào ô") }
default: die("không có lệnh \(cmd)")
}
