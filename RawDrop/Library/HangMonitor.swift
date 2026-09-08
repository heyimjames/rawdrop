import Foundation

#if DEBUG
/// Prints whenever the main thread stops turning for more than 150ms.
/// Debug builds only; started from RawDropApp when `-hang-monitor` is passed.
enum HangMonitor {
    private static var last = Date()
    private static var timer: Timer?

    static func start() {
        guard ProcessInfo.processInfo.arguments.contains("-hang-monitor") else { return }
        last = Date()
        timer = Timer(timeInterval: 0.05, repeats: true) { _ in
            let now = Date()
            let gap = now.timeIntervalSince(last)
            if gap > 0.15 {
                print("[hang] main thread blocked for \(Int(gap * 1000)) ms")
            }
            last = now
        }
        RunLoop.main.add(timer!, forMode: .common)
        print("[hang] monitor running")
    }

    private static let enabled = ProcessInfo.processInfo.arguments.contains("-hang-monitor")

    static func mark(_ label: String) {
        guard enabled else { return }
        print("[mark] \(label) at \(String(format: "%.3f", Date().timeIntervalSince1970))")
    }
}
#endif
