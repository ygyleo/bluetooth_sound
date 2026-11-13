import AppKit

@MainActor
enum Glyphs {
    static func device(_ kind: DeviceKind, size: CGFloat = 15) -> NSImage {
        switch kind {
        case .airPods: symbol("airpods", size: size)
        case .airPods3: symbol("airpods.gen3", fallback: "airpods", size: size)
        case .airPods4: symbol("airpods.gen4", fallback: "airpods", size: size)
        case .airPodsPro: symbol("airpodspro", fallback: "airpods", size: size)
        case .airPodsMax: symbol("airpodsmax", size: size)
        case .earbuds: symbol("earbuds", size: size)
        case .headphones: symbol("headphones", size: size)
        case .speaker: symbol("speaker.wave.2.fill", size: size)
        case .externalSpeaker: symbol("hifispeaker.fill", size: size)
        case .display: symbol("display", size: size)
        case .airPlay: symbol("airplay.audio", size: size)
        case .keyboard: symbol("keyboard", size: size)
        case .mouse: symbol("computermouse", size: size)
        case .trackpad: symbol("trackpad", size: size)
        case .controller: symbol("gamecontroller", size: size)
        case .phone: symbol("iphone", size: size)
        case .tablet: symbol("ipad", size: size)
        case .computer: symbol("laptopcomputer", size: size)
        case .other: bluetooth()
        }
    }

    static func symbol(_ name: String, fallback: String = "headphones", size: CGFloat = 15) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: fallback, accessibilityDescription: nil)
        return image?.withSymbolConfiguration(configuration) ?? bluetooth()
    }

    static func bluetooth(slashed: Bool = false) -> NSImage {
        let badge = NSImage(named: NSImage.bluetoothTemplateName)
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            if let badge {
                let width = 15 * badge.size.width / badge.size.height
                badge.draw(in: NSRect(x: (18 - width) / 2, y: 1.5, width: width, height: 15))
            }
            if slashed {
                let slash = NSBezierPath()
                slash.move(to: NSPoint(x: 3, y: 15))
                slash.line(to: NSPoint(x: 15, y: 3))
                slash.lineCapStyle = .round
                let context = NSGraphicsContext.current?.cgContext
                context?.saveGState()
                context?.setBlendMode(.destinationOut)
                NSColor.black.setStroke()
                slash.lineWidth = 3.5
                slash.stroke()
                context?.restoreGState()
                NSColor.black.setStroke()
                slash.lineWidth = 1.5
                slash.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
