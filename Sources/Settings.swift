import AppKit
import ServiceManagement

enum AppLanguage: String, CaseIterable {
    case english = "en"
    case chinese = "zh-Hans"

    static let preferenceKey = "language"
    static var initial: Self {
        Locale.preferredLanguages.first?.hasPrefix("zh") == true ? .chinese : .english
    }
    static var current: Self {
        UserDefaults.standard.string(forKey: preferenceKey).flatMap(Self.init(rawValue:)) ?? initial
    }
    var title: String { self == .english ? "English" : "简体中文" }
}

enum L10n {
    static func text(_ key: String, language: AppLanguage = .current) -> String {
        let bundle = Bundle.main.path(forResource: language.rawValue, ofType: "lproj").flatMap(Bundle.init(path:))
        return bundle?.localizedString(forKey: key, value: nil, table: nil) ?? key
    }
}

@MainActor
final class SettingsWindow: NSWindowController, NSWindowDelegate {
    var onLanguageChange: (() -> Void)?

    private let languageLabel = NSTextField(labelWithString: "")
    private let loginLabel = NSTextField(labelWithString: "")
    private let languageControl = NSSegmentedControl(labels: AppLanguage.allCases.map(\.title),
                                                      trackingMode: .selectOne, target: nil, action: nil)
    private let loginSwitch = NSSwitch()
    private let approvalButton = NSButton()

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 390, height: 108),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: window)
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("Settings")

        languageControl.target = self
        languageControl.action = #selector(changeLanguage)
        loginSwitch.target = self
        loginSwitch.action = #selector(updateLogin)
        approvalButton.target = self
        approvalButton.action = #selector(openLoginItems)
        approvalButton.bezelStyle = .inline

        let controls = NSGridView(views: [[languageLabel, languageControl], [loginLabel, loginSwitch]])
        controls.rowSpacing = 15
        controls.columnSpacing = 14
        controls.column(at: 1).xPlacement = .trailing
        for row in 0..<controls.numberOfRows {
            controls.row(at: row).rowAlignment = .firstBaseline
        }
        let stack = NSStackView(views: [controls, approvalButton])
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        if let content = window.contentView {
            content.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
                stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
                controls.widthAnchor.constraint(equalTo: stack.widthAnchor)
            ])
        }
        refresh()
    }

    required init?(coder: NSCoder) { nil }

    func windowDidBecomeKey(_ notification: Notification) {
        refresh()
    }

    private func refresh() {
        window?.title = L10n.text("settings.title")
        languageLabel.stringValue = L10n.text("settings.language")
        loginLabel.stringValue = L10n.text("settings.login")
        languageControl.setAccessibilityLabel(languageLabel.stringValue)
        loginSwitch.setAccessibilityLabel(loginLabel.stringValue)
        languageControl.selectedSegment = AppLanguage.allCases.firstIndex(of: .current) ?? 0

        let status = SMAppService.mainApp.status
        loginSwitch.state = status == .enabled || status == .requiresApproval ? .on : .off
        approvalButton.title = L10n.text("settings.approve")
        approvalButton.isHidden = status != .requiresApproval
        let height: CGFloat = approvalButton.isHidden ? 108 : 142
        if let window, window.contentView?.frame.height != height {
            window.setContentSize(NSSize(width: 390, height: height))
        }
    }

    @objc private func changeLanguage() {
        let index = languageControl.selectedSegment
        guard AppLanguage.allCases.indices.contains(index) else { return }
        UserDefaults.standard.set(AppLanguage.allCases[index].rawValue, forKey: AppLanguage.preferenceKey)
        refresh()
        onLanguageChange?()
    }

    @objc private func updateLogin() {
        let service = SMAppService.mainApp
        do {
            if loginSwitch.state == .on {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = L10n.text("error.login")
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: L10n.text("action.ok"))
            if let window { alert.beginSheetModal(for: window) }
        }
        refresh()
    }

    @objc private func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
