import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    // the faceplate wants room: 1480 x 960 where the screen has it
    let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1480, height: 960)
    let size = NSSize(width: min(1480, visible.width), height: min(960, visible.height))
    self.setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2, width: size.width, height: size.height), display: true)
    self.minSize = NSSize(width: 1000, height: 700)
    self.title = "Striso Live"

    RegisterGeneratedPlugins(registry: flutterViewController)

    // --hidden or --smoke=<s> (smoke tests): the window stays invisible and off-screen, takes no
    // clicks, and the app no Dock icon or focus (as the Windows runner's minimized, off-screen one)
    if CommandLine.arguments.contains(where: { $0 == "--hidden" || $0.hasPrefix("--smoke=") }) {
      NSApp.setActivationPolicy(.prohibited)
      self.alphaValue = 0
      self.ignoresMouseEvents = true
      self.setFrameOrigin(NSPoint(x: -32000, y: -32000))
    }

    super.awakeFromNib()
  }
}
