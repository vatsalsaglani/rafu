import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import RafuCore

/// "Me": the microphone through `AVAudioEngine`. The device comes from
/// Settings ▸ Meetings ▸ Microphone through `MeetingMicrophonePolicy`
/// (Automatic picks the built-in microphone over a Bluetooth headset). The
/// device is set on the input node's audio unit with
/// `kAudioOutputUnitProperty_CurrentDevice` (global scope, an
/// `AudioObjectID`, read/write; confirmed in `AudioUnitProperties.h`). No
/// voice processing: it stopped the call-audio tap in the capture check.
///
/// An engine configuration change or a change of the default input device
/// ends the run with `.interrupted`; the recorder starts it again, which
/// resolves the device again.
@available(macOS 26, *)
actor MeetingMicrophoneSource: MeetingAudioSource {
    nonisolated let track: MeetingTrack = .me

    private let choice: @Sendable () -> MeetingMicrophoneChoice
    private let listenerQueue = DispatchQueue(label: "dev.vatsalsaglani.rafu.meetings.mic.listen")
    private var engine: AVAudioEngine?
    private var pipeline: MeetingTrackPipeline?
    private var drainTask: Task<Void, Never>?
    private var events: AsyncStream<MeetingAudioSourceEvent>.Continuation?
    private var configurationObserver: (any NSObjectProtocol)?
    private var listeners: [MeetingPropertyListener] = []
    private var deviceFacts: MeetingAudioDeviceFacts?
    private var coreAudio = MeetingCoreAudio(diagnostics: NoopMeetingDiagnostics(), meeting: nil)
    /// Counts runs, so a late listener call cannot end a newer run.
    private var runID = 0
    private var startedAt: ContinuousClock.Instant?

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

        let engine = AVAudioEngine()
        let input = engine.inputNode
        guard let unit = input.audioUnit else {
            throw MeetingAudioSourceError.failed(call: .setInputDevice, status: -1)
        }
        var objectID = device.objectID
        let setStatus = audio.call(.setInputDevice) {
            AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &objectID, UInt32(MemoryLayout<AudioObjectID>.size))
        }
        guard setStatus == noErr else {
            throw MeetingAudioSourceError.failed(call: .setInputDevice, status: setStatus)
        }

        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw MeetingAudioSourceError.noDevice
        }

        let (blocks, blockContinuation) = AsyncStream.makeStream(
            of: MeetingCapturedBlock.self, bufferingPolicy: .bufferingNewest(400))
        let (eventStream, eventContinuation) = AsyncStream.makeStream(
            of: MeetingAudioSourceEvent.self)
        let ring = MeetingCaptureRing()
        let newPipeline = MeetingTrackPipeline(ring: ring, continuation: blockContinuation)

        Self.installTap(on: input, format: format, ring: ring)
        engine.prepare()
        do {
            try engine.start()
            audio.diagnostics.record(.coreAudioCall(.startDevice, status: noErr), meeting: meeting)
        } catch {
            let code = Int32(truncatingIfNeeded: (error as NSError).code)
            audio.diagnostics.record(.coreAudioCall(.startDevice, status: code), meeting: meeting)
            input.removeTap(onBus: 0)
            blockContinuation.finish()
            eventContinuation.finish()
            throw MeetingAudioSourceError.failed(call: .startDevice, status: code)
        }

        self.engine = engine
        startedAt = .now
        pipeline = newPipeline
        events = eventContinuation
        let facts = audio.facts(device.objectID, input: true)
        deviceFacts = facts
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil,
            using: Self.interruptionHandler(source: self, run: runID))
        if resolution.kind != .named || resolution.reason == .namedDeviceMissing {
            addListener(MeetingCoreAudio.systemObject, kAudioHardwarePropertyDefaultInputDevice)
        }
        addListener(device.objectID, kAudioDevicePropertyDeviceIsAlive)
        drainTask = Task { await self.drainLoop() }

        return MeetingAudioSourceRun(
            facts: MeetingAudioSourceFacts(
                device: facts, captureSampleRate: format.sampleRate, microphone: resolution),
            blocks: blocks, events: eventStream)
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

    /// The tap block is built in `MeetingAudioCallbacks`, outside the actor.
    private nonisolated static func installTap(
        on input: AVAudioInputNode, format: AVAudioFormat, ring: MeetingCaptureRing
    ) {
        input.installTap(
            onBus: 0, bufferSize: 4_096, format: format,
            block: MeetingAudioCallbacks.microphoneTapBlock(
                ring: ring, channelCount: Int(format.channelCount), sampleRate: format.sampleRate))
    }

    private nonisolated static func interruptionHandler(source: MeetingMicrophoneSource, run: Int)
        -> @Sendable (Notification) -> Void
    {
        { _ in Task { await source.configurationChanged(run: run) } }
    }

    /// The engine changed its configuration. A change in the first second
    /// after start belongs to the start itself (INFERRED: not measured on
    /// each device), so it does not end the run.
    func configurationChanged(run: Int) {
        guard let startedAt, ContinuousClock.now - startedAt >= .seconds(1) else { return }
        interrupt(run: run)
    }

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

    private func teardown(reason: MeetingAudioSourceEvent?) {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = nil
        for listener in listeners {
            var address = listener.address
            coreAudio.call(.removePropertyListener) {
                AudioObjectRemovePropertyListenerBlock(
                    listener.object, &address, listenerQueue, listener.block)
            }
        }
        listeners = []
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
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
