import AVFoundation
import CoreAudio
import Foundation
import RafuCore

/// A registered Core Audio property listener, kept so it can be removed
/// with the same block.
nonisolated struct MeetingPropertyListener {
    var object: AudioObjectID
    var address: AudioObjectPropertyAddress
    typealias Block = @Sendable (UInt32, UnsafePointer<AudioObjectPropertyAddress>) -> Void
    var block: Block
}

/// "Them": all sound that this Mac plays, except Rafu's own, through the
/// global process tap, a private aggregate device and an IO block (the
/// setup that the capture check measured). The rate is the aggregate
/// device's nominal rate, not the tap format's (AirPods in call mode run at
/// 24 kHz while the tap says 48 kHz). No voice processing.
///
/// A change of the default output device, of the aggregate rate, or the
/// loss of the output device ends the run with `.interrupted`; the recorder
/// starts it again, which reads the rate again.
@available(macOS 26, *)
actor MeetingSystemAudioSource: MeetingAudioSource {
    nonisolated let track: MeetingTrack = .them

    private let listenerQueue = DispatchQueue(label: "dev.vatsalsaglani.rafu.meetings.tap.listen")
    private let ioQueue = DispatchQueue(
        label: "dev.vatsalsaglani.rafu.meetings.tap.io", qos: .userInteractive)

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var listeners: [MeetingPropertyListener] = []
    private var pipeline: MeetingTrackPipeline?
    private var drainTask: Task<Void, Never>?
    private var events: AsyncStream<MeetingAudioSourceEvent>.Continuation?
    private var outputFacts: MeetingAudioDeviceFacts?
    private var coreAudio = MeetingCoreAudio(diagnostics: NoopMeetingDiagnostics(), meeting: nil)
    /// Counts runs, so a late listener call cannot end a newer run.
    private var runID = 0

    init() {}

    func start(meeting: MeetingID?, diagnostics: any MeetingDiagnosticsRecording) async throws
        -> MeetingAudioSourceRun
    {
        teardown(reason: nil)
        runID += 1
        let audio = MeetingCoreAudio(diagnostics: diagnostics, meeting: meeting)
        coreAudio = audio

        guard let outputDevice = audio.defaultDevice(input: false) else {
            throw MeetingAudioSourceError.noDevice
        }
        let output = audio.facts(outputDevice, input: false)
        outputFacts = output
        let speakers = audio.isBuiltInSpeakers(outputDevice)

        // 1. The global tap, without this process.
        let own = audio.ownProcessObject().map { [$0] } ?? []
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: own)
        description.name = "Rafu meeting call audio"
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        description.isPrivate = true
        var newTap = AudioObjectID(kAudioObjectUnknown)
        try check(
            .createProcessTap,
            audio.call(.createProcessTap) {
                AudioHardwareCreateProcessTap(description, &newTap)
            })
        tapID = newTap

        do {
            // 2. Its format and UID.
            let (tapFormat, formatStatus) = audio.read(
                tapID, kAudioTapPropertyFormat, as: .readTapFormat,
                initial: AudioStreamBasicDescription())
            try check(.readTapFormat, formatStatus)
            guard let tapUID = audio.readString(tapID, kAudioTapPropertyUID) else {
                throw MeetingAudioSourceError.failed(call: .other, status: -1)
            }

            // 3. The private aggregate device on the default output.
            let outputUID = output.uid.value
            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Rafu meeting call audio",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
                kAudioAggregateDeviceTapListKey: [
                    [kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: tapUID]
                ],
            ]
            var newAggregate = AudioObjectID(kAudioObjectUnknown)
            try check(
                .createAggregateDevice,
                audio.call(.createAggregateDevice) {
                    AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &newAggregate)
                })
            aggregateID = newAggregate

            // 4. The rate rule.
            let (deviceRate, rateStatus) = audio.read(
                aggregateID, kAudioDevicePropertyNominalSampleRate, as: .readNominalSampleRate,
                initial: Float64(0))
            let format = MeetingTapFormat(
                sampleRate: tapFormat.mSampleRate, channelCount: Int(tapFormat.mChannelsPerFrame),
                bitsPerChannel: Int(tapFormat.mBitsPerChannel),
                isInterleaved: tapFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0)
            let rate = MeetingSampleRatePolicy.resolve(
                tapFormat: format, deviceRate: rateStatus == noErr ? deviceRate : nil,
                diagnostics: diagnostics, meeting: meeting
            ).rate
            let layout = MeetingTapLayout(
                channelCount: format.channelCount, isInterleaved: format.isInterleaved,
                isFloat32: tapFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0
                    && tapFormat.mBitsPerChannel == 32,
                sampleRate: rate)

            // 5. The ring, the drain and the IO block.
            let (blocks, blockContinuation) = AsyncStream.makeStream(
                of: MeetingCapturedBlock.self, bufferingPolicy: .bufferingNewest(400))
            let (eventStream, eventContinuation) = AsyncStream.makeStream(
                of: MeetingAudioSourceEvent.self)
            let ring = MeetingCaptureRing()
            let newPipeline = MeetingTrackPipeline(ring: ring, continuation: blockContinuation)
            pipeline = newPipeline
            events = eventContinuation

            let ioBlock = MeetingAudioCallbacks.deviceIOBlock(ring: ring, layout: layout)
            var newProc: AudioDeviceIOProcID?
            try check(
                .createIOProc,
                audio.call(.createIOProc) {
                    AudioDeviceCreateIOProcIDWithBlock(&newProc, aggregateID, ioQueue, ioBlock)
                })
            procID = newProc
            try check(
                .startDevice,
                audio.call(.startDevice) {
                    AudioDeviceStart(aggregateID, newProc)
                })

            // 6. Device changes end the run.
            addListener(MeetingCoreAudio.systemObject, kAudioHardwarePropertyDefaultOutputDevice)
            addListener(aggregateID, kAudioDevicePropertyNominalSampleRate)
            addListener(outputDevice, kAudioDevicePropertyDeviceIsAlive)

            drainTask = Task { await self.drainLoop() }
            return MeetingAudioSourceRun(
                facts: MeetingAudioSourceFacts(
                    device: output, captureSampleRate: rate, outputIsBuiltInSpeakers: speakers),
                blocks: blocks, events: eventStream)
        } catch {
            teardown(reason: nil)
            throw error
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
        teardown(reason: .interrupted(old: outputFacts))
    }

    private func drainLoop() async {
        while !Task.isCancelled {
            pipeline?.drain()
            try? await Task.sleep(for: .milliseconds(50))
        }
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

    /// Built outside the actor: Core Audio calls it on `listenerQueue`.
    private nonisolated static func listenerBlock(source: MeetingSystemAudioSource, run: Int)
        -> MeetingPropertyListener.Block
    {
        { _, _ in Task { await source.interrupt(run: run) } }
    }

    private func check(_ call: MeetingCoreAudioCall, _ status: OSStatus) throws {
        guard status == noErr else {
            throw MeetingAudioSourceError.failed(call: call, status: status)
        }
    }

    /// The measured teardown order: stop, destroy the IO proc, destroy the
    /// aggregate device, destroy the tap. After `AudioDeviceStop` returns,
    /// the IO block does not run again, so the ring can go.
    private func teardown(reason: MeetingAudioSourceEvent?) {
        let audio = coreAudio
        if aggregateID != kAudioObjectUnknown, let procID {
            let stopStatus = AudioDeviceStop(aggregateID, procID)
            audio.call(.stopDevice) { stopStatus }
            let destroyStatus = AudioDeviceDestroyIOProcID(aggregateID, procID)
            audio.call(.destroyIOProc) { destroyStatus }
        }
        procID = nil
        for listener in listeners {
            var address = listener.address
            audio.call(.removePropertyListener) {
                AudioObjectRemovePropertyListenerBlock(
                    listener.object, &address, listenerQueue, listener.block)
            }
        }
        listeners = []
        if aggregateID != kAudioObjectUnknown {
            audio.call(.destroyAggregateDevice) { AudioHardwareDestroyAggregateDevice(aggregateID) }
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            audio.call(.destroyProcessTap) { AudioHardwareDestroyProcessTap(tapID) }
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
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
