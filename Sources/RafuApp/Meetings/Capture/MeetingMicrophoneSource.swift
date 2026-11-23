import AVFoundation
import CoreAudio
import Foundation
import RafuCore

/// "Me": the microphone through a Core Audio IO block on the input device
/// itself, the same path as "Them". The device comes from Settings ▸
/// Meetings ▸ Microphone through `MeetingMicrophonePolicy` (Automatic picks
/// the built-in microphone over a Bluetooth headset). The format is the
/// virtual format of the device's first input stream; the rate is the
/// device's nominal rate (`MeetingInputFormatPolicy`). No voice processing:
/// it stopped the call-audio tap in the capture check.
///
/// An earlier version used the AVFoundation audio engine and set the device
/// on its input audio unit. The engine did not see that change, its format
/// did not match the hardware, and the tap call raised an NSException that
/// aborted all of Rafu (a Bluetooth headset in call mode). This path makes
/// no Objective-C call that can raise.
///
/// A change of the default input device (when the choice follows it), the
/// loss of the device or a change of its nominal rate ends the run with
/// `.interrupted`; the recorder starts it again, which resolves the device
/// and reads the format again.
@available(macOS 26, *)
actor MeetingMicrophoneSource: MeetingAudioSource {
    nonisolated let track: MeetingTrack = .me

    private let choice: @Sendable () -> MeetingMicrophoneChoice
    private let listenerQueue = DispatchQueue(label: "dev.vatsalsaglani.rafu.meetings.mic.listen")
    private let ioQueue = DispatchQueue(
        label: "dev.vatsalsaglani.rafu.meetings.mic.io", qos: .userInteractive)

    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var pipeline: MeetingTrackPipeline?
    private var drainTask: Task<Void, Never>?
    private var events: AsyncStream<MeetingAudioSourceEvent>.Continuation?
    private var listeners: [MeetingPropertyListener] = []
    private var deviceFacts: MeetingAudioDeviceFacts?
    private var coreAudio = MeetingCoreAudio(diagnostics: NoopMeetingDiagnostics(), meeting: nil)
    /// Counts runs, so a late listener call cannot end a newer run.
    private var runID = 0

    /// The most passes of read-format-then-start when the nominal rate
    /// changes between the read and the start.
    private static let maximumPasses = 2

    init(choice: @escaping @Sendable () -> MeetingMicrophoneChoice) {
        self.choice = choice
    }

    func start(meeting: MeetingID?, diagnostics: any MeetingDiagnosticsRecording) async throws
        -> MeetingAudioSourceRun
    {
        teardown(reason: nil)
        runID += 1
        let audio = MeetingCoreAudio(diagnostics: diagnostics, meeting: meeting)
        coreAudio = audio

        let defaultInput = audio.defaultDevice(input: true).flatMap { audio.inputDevice($0) }
        let resolution = MeetingMicrophonePolicy.resolve(
            choice: choice(), defaultInput: defaultInput, inputs: audio.inputDevices())
        guard let device = resolution.device else { throw MeetingAudioSourceError.noDevice }
        let objectID = AudioObjectID(device.objectID)

        var pass = 0
        while true {
            pass += 1
            let layout = try Self.readLayout(objectID, audio: audio)

            let (blocks, blockContinuation) = AsyncStream.makeStream(
                of: MeetingCapturedBlock.self, bufferingPolicy: .bufferingNewest(400))
            let (eventStream, eventContinuation) = AsyncStream.makeStream(
                of: MeetingAudioSourceEvent.self)
            let ring = MeetingCaptureRing()
            pipeline = MeetingTrackPipeline(ring: ring, continuation: blockContinuation)
            events = eventContinuation

            do {
                try openDevice(objectID, ring: ring, layout: layout, audio: audio)
            } catch {
                teardown(reason: nil)
                throw error
            }

            // The rate can change between the read and the start (a headset
            // that enters call mode); then each label would be wrong.
            let (rateNow, rateStatus) = audio.read(
                objectID, kAudioDevicePropertyNominalSampleRate, as: .readNominalSampleRate,
                initial: Float64(0))
            if rateStatus == noErr, rateNow.isFinite, rateNow > 0, rateNow != layout.sampleRate {
                teardown(reason: nil)
                guard pass < Self.maximumPasses else {
                    throw MeetingAudioSourceError.failed(call: .readNominalSampleRate, status: -1)
                }
                continue
            }

            let facts = audio.facts(objectID, input: true)
            deviceFacts = facts
            if resolution.kind != .named || resolution.reason == .namedDeviceMissing {
                addListener(MeetingCoreAudio.systemObject, kAudioHardwarePropertyDefaultInputDevice)
            }
            addListener(objectID, kAudioDevicePropertyDeviceIsAlive)
            addListener(objectID, kAudioDevicePropertyNominalSampleRate)
            drainTask = Task { await self.drainLoop() }

            return MeetingAudioSourceRun(
                facts: MeetingAudioSourceFacts(
                    device: facts, captureSampleRate: layout.sampleRate, microphone: resolution),
                blocks: blocks, events: eventStream)
        }
    }

    func stop() async {
        teardown(reason: nil)
    }

    func takeCallbackCounters() async -> MeetingCallbackCounters {
        pipeline?.takeCounters() ?? MeetingCallbackCounters()
    }

    /// A listener saw a device change. A listener of an older run (Core
    /// Audio can call several listeners for one change) does nothing.
    func interrupt(run: Int) {
        guard pipeline != nil, run == runID else { return }
        teardown(reason: .interrupted(old: deviceFacts))
    }

    private func drainLoop() async {
        while !Task.isCancelled {
            pipeline?.drain()
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Reads the first input stream's format and the nominal rate, records
    /// them, and applies the format rule.
    private static func readLayout(_ device: AudioObjectID, audio: MeetingCoreAudio) throws
        -> MeetingTapLayout
    {
        guard let stream = audio.inputStreamFormat(device) else {
            throw MeetingAudioSourceError.failed(call: .other, status: -1)
        }
        let (nominal, nominalStatus) = audio.read(
            device, kAudioDevicePropertyNominalSampleRate, as: .readNominalSampleRate,
            initial: Float64(0))
        let format = MeetingTapFormat(
            sampleRate: stream.mSampleRate, channelCount: Int(stream.mChannelsPerFrame),
            bitsPerChannel: Int(stream.mBitsPerChannel),
            isInterleaved: stream.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0)
        let isFloat32 =
            stream.mFormatID == kAudioFormatLinearPCM
            && stream.mFormatFlags & kAudioFormatFlagIsFloat != 0 && stream.mBitsPerChannel == 32
        let nominalRate = nominalStatus == noErr ? nominal : nil
        audio.diagnostics.record(
            .microphoneFormat(format, isFloat32: isFloat32, nominalSampleRate: nominalRate ?? 0),
            meeting: audio.meeting)
        let layout: MeetingInputLayout
        do {
            layout = try MeetingInputFormatPolicy.layout(
                streamFormat: format, isFloat32: isFloat32, nominalRate: nominalRate)
        } catch {
            throw MeetingAudioSourceError.failed(call: .other, status: -1)
        }
        return MeetingTapLayout(
            channelCount: layout.channelCount, isInterleaved: layout.isInterleaved,
            isFloat32: true, sampleRate: layout.sampleRate)
    }

    /// Creates the IO proc on the device and starts it. On a failure the
    /// caller tears down what was made.
    private func openDevice(
        _ device: AudioObjectID, ring: MeetingCaptureRing, layout: MeetingTapLayout,
        audio: MeetingCoreAudio
    ) throws {
        let ioBlock = Self.ioBlock(ring: ring, layout: layout)
        var newProc: AudioDeviceIOProcID?
        let createStatus = audio.call(.createIOProc) {
            AudioDeviceCreateIOProcIDWithBlock(&newProc, device, ioQueue, ioBlock)
        }
        guard createStatus == noErr, let newProc else {
            throw MeetingAudioSourceError.failed(
                call: .createIOProc, status: createStatus == noErr ? -1 : createStatus)
        }
        deviceID = device
        procID = newProc
        let startStatus = audio.call(.startDevice) { AudioDeviceStart(device, newProc) }
        guard startStatus == noErr else {
            throw MeetingAudioSourceError.failed(call: .startDevice, status: startStatus)
        }
    }

    /// Built outside the actor: a block formed inside an isolated type
    /// inherits that isolation under Swift 6 and traps on the audio thread.
    private nonisolated static func ioBlock(ring: MeetingCaptureRing, layout: MeetingTapLayout)
        -> AudioDeviceIOBlock
    {
        MeetingAudioCallbacks.deviceIOBlock(ring: ring, layout: layout)
    }

    /// Built outside the actor: Core Audio calls it on `listenerQueue`.
    private nonisolated static func listenerBlock(source: MeetingMicrophoneSource, run: Int)
        -> MeetingPropertyListener.Block
    {
        { _, _ in Task { await source.interrupt(run: run) } }
    }

    private func addListener(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) {
        var address = MeetingCoreAudio.address(selector)
        let block = Self.listenerBlock(source: self, run: runID)
        let status = coreAudio.call(.addPropertyListener) {
            AudioObjectAddPropertyListenerBlock(object, &address, listenerQueue, block)
        }
        if status == noErr {
            listeners.append(
                MeetingPropertyListener(object: object, address: address, block: block))
        }
    }

    /// The order of "Them": stop the device, destroy the IO proc, remove the
    /// listeners, then drain. After `AudioDeviceStop` returns, the IO block
    /// does not run again, so the ring can go.
    private func teardown(reason: MeetingAudioSourceEvent?) {
        let audio = coreAudio
        if deviceID != kAudioObjectUnknown, let procID {
            let stopStatus = AudioDeviceStop(deviceID, procID)
            audio.call(.stopDevice) { stopStatus }
            let destroyStatus = AudioDeviceDestroyIOProcID(deviceID, procID)
            audio.call(.destroyIOProc) { destroyStatus }
        }
        procID = nil
        deviceID = AudioObjectID(kAudioObjectUnknown)
        for listener in listeners {
            var address = listener.address
            audio.call(.removePropertyListener) {
                AudioObjectRemovePropertyListenerBlock(
                    listener.object, &address, listenerQueue, listener.block)
            }
        }
        listeners = []
        drainTask?.cancel()
        drainTask = nil
        if let pipeline {
            pipeline.drain()
            pipeline.finish()
        }
        pipeline = nil
        if let reason { events?.yield(reason) }
        events?.finish()
        events = nil
    }
}

/// The permission checks at each Start. Microphone: `AVCaptureDevice`.
/// System audio: macOS has no public status call (no permission API in the
/// Core Audio headers of SDK 27.2), so it is `.unknown`; the recorder finds
/// a denial from exact-silence tap buffers while another app plays sound.
nonisolated struct MeetingSystemPermissions: MeetingPermissionChecking {
    func microphoneState() async -> MeetingPermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        case .denied, .restricted: .denied
        @unknown default: .unknown
        }
    }

    func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    func systemAudioState() async -> MeetingPermissionState { .unknown }
}
