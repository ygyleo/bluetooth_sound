import CoreAudio
import Foundation
import IOBluetooth

enum DeviceKind: Equatable, Sendable {
    case airPods, airPods3, airPods4, airPodsPro, airPodsMax
    case earbuds, headphones, speaker, externalSpeaker, display, airPlay
    case keyboard, mouse, trackpad, controller, phone, tablet, computer, other

    var isAudio: Bool {
        switch self {
        case .airPods, .airPods3, .airPods4, .airPodsPro, .airPodsMax,
             .earbuds, .headphones, .speaker, .externalSpeaker, .display, .airPlay: true
        default: false
        }
    }

    static func named(_ name: String, type: String = "", product: String = "") -> Self {
        switch product.lowercased() {
        case "0x2002", "0x200f": return .airPods
        case "0x2013": return .airPods3
        case "0x2019", "0x201b": return .airPods4
        case "0x200e", "0x2014", "0x2024", "0x2027": return .airPodsPro
        case "0x200a", "0x201f": return .airPodsMax
        default: break
        }
        let name = name.lowercased()
        if name.contains("airpods") {
            if name.contains("max") { return .airPodsMax }
            if name.contains("pro") { return .airPodsPro }
            if name.contains("4") { return .airPods4 }
            if name.contains("3") { return .airPods3 }
            return .airPods
        }
        let label = name + " " + type.lowercased()
        if label.contains("earbud") || label.contains("zero clip") { return .earbuds }
        if label.contains("headphon") || label.contains("headset") || label.contains("handsfree")
            || label.contains("耳机") || label.contains("耳機") { return .headphones }
        if label.contains("speaker") || label.contains("soundbar") || label.contains("hifi")
            || label.contains("音箱") || label.contains("扬声器") { return .externalSpeaker }
        if label.contains("trackpad") { return .trackpad }
        if label.contains("keyboard") || label.contains("键盘") { return .keyboard }
        if label.contains("mouse") { return .mouse }
        if label.contains("gamepad") || label.contains("controller") { return .controller }
        if label.contains("iphone") || label.contains("smartphone") { return .phone }
        if label.contains("ipad") { return .tablet }
        if label.contains("macbook") { return .computer }
        return .other
    }

    static func classic(_ device: IOBluetoothDevice) -> Self {
        let byName = named(device.name ?? "")
        if byName != .other { return byName }
        switch Int(device.deviceClassMajor) {
        case kBluetoothDeviceClassMajorAudio:
            switch Int(device.deviceClassMinor) {
            case kBluetoothDeviceClassMinorAudioHeadphones, kBluetoothDeviceClassMinorAudioHeadset,
                 kBluetoothDeviceClassMinorAudioHandsFree:
                return .headphones
            case kBluetoothDeviceClassMinorAudioLoudspeaker, kBluetoothDeviceClassMinorAudioCar,
                 kBluetoothDeviceClassMinorAudioHiFi:
                return .externalSpeaker
            default:
                return .other
            }
        case kBluetoothDeviceClassMajorPeripheral:
            let minor = Int(device.deviceClassMinor)
            switch minor & 0x30 {
            case kBluetoothDeviceClassMinorPeripheral1Keyboard, kBluetoothDeviceClassMinorPeripheral1Combo:
                return .keyboard
            case kBluetoothDeviceClassMinorPeripheral1Pointing:
                return .mouse
            default:
                return minor == kBluetoothDeviceClassMinorPeripheral2Gamepad ? .controller : .other
            }
        case kBluetoothDeviceClassMajorPhone: return .phone
        case kBluetoothDeviceClassMajorComputer: return .computer
        default: return .other
        }
    }
}

struct DeviceBattery: Sendable {
    var left: Int?
    var right: Int?
    var main: Int?

    static func percent(_ value: Any?) -> Int? {
        let number = (value as? NSNumber)?.intValue
            ?? (value as? String).flatMap { Int($0.trimmingCharacters(in: CharacterSet(charactersIn: "% "))) }
        return number.flatMap { (0...100).contains($0) ? $0 : nil }
    }
}

struct BluetoothDevice: Sendable {
    let address: String
    let name: String
    let kind: DeviceKind
    let connected: Bool
    var battery = DeviceBattery()

    static func normalizeAddress(_ string: String) -> String? {
        let address = string.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "")
        guard address.count == 12,
              address.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
              address != "000000000000" else { return nil }
        return address.lowercased()
    }

    static func fromProfiler(_ data: Data) -> [Self] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let controllers = root["SPBluetoothDataType"] as? [[String: Any]] else { return [] }
        var devices: [String: Self] = [:]
        for controller in controllers {
            for (key, connected) in [("device_not_connected", false), ("device_connected", true)] {
                for entry in controller[key] as? [[String: [String: Any]]] ?? [] {
                    for (name, info) in entry {
                        guard let raw = info["device_address"] as? String,
                              let address = normalizeAddress(raw) else { continue }
                        if devices[address]?.connected == true && !connected { continue }
                        let kind = DeviceKind.named(name, type: info["device_minorType"] as? String ?? "",
                                                    product: info["device_productID"] as? String ?? "")
                        let battery = DeviceBattery(left: DeviceBattery.percent(info["device_batteryLevelLeft"]),
                                                    right: DeviceBattery.percent(info["device_batteryLevelRight"]),
                                                    main: DeviceBattery.percent(info["device_batteryLevelMain"]))
                        devices[address] = Self(address: address, name: name, kind: kind, connected: connected, battery: battery)
                    }
                }
            }
        }
        return Array(devices.values)
    }
}

struct AudioOutput {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let transport: UInt32

    var isBluetooth: Bool {
        transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    private var bluetoothAddress: String? {
        let addressPattern = #"(?i)(?<![0-9a-f])(?:[0-9a-f]{2}[:-]){5}[0-9a-f]{2}(?![0-9a-f])"#
        if let range = uid.range(of: addressPattern, options: .regularExpression) {
            return BluetoothDevice.normalizeAddress(String(uid[range]))
        }
        return uid.split(separator: ":").first.flatMap { BluetoothDevice.normalizeAddress(String($0)) }
    }

    func bluetoothDevice(in devices: [BluetoothDevice]) -> BluetoothDevice? {
        guard isBluetooth else { return nil }
        if let address = bluetoothAddress { return devices.first { $0.address == address } }
        let matches = devices.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        return matches.count == 1 ? matches.first : nil
    }

    func kind(in devices: [BluetoothDevice]) -> DeviceKind {
        if isBluetooth {
            if let device = bluetoothDevice(in: devices), device.kind.isAudio { return device.kind }
            let byName = DeviceKind.named(name)
            return byName.isAudio ? byName : .headphones
        }
        if transport == kAudioDeviceTransportTypeAirPlay { return .airPlay }
        if transport == kAudioDeviceTransportTypeHDMI || transport == kAudioDeviceTransportTypeDisplayPort { return .display }
        let byName = DeviceKind.named(name)
        if byName.isAudio && byName != .externalSpeaker { return byName }
        return transport == kAudioDeviceTransportTypeBuiltIn ? .speaker : .externalSpeaker
    }
}
