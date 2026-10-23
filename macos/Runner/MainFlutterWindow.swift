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

    super.awakeFromNib()
  }
}
