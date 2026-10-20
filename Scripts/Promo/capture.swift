// Captures a process's main window with macOS's own `screencapture` (real on-screen pixels, with
// any attached sheet, transparent rounded corners, no shadow).
//
//   swift capture.swift <pid> <output.png>
import CoreGraphics
import Foundation

let args = CommandLine.arguments
guard args.count == 3, let pid = Int32(args[1]) else { print("usage: capture.swift <pid> <out.png>"); exit(2) }
let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
let main = info
    .filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
    .compactMap { w -> (id: Int, area: CGFloat)? in
        guard let id = w[kCGWindowNumber as String] as? Int, let b = w[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: b) else { return nil }
        return (id, rect.width * rect.height)
    }
    .max { $0.area < $1.area }
guard let main else { print("no window for pid \(pid)"); exit(1) }
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
p.arguments = ["-x", "-o", "-l", String(main.id), args[2]]
try p.run()
p.waitUntilExit()
print(p.terminationStatus == 0 ? "captured \(args[2])" : "screencapture failed")
exit(p.terminationStatus)
