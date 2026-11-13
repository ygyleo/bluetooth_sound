import CoreAudio
import Foundation

enum Audio {
    private static let system = AudioObjectID(kAudioObjectSystemObject)
    static let defaultOutputProperty = address(kAudioHardwarePropertyDefaultOutputDevice)

    static func currentOutput() -> AudioOutput? {
        var device = AudioDeviceID(kAudioObjectUnknown)
        guard read(defaultOutputProperty, from: system, into: &device) else { return nil }
        return output(device)
    }

    static func selectOutput(for target: BluetoothDevice, among devices: [BluetoothDevice]) -> Bool {
        if currentOutput()?.bluetoothDevice(in: devices)?.address == target.address { return true }
        guard let match = outputs().first(where: { $0.bluetoothDevice(in: devices)?.address == target.address }) else {
            return false
        }
        var property = defaultOutputProperty
        var id = match.id
        return AudioObjectSetPropertyData(system, &property, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &id) == noErr
    }

    private static func outputs() -> [AudioOutput] {
        var property = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &property, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.stride)
        let used = ids.withUnsafeMutableBytes { bytes -> Bool in
            guard let base = bytes.baseAddress else { return false }
            return AudioObjectGetPropertyData(system, &property, 0, nil, &size, base) == noErr
        }
        return used ? ids.compactMap(output) : []
    }

    private static func output(_ id: AudioDeviceID) -> AudioOutput? {
        guard id != kAudioObjectUnknown else { return nil }
        var streams = address(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &size) == noErr, size > 0 else { return nil }
        var transport: UInt32 = 0
        _ = read(address(kAudioDevicePropertyTransportType), from: id, into: &transport)
        return AudioOutput(id: id, uid: string(kAudioDevicePropertyDeviceUID, from: id) ?? "",
                           name: string(kAudioObjectPropertyName, from: id) ?? "", transport: transport)
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func string(_ selector: AudioObjectPropertySelector, from id: AudioObjectID) -> String? {
        var value: Unmanaged<CFString>?
        return read(address(selector), from: id, into: &value) ? value?.takeRetainedValue() as String? : nil
    }

    private static func read<T>(_ address: AudioObjectPropertyAddress, from id: AudioObjectID, into value: inout T) -> Bool {
        var property = address
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutableBytes(of: &value) { bytes in
            guard let base = bytes.baseAddress else { return false }
            return AudioObjectGetPropertyData(id, &property, 0, nil, &size, base) == noErr
        }
    }
}
