import AppKit
import CoreAudio
import CoreBluetooth
import CoreServices
import ServiceManagement

@MainActor
final class StatusMenu: NSObject, NSApplicationDelegate, CBCentralManagerDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private lazy var settings = SettingsWindow()
    private var central: CBCentralManager?
    private var heartbeat: Timer?
    private var outputListener: AudioObjectPropertyListenerBlock?
    private var power: BluetoothPower = .unavailable
    private var output: AudioOutput?
    private var paired: [BluetoothDevice]?
    private var profiled: [BluetoothDevice] = []
    private var refreshingDevices = false
    private var profiling = false
    private var lastProfile = Date.distantPast
    private var changing = false
    private var presentingMenu = false
    private var lastGlyph: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        item.autosaveName = "bluetooth_sound"
        item.button?.target = self
        item.button?.action = #selector(statusClicked)
        _ = item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        central = CBCentralManager(delegate: self, queue: nil, options: [CBCentralManagerOptionShowPowerAlertKey: false])
        refreshStatus()
        let timer = Timer(timeInterval: 2, target: self, selector: #selector(refreshStatus), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        heartbeat = timer

        var property = Audio.defaultOutputProperty
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.refreshStatus() }
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &property, .main, listener) == noErr {
            outputListener = listener
        }

        let launchEvent = NSAppleEventManager.shared().currentAppleEvent
        let reason = launchEvent?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue
        // Service Management can also launch the process without an Apple event.
        let launchedAtLogin = reason == keyAELaunchedAsLogInItem || reason == keyAELaunchedAsServiceItem
            || (launchEvent == nil && SMAppService.mainApp.status == .enabled)
        if !launchedAtLogin { showSettings() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        heartbeat?.invalidate()
        if let outputListener {
            var property = Audio.defaultOutputProperty
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &property, .main, outputListener)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in refreshStatus() }
    }

    private var bluetoothDenied: Bool {
        CBCentralManager.authorization == .denied || CBCentralManager.authorization == .restricted
    }

    private var devices: [BluetoothDevice] {
        var index = Dictionary(profiled.map { ($0.address, $0) }, uniquingKeysWith: { first, _ in first })
        for device in paired ?? [] {
            guard let metadata = index[device.address] else {
                index[device.address] = device
                continue
            }
            index[device.address] = BluetoothDevice(address: device.address, name: device.name,
                                                    kind: metadata.kind == .other ? device.kind : metadata.kind,
                                                    connected: device.connected, battery: metadata.battery)
        }
        return index.values.sorted {
            if $0.connected != $1.connected { return $0.connected }
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.address < $1.address : order == .orderedAscending
        }
    }

    @objc private func refreshStatus() {
        let previousPower = power
        power = central?.state == .unsupported ? .unavailable : Adapter.power()
        output = Audio.currentOutput()
        if power != previousPower && power != .on {
            paired = nil
            profiled = []
            lastProfile = .distantPast
        }
        if power == .on && CBCentralManager.authorization == .allowedAlways {
            refreshDevices()
        }
        updateIcon()
    }

    private func refreshDevices(profileNow: Bool = false) {
        if !refreshingDevices {
            refreshingDevices = true
            BluetoothDevices.queue.async { [weak self] in
                let current = BluetoothDevices.paired()
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.refreshingDevices = false
                    guard self.power == .on else { return }
                    let formerlyConnected = Set((self.paired ?? []).filter(\.connected).map(\.address))
                    let nowConnected = Set(current.filter(\.connected).map(\.address))
                    self.paired = current
                    self.updateIcon()
                    if formerlyConnected != nowConnected { self.refreshProfile(force: true) }
                }
            }
        }
        refreshProfile(force: profileNow)
    }

    private func refreshProfile(force: Bool) {
        guard !profiling, force || Date().timeIntervalSince(lastProfile) >= 30 else { return }
        profiling = true
        lastProfile = Date()
        Task { [weak self] in
            let snapshot = await BluetoothDevices.extendedSnapshot()
            guard let self else { return }
            self.profiling = false
            guard self.power == .on, let snapshot else { return }
            self.profiled = snapshot
            self.updateIcon()
        }
    }

    private func updateIcon() {
        guard let button = item.button else { return }
        let kind = output?.kind(in: devices) ?? .speaker
        let key = power == .on ? String(describing: kind) : String(describing: power)
        if key != lastGlyph {
            button.image = power == .on ? Glyphs.device(kind) : Glyphs.bluetooth(slashed: power == .off)
            lastGlyph = key
        }

        let status: String
        switch power {
        case .on:
            status = output.flatMap { $0.name.isEmpty ? nil : $0.name } ?? L10n.text("bluetooth.on")
        case .off: status = L10n.text("bluetooth.off")
        case .unavailable: status = L10n.text("bluetooth.unavailable")
        }
        button.setAccessibilityLabel("bluetooth_sound · " + status)
        button.setAccessibilityHelp(L10n.text("status.hint"))
        button.toolTip = status + "\n" + L10n.text("status.hint")
    }

    @objc private func statusClicked(_ sender: NSStatusBarButton) {
        guard !presentingMenu else { return }
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.type == .rightMouseDown
            || event?.buttonNumber == 1 || event?.modifierFlags.contains(.control) == true
            || event?.type == .keyUp || event?.type == .keyDown || event == nil {
            showMenu(from: sender)
        } else {
            togglePower()
        }
    }

    private func showMenu(from button: NSStatusBarButton) {
        refreshStatus()
        let menu = makeMenu()
        // Keeping a menu attached between clicks takes over the primary click on macOS 27.
        presentingMenu = true
        item.menu = menu
        button.performClick(nil)
        item.menu = nil
        presentingMenu = false
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.minimumWidth = 224
        menu.addItem(.sectionHeader(title: L10n.text("bluetooth.title")))

        if changing {
            menu.addItem(menuItem("bluetooth.updating"))
        } else if bluetoothDenied {
            menu.addItem(menuItem("bluetooth.permission", action: #selector(openBluetoothPrivacy)))
        } else {
            switch power {
            case .off: menu.addItem(menuItem("bluetooth.off"))
            case .unavailable: menu.addItem(menuItem("bluetooth.unavailable"))
            case .on:
                let currentDevices = devices
                if currentDevices.isEmpty {
                    menu.addItem(menuItem(paired == nil || profiling ? "bluetooth.loading" : "bluetooth.empty"))
                }
                let outputID = output?.bluetoothDevice(in: currentDevices)?.address
                for device in currentDevices {
                    let isOutput = outputID == device.address
                    let title = Self.deviceMenuTitle(device.name)
                    let entry = NSMenuItem(title: title, action: #selector(selectDevice), keyEquivalent: "")
                    if title != device.name { entry.toolTip = device.name }
                    entry.target = self
                    entry.representedObject = device.address
                    entry.image = Glyphs.device(device.kind, size: 16)
                    let isConnected = isOutput || device.connected
                    entry.state = isConnected ? .on : .off
                    if #available(macOS 27.0, *) { entry.preferredImageVisibility = .visible }

                    if #available(macOS 14.4, *) {
                        var details: [String] = []
                        if isOutput { details.append(L10n.text("device.currentOutput")) }
                        if isConnected {
                            if let left = device.battery.left {
                                details.append(String(format: L10n.text("device.leftBattery"), left))
                            }
                            if let right = device.battery.right {
                                details.append(String(format: L10n.text("device.rightBattery"), right))
                            }
                            if details.count == (isOutput ? 1 : 0), let main = device.battery.main {
                                details.append("\(main)%")
                            }
                        }
                        entry.subtitle = details.isEmpty ? nil : details.joined(separator: "  ·  ")
                    }
                    if isConnected {
                        let submenu = NSMenu()
                        submenu.autoenablesItems = false
                        if !isOutput && device.kind.isAudio {
                            let use = menuItem("device.useForSound", action: #selector(selectDevice))
                            use.representedObject = device.address
                            submenu.addItem(use)
                        }
                        let disconnect = menuItem("device.disconnect", action: #selector(disconnectDevice))
                        disconnect.representedObject = device.address
                        submenu.addItem(disconnect)
                        entry.submenu = submenu
                    }
                    menu.addItem(entry)
                }
            }
        }

        menu.addItem(menuItem("action.bluetoothSettings", action: #selector(openBluetoothSettings)))
        return menu
    }

    static func deviceMenuTitle(_ name: String) -> String {
        let limit: CGFloat = 176
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.menuFont(ofSize: 0)]
        let name = name.split(whereSeparator: \.isNewline).joined(separator: " ")
        if name.size(withAttributes: attributes).width <= limit { return name }

        var prefix = ""
        for character in name {
            let next = prefix + String(character)
            if (next + "…").size(withAttributes: attributes).width > limit { break }
            prefix = next
        }
        return prefix.trimmingCharacters(in: .whitespaces) + "…"
    }

    private func menuItem(_ key: String, action: Selector? = nil) -> NSMenuItem {
        let entry = NSMenuItem(title: L10n.text(key), action: action, keyEquivalent: "")
        entry.target = action == nil ? nil : self
        entry.isEnabled = action != nil
        return entry
    }

    private func togglePower() {
        guard !changing else { return }
        guard !bluetoothDenied else {
            showError(BluetoothFailure.permissionDenied)
            return
        }
        let current = Adapter.power()
        guard current != .unavailable, central?.state != .unsupported else {
            showError(BluetoothFailure.powerUnavailable)
            return
        }
        let destination: BluetoothPower = current == .on ? .off : .on
        changing = true
        Task {
            do {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    BluetoothDevices.queue.async {
                        do { continuation.resume(returning: try Adapter.changePower(to: destination)) }
                        catch { continuation.resume(throwing: error) }
                    }
                }
                for _ in 0..<40 {
                    if Adapter.power() == destination { break }
                    try await Task.sleep(for: .milliseconds(250))
                }
                if Adapter.power() != destination { throw BluetoothFailure.powerDidNotChange }
            } catch {
                showError(error)
            }
            changing = false
            refreshStatus()
        }
    }

    @objc private func selectDevice(_ sender: NSMenuItem) {
        changeDevice(sender, connect: true)
    }

    @objc private func disconnectDevice(_ sender: NSMenuItem) {
        changeDevice(sender, connect: false)
    }

    private func changeDevice(_ sender: NSMenuItem, connect: Bool) {
        guard !changing, power == .on, !bluetoothDenied,
              let address = sender.representedObject as? String,
              let target = devices.first(where: { $0.address == address }) else { return }
        changing = true
        var matchingDevices = devices
        Task {
            do {
                // An active Core Audio endpoint already proves that an audio connection exists.
                if !connect || !Audio.selectOutput(for: target, among: matchingDevices) {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        BluetoothDevices.queue.async {
                            do { continuation.resume(returning: try BluetoothDevices.changeConnection(target, connect: connect)) }
                            catch { continuation.resume(throwing: error) }
                        }
                    }
                    if connect && target.kind.isAudio {
                        var routed = false
                        for _ in 0..<24 {
                            if Audio.selectOutput(for: target, among: matchingDevices) {
                                routed = true
                                break
                            }
                            try await Task.sleep(for: .milliseconds(250))
                            matchingDevices = devices
                        }
                        if !routed { throw BluetoothFailure.outputUnavailable }
                    }
                }
            } catch {
                showError(error, device: target.name)
            }
            changing = false
            profiled.removeAll { $0.address == target.address }
            refreshStatus()
            refreshDevices(profileNow: true)
        }
    }

    private func showError(_ error: Error, device: String? = nil) {
        let alert = NSAlert()
        alert.messageText = device ?? "bluetooth_sound"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: L10n.text("action.ok"))
        if (error as? BluetoothFailure) == .permissionDenied {
            alert.addButton(withTitle: L10n.text("action.openSettings"))
        }
        NSApp.activate()
        if alert.runModal() == .alertSecondButtonReturn { openBluetoothPrivacy() }
    }

    private func showSettings() {
        settings.onLanguageChange = { [weak self] in self?.updateIcon() }
        NSApp.activate()
        settings.showWindow(nil)
        settings.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func openBluetoothSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openBluetoothPrivacy() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth") {
            NSWorkspace.shared.open(url)
        }
    }
}
