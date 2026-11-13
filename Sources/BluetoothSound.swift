import AppKit

@main
struct BluetoothSound {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = StatusMenu()
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
