import AudioToolbox
import CoreAudio
import Foundation
import RafuCore

/// The one way the capture code calls Core Audio. Each named call records
/// its call name and `OSStatus` to the meeting diagnostics, so a different
/// behaviour on another Mac shows in the exported file. Device-fact reads
/// (`.other`) are recorded only when they fail, so the file is not full of
/// zeros.
nonisolated struct MeetingCoreAudio: Sendable {
    let diagnostics: any MeetingDiagnosticsRecording
    let meeting: MeetingID?

    static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    /// Runs one Core Audio call and records it.
    @discardableResult
    func call(_ name: MeetingCoreAudioCall, _ body: () -> OSStatus) -> OSStatus {
        let status = body()
        if name != .other || status != noErr {
            diagnostics.record(.coreAudioCall(name, status: status), meeting: meeting)
        }
        return status
    }

    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    /// Reads a fixed-size property.
    func read<T: BitwiseCopyable>(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        as name: MeetingCoreAudioCall = .other, initial: T
    ) -> (T, OSStatus) {
        var value = initial
        var address = Self.address(selector, scope: scope)
        var size = UInt32(MemoryLayout<T>.size)
        let status = call(name) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        }
        return (value, status)
    }

    /// Reads a `CFString` property.
    func readString(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> String? {
        var address = Self.address(selector, scope: scope)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>?
        let status = call(.other) {
            withUnsafeMutablePointer(to: &value) {
                AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
            }
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    func defaultDevice(input: Bool) -> AudioObjectID? {
        let (id, status) = read(
            Self.systemObject,
            input
                ? kAudioHardwarePropertyDefaultInputDevice
                : kAudioHardwarePropertyDefaultOutputDevice,
            as: input ? .readDefaultInputDevice : .readDefaultOutputDevice,
            initial: AudioObjectID(kAudioObjectUnknown))
        return status == noErr && id != kAudioObjectUnknown ? id : nil
    }

    func channelCount(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var address = Self.address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard
            call(.other, { AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) })
                == noErr, size > 0
        else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard
            call(.other, { AudioObjectGetPropertyData(device, &address, 0, nil, &size, list) })
                == noErr
        else { return 0 }
        return UnsafeMutableAudioBufferListPointer(list).reduce(0) {
            $0 + Int($1.mNumberChannels)
        }
    }

    func facts(_ device: AudioObjectID, input: Bool) -> MeetingAudioDeviceFacts {
        let scope = input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
        return MeetingAudioDeviceFacts(
            name: MeetingDiagnosticString(readString(device, kAudioObjectPropertyName) ?? ""),
            uid: MeetingDiagnosticString(readString(device, kAudioDevicePropertyDeviceUID) ?? ""),
            transportType: read(device, kAudioDevicePropertyTransportType, initial: UInt32(0)).0,
            nominalSampleRate: read(
                device, kAudioDevicePropertyNominalSampleRate, initial: Float64(0)
            ).0,
            channelCount: channelCount(device, scope: scope))
    }

    /// Every device with input channels.
    func inputDevices() -> [MeetingInputDevice] {
        var address = Self.address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard
            call(
                .other,
                {
                    AudioObjectGetPropertyDataSize(Self.systemObject, &address, 0, nil, &size)
                }) == noErr
        else { return [] }
        var ids = [AudioObjectID](
            repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard
            call(
                .other,
                {
                    AudioObjectGetPropertyData(Self.systemObject, &address, 0, nil, &size, &ids)
                }) == noErr
        else { return [] }
        return ids.compactMap { inputDevice($0) }
    }

    func inputDevice(_ id: AudioObjectID) -> MeetingInputDevice? {
        guard channelCount(id, scope: kAudioObjectPropertyScopeInput) > 0,
            let uid = readString(id, kAudioDevicePropertyDeviceUID)
        else { return nil }
        return MeetingInputDevice(
            objectID: id, uid: uid, name: readString(id, kAudioObjectPropertyName) ?? "",
            transportType: read(id, kAudioDevicePropertyTransportType, initial: UInt32(0)).0)
    }

    /// True when the output device is the built-in speakers (not built-in
    /// headphones): transport built-in and data source `ispk`.
    func isBuiltInSpeakers(_ device: AudioObjectID) -> Bool {
        let transport = read(device, kAudioDevicePropertyTransportType, initial: UInt32(0)).0
        guard transport == kAudioDeviceTransportTypeBuiltIn else { return false }
        let (source, status) = read(
            device, kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeOutput,
            initial: UInt32(0))
        guard status == noErr else { return true }
        return source == MeetingTransportType.fourCharacterCode("ispk")
    }

    /// The Core Audio process object of this app, for the tap's exclusion
    /// list.
    func ownProcessObject() -> AudioObjectID? {
        var pid = getpid()
        var address = Self.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = call(.other) {
            AudioObjectGetPropertyData(
                Self.systemObject, &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size,
                &object)
        }
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }
}

/// The processes that play sound now, from Core Audio's process list
/// (`isRunningOutput`), without Rafu itself.
nonisolated struct MeetingCoreAudioPlayingProcesses: MeetingPlayingProcessListing {
    func playingBundleIDs() async -> [String] {
        Self.current()
    }

    static func current() -> [String] {
        guard let processes = try? AudioHardwareSystem.shared.processes else { return [] }
        let own = getpid()
        var ids = Set<String>()
        for process in processes {
            guard (try? process.isRunningOutput) == true,
                let pid = try? process.pid, pid != own
            else { continue }
            ids.insert((try? process.bundleID) ?? "no-bundle-id")
        }
        return ids.sorted()
    }
}
