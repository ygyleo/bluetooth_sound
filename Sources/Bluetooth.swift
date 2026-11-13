import CoreBluetooth
import Darwin
import Foundation
import IOBluetooth

enum BluetoothPower: Equatable, Sendable {
    case on, off, unavailable
}

enum BluetoothFailure: LocalizedError, Equatable {
    case powerUnavailable, powerDidNotChange, permissionDenied
    case deviceUnavailable, connectionFailed, disconnectionFailed, outputUnavailable

    var errorDescription: String? {
        switch self {
        case .powerUnavailable: L10n.text("error.powerUnavailable")
        case .powerDidNotChange: L10n.text("error.powerDidNotChange")
        case .permissionDenied: L10n.text("error.permissionDenied")
        case .deviceUnavailable: L10n.text("error.deviceUnavailable")
        case .connectionFailed: L10n.text("error.connectionFailed")
        case .disconnectionFailed: L10n.text("error.disconnectionFailed")
        case .outputUnavailable: L10n.text("error.outputUnavailable")
        }
    }
}

// macOS does not expose a public API for changing the adapter's power.
enum Adapter {
    private typealias Getter = @convention(c) () -> Int32
    private typealias Setter = @convention(c) (Int32) -> Void
    // The framework handle stays loaded for the process lifetime.
    nonisolated(unsafe) private static let library = dlopen("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_LAZY)
    private static let available = symbol("IOBluetoothPreferencesAvailable", as: Getter.self)
    private static let get = symbol("IOBluetoothPreferenceGetControllerPowerState", as: Getter.self)
    private static let set = symbol("IOBluetoothPreferenceSetControllerPowerState", as: Setter.self)

    static func power() -> BluetoothPower {
        if available?() == 1, let state = get?() {
            return state == 1 ? .on : .off
        }
        guard let controller = IOBluetoothHostController.default() else { return .unavailable }
        return controller.powerState == kBluetoothHCIPowerStateON ? .on : .off
    }

    static func changePower(to power: BluetoothPower) throws {
        guard let set, available?() == 1 else { throw BluetoothFailure.powerUnavailable }
        set(power == .on ? 1 : 0)
    }

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let library, let pointer = dlsym(library, name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }
}

enum BluetoothDevices {
    static let queue = DispatchQueue(label: "local.bluetooth_sound.devices", qos: .userInitiated)
    private static let profilerQueue = DispatchQueue(label: "local.bluetooth_sound.profiler", qos: .utility)

    static func connectedAddresses() -> Set<String> {
        let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        return Set(devices.filter { $0.isConnected() }
            .compactMap { $0.addressString.flatMap(BluetoothDevice.normalizeAddress) })
    }

    static func changeConnection(_ target: BluetoothDevice, connect: Bool) throws {
        let formatted = stride(from: 0, to: target.address.count, by: 2).map { index in
            let start = target.address.index(target.address.startIndex, offsetBy: index)
            return target.address[start..<target.address.index(start, offsetBy: 2)]
        }.joined(separator: "-")
        let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        let device = devices.first { $0.addressString.flatMap(BluetoothDevice.normalizeAddress) == target.address }
            ?? IOBluetoothDevice(addressString: formatted)
        guard let device else { throw BluetoothFailure.deviceUnavailable }
        if connect {
            guard !device.isConnected() else { return }
            let code = device.openConnection(nil, withPageTimeout: 0x2000, authenticationRequired: false)
            guard code == kIOReturnSuccess || device.isConnected() else { throw BluetoothFailure.connectionFailed }
        } else {
            let code = device.closeConnection()
            guard code == kIOReturnSuccess || !device.isConnected() else { throw BluetoothFailure.disconnectionFailed }
        }
    }

    static func extendedSnapshot() async -> [BluetoothDevice]? {
        await withCheckedContinuation { continuation in
            profilerQueue.async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
                process.arguments = ["-json", "-timeout", "5", "SPBluetoothDataType"]
                process.standardError = FileHandle.nullDevice
                let pipe = Pipe()
                process.standardOutput = pipe
                do {
                    try process.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    continuation.resume(returning: process.terminationStatus == 0 ? BluetoothDevice.fromProfiler(data) : nil)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
