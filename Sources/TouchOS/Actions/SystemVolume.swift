import AudioToolbox
import CoreAudio
import OSLog
import TouchOSCore

/// 默认输出设备的主音量（0–1），供滑杆槽位使用。设备不支持软件音量（例如部分 HDMI 输出）时读写失败，返回 nil / 忽略。
enum SystemVolume {
    private static let log = Logger(subsystem: TouchOSCore.logSubsystem, category: "volume")
    private static let queue = DispatchQueue(label: "ai.nekro.touchos.volume", qos: .userInitiated)

    private static var volumeAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                   mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }

    private static func defaultOutput() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return status == noErr ? id : nil
    }

    static func get() -> Double? {
        guard let device = defaultOutput() else { return nil }
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = volumeAddress
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return Double(value)
    }

    /// 异步设置，不阻塞输入队列
    static func set(_ value: Double) {
        queue.async {
            guard let device = defaultOutput() else { return }
            var v = Float32(min(max(value, 0), 1))
            var address = volumeAddress
            let status = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
            if status != noErr { log.info("set volume failed: \(status)") }
        }
    }
}
