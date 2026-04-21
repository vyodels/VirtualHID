import AppKit
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private let textView = NSTextView(frame: .zero)

    func applicationDidFinishLaunching(_ notification: Notification) {
        let frame = NSRect(x: 220, y: 220, width: 520, height: 360)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Focus Holder"
        window.isReleasedWhenClosed = false
        window.center()

        let contentView = NSView(frame: frame)
        let scrollView = NSScrollView(frame: NSRect(x: 20, y: 20, width: 480, height: 300))
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        textView.string = "这个窗口用于失焦实验。保持它在前台，观察浏览器是否仍收到 CGEventPostToPid 键盘事件。\n你也可以在这里手动输入，检查是否与后台浏览器抢键盘。"
        textView.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.isRichText = false
        scrollView.documentView = textView

        contentView.addSubview(scrollView)
        window.contentView = contentView
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct FocusHolderApp {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.setActivationPolicy(.regular)
        application.delegate = delegate
        application.run()
    }
}
