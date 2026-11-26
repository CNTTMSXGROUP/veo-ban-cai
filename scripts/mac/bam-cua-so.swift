import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func attr(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

func labels(_ element: AXUIElement) -> [String] {
    ["AXTitle", "AXDescription", "AXValue", "AXHelp"].compactMap { attr(element, $0) as? String }
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    attr(element, "AXChildren") as? [AXUIElement] ?? []
}

func rect(_ element: AXUIElement) -> CGRect? {
    guard let pos = attr(element, "AXPosition"), CFGetTypeID(pos) == AXValueGetTypeID(),
          let size = attr(element, "AXSize"), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
    var at = CGPoint.zero
    var wh = CGSize.zero
    guard AXValueGetValue(pos as! AXValue, .cgPoint, &at),
          AXValueGetValue(size as! AXValue, .cgSize, &wh), wh.width > 0, wh.height > 0 else { return nil }
    return CGRect(origin: at, size: wh)
}

func find(_ root: AXUIElement, _ expected: String, command: String) -> AXUIElement? {
    var queue = children(root)
    var index = 0
    let prefix = expected.hasSuffix("*") ? String(expected.dropLast()) : nil
    let desktop = CGDisplayBounds(CGMainDisplayID())
    while index < queue.count && index < 4000 {
        let element = queue[index]
        index += 1
        let match = labels(element).contains { label in
            label == expected || (prefix.map { label.hasPrefix($0) } ?? false)
        }
        if match && command == "wait" { return element }
        let role = attr(element, "AXRole") as? String
        let interactive = role != "AXStaticText" && role != "AXGroup" && role != "AXImage" && role != "AXWindow"
        let looksClickable = command == "click-text" ? role == "AXStaticText" : (interactive || command == "click-file")
        if match, looksClickable,
           (attr(element, "AXEnabled") as? Bool) != false, let box = rect(element),
           desktop.contains(CGPoint(x: box.midX, y: box.midY)) { return element }
        queue.append(contentsOf: children(element))
    }
    return nil
}

func key(_ code: CGKeyCode, _ flags: CGEventFlags = []) {
    for down in [true, false] {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { fail("Thiếu sự kiện phím.") }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }
}

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 3, let pid = Int32(args[0]), let app = NSRunningApplication(processIdentifier: pid),
      ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true",
      AXIsProcessTrusted(), CGPreflightPostEventAccess() else { fail("Thiếu phiên máy thử hoặc quyền thao tác.") }
let command = args[1]
let value = args[2]
let root = AXUIElementCreateApplication(pid)

if command == "dump" {
    var queue = children(root)
    var i = 0
    while i < queue.count && i < 1500 {
        let el = queue[i]
        let info = labels(el).filter { !$0.isEmpty }
        if !info.isEmpty { print("\(attr(el, "AXRole") as? String ?? "") \(rect(el).map { String(describing: $0) } ?? "") \(info.joined(separator: " | "))") }
        queue.append(contentsOf: children(el))
        i += 1
    }
} else if command == "capture" {
    guard CGPreflightScreenCaptureAccess(),
          let items = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
          let window = items.first(where: {
              ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0
          }), let id = window[kCGWindowNumber as String] as? UInt32 else { fail("Không thấy cửa sổ chụp ảnh.") }
    let shot = Process()
    shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    shot.arguments = ["-x", "-o", "-l", String(id), value]
    try shot.run()
    shot.waitUntilExit()
    if shot.terminationStatus != 0 { fail("Không chụp được ảnh cửa sổ.") }
} else if command == "key" {
    if !app.isActive { _ = app.activate(options: []); Thread.sleep(forTimeInterval: 0.2) }
    let flags: CGEventFlags = args.count >= 4 && args[3] == "cmd" ? .maskCommand : []
    guard let code = UInt16(value) else { fail("Sai mã phím.") }
    key(code, flags)
} else {
    guard ["wait", "click", "click-text", "click-file"].contains(command) else { fail("Thao tác thử không hợp lệ.") }
    let until = Date().addingTimeInterval(args.count >= 4 ? Double(args[3]) ?? 15 : 15)
    var matched: AXUIElement?
    repeat {
        matched = find(root, value, command: command)
        if matched == nil { Thread.sleep(forTimeInterval: 0.25) }
    } while matched == nil && Date() < until
    guard let element = matched else { fail("Không thấy điều khiển \(value).") }
    if command != "wait" {
        if !app.isActive { _ = app.activate(options: []); Thread.sleep(forTimeInterval: 0.2) }
        guard let box = rect(element) else { fail("Không thấy vị trí \(value).") }
        let point = CGPoint(x: box.midX, y: box.midY)
        for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
            guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else {
                fail("Không tạo được lần bấm \(value).")
            }
            event.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.035)
        }
    }
}
