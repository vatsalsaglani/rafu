import AppKit
import CoreImage
import Observation
// ScreenCaptureKit's legacy picker objects have no Swift isolation annotation.
// The picker filter is handed to MainActor once and is never mutated by Rafu.
@preconcurrency import ScreenCaptureKit
import SwiftUI
import Synchronization

/// Only a value ticket crosses callback queues. The picker filter never enters
/// this lock. A cancelled owner leaves its request occupied until the SDK replies.
nonisolated final class CanvasCaptureRequestGate: Sendable {
    private let ticket = Mutex<UUID?>(nil)
    func begin() -> UUID? {
        ticket.withLock { value in
            guard value == nil else { return nil }
            let next = UUID()
            value = next
            return next
        }
    }
    func snapshot() -> UUID? { ticket.withLock { $0 } }
    func finish(_ expected: UUID) -> Bool {
        ticket.withLock { value in
            guard value == expected else { return false }
            value = nil
            return true
        }
    }
}

/// One picker observer routes each choice to its explicit pending owner.
/// Captured content and window identities are never written to Canvas records.
final class CanvasCapturePicker: NSObject, SCContentSharingPickerObserver {
    static let shared = CanvasCapturePicker()
    nonisolated private let requests = CanvasCaptureRequestGate()
    private weak var pending: CanvasNativeAppController?
    private var streams: [ObjectIdentifier: CanvasNativeAppController] = [:]
    private override init() {
        super.init()
        SCContentSharingPicker.shared.add(self)
    }

    func choose(for controller: CanvasNativeAppController) {
        guard requests.begin() != nil else {
            controller.status = "Finish the open window picker first"
            return
        }
        pending = controller
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = [.singleWindow]
        configuration.allowsChangingSelectedContent = false
        let picker = SCContentSharingPicker.shared
        picker.defaultConfiguration = configuration
        picker.isActive = true
        picker.present(using: .window)
        controller.status = "Choose one window in the system picker"
    }
    func register(_ stream: SCStream, owner: CanvasNativeAppController) {
        streams[ObjectIdentifier(stream)] = owner
    }
    func remove(_ stream: SCStream) {
        streams[ObjectIdentifier(stream)] = nil
        updateActive()
    }
    func cancel(_ owner: CanvasNativeAppController) {
        if pending === owner { pending = nil }
        updateActive()
    }
    private func updateActive() {
        SCContentSharingPicker.shared.isActive = requests.snapshot() != nil || !streams.isEmpty
    }

    nonisolated func contentSharingPicker(
        _ picker: SCContentSharingPicker, didCancelFor stream: SCStream?
    ) {
        let identity = stream.map(ObjectIdentifier.init)
        let request = requests.snapshot()
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let identity {
                streams[identity]?.stop()
            } else {
                guard let request, requests.finish(request) else { return }
                pending?.status = "Window selection cancelled"
                pending = nil
            }
            updateActive()
        }
    }
    nonisolated func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didUpdateWith filter: SCContentFilter, for stream: SCStream?
    ) {
        if let stream {
            let identity = ObjectIdentifier(stream)
            Task { @MainActor [weak self] in self?.streams[identity]?.stop() }
            return
        }
        // The SDK calls this off main. Keep the exact picker-authorized
        // filter; do not rebuild it through a broader screen inventory.
        // This one legacy SDK handoff relies on the file-scoped compatibility
        // import. Rafu never mutates or shares the filter after this handoff.
        guard let request = requests.snapshot() else { return }
        Task { @MainActor [weak self, filter] in
            guard let self, self.requests.finish(request) else { return }
            let owner = self.pending
            self.pending = nil
            guard filter.style == .window else {
                owner?.status = "Choose one window"
                self.updateActive()
                return
            }
            owner?.start(filter: filter)
            self.updateActive()
        }
    }
    nonisolated func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        guard let request = requests.snapshot() else { return }
        Task { @MainActor [weak self] in
            guard let self, self.requests.finish(request) else { return }
            self.pending?.status = "Window preview is unavailable. You can still open the app."
            self.pending = nil
            self.updateActive()
        }
    }
}

nonisolated private enum CanvasCaptureEvent: Sendable {
    case frame(CGImage)
    case unavailable
}

/// Callback work stays on a serial capture queue. At most one pending frame
/// crosses to MainActor; no Task is made for every captured frame.
nonisolated private final class CanvasCaptureOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    let frames: AsyncStream<CanvasCaptureEvent>.Continuation
    private let context = CIContext(options: [.cacheIntermediates: false])
    init(_ frames: AsyncStream<CanvasCaptureEvent>.Continuation) { self.frames = frames }
    func stream(
        _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen, sampleBuffer.isValid,
            let buffer = sampleBuffer.imageBuffer
        else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
            let code = attachments.first?[.status] as? Int,
            let status = SCFrameStatus(rawValue: code)
        {
            if status == .blank || status == .suspended || status == .stopped {
                frames.yield(.unavailable)
                return
            }
            guard status == .complete else { return }
        }
        let image = CIImage(cvPixelBuffer: buffer)
        if let frame = context.createCGImage(image, from: image.extent) {
            frames.yield(.frame(frame))
        }
    }
    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        frames.yield(.unavailable)
        frames.finish()
    }
}

@Observable
final class CanvasNativeAppController {
    let bundleID: String
    static let referenceStatus = "App reference — no preview"
    var status = CanvasNativeAppController.referenceStatus
    private(set) var frame: CGImage?
    private(set) var isCapturing = false
    @ObservationIgnored private var stream: SCStream?
    @ObservationIgnored private var output: CanvasCaptureOutput?
    @ObservationIgnored private var framesTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var pickerIsPending = false
    @ObservationIgnored var canStart: (() -> Bool)?

    init(bundleID: String) { self.bundleID = bundleID }
    func openApp() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            status = "The app is not installed"
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
    }
    func chooseWindow() {
        guard canStart?() == true else {
            status = "Preview limit reached, or Canvas is hidden"
            return
        }
        stop()
        pickerIsPending = true
        CanvasCapturePicker.shared.choose(for: self)
    }
    func start(filter: SCContentFilter) {
        pickerIsPending = false
        guard canStart?() == true else {
            status = "Canvas is hidden or the preview limit is reached"
            return
        }
        let ticket = UUID()
        generation = ticket
        let pair = AsyncStream<CanvasCaptureEvent>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let output = CanvasCaptureOutput(pair.continuation)
        let configuration = SCStreamConfiguration()
        configuration.width = 960
        configuration.height = 540
        configuration.queueDepth = 3
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 10)
        configuration.capturesAudio = false
        configuration.showsCursor = false
        let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        do {
            try stream.addStreamOutput(
                output, type: .screen,
                sampleHandlerQueue: DispatchQueue(label: "dev.rafu.canvas.capture", qos: .utility))
            self.stream = stream
            self.output = output
            isCapturing = true
            CanvasCapturePicker.shared.register(stream, owner: self)
            framesTask = Task { [weak self] in
                for await event in pair.stream {
                    guard let self, generation == ticket, !Task.isCancelled else { return }
                    switch event {
                    case .frame(let image): frame = image
                    case .unavailable:
                        stop()
                        status = "The window preview is unavailable"
                        return
                    }
                }
            }
            Task { [weak self] in
                do {
                    try await stream.startCapture()
                    guard let self, generation == ticket else {
                        try? await stream.stopCapture()
                        return
                    }
                    status = "Live preview — input stays in the app"
                } catch {
                    guard let self, generation == ticket else { return }
                    stop()
                    status = "Preview access was denied or the window is unavailable"
                }
            }
        } catch {
            if generation == ticket {
                stop()
                status = "Preview access was denied or the window is unavailable"
            }
        }
    }
    func stop() {
        generation = UUID()
        if pickerIsPending || stream != nil { CanvasCapturePicker.shared.cancel(self) }
        pickerIsPending = false
        framesTask?.cancel()
        framesTask = nil
        output?.frames.finish()
        output = nil
        if let stream {
            CanvasCapturePicker.shared.remove(stream)
            Task { try? await stream.stopCapture() }
        }
        stream = nil
        frame = nil
        isCapturing = false
        status = "Paused — choose a window to resume"
    }
}

struct CanvasNativeAppCard: View {
    @Environment(\.rafuTheme) private var theme
    let card: CanvasCard
    let board: CanvasBoardState
    let session: WorkspaceSession
    @State private var controller: CanvasNativeAppController?
    @State private var visibilityOwner = UUID()
    @State private var appIcon: NSImage?
    @State private var showsPictureNote = false

    var body: some View {
        Group {
            if let controller {
                if let frame = controller.frame {
                    picture(frame, controller: controller)
                } else {
                    reference(controller)
                }
            } else {
                Text("Preparing app reference…").foregroundStyle(theme.palette.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            guard let resources = session.canvasResources[board.id],
                resources.board === board
            else { return }
            controller = resources.nativeApp(for: card)
            resources.showNative(card.id, owner: visibilityOwner)
            if case .nativeApp(let bundleID) = card.content,
                let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            {
                appIcon = NSWorkspace.shared.icon(forFile: url.path)
            }
        }
        .onDisappear {
            session.canvasResources[board.id]?.hideNative(card.id, owner: visibilityOwner)
        }
    }

    /// The app is a separate process. Its body is an icon, its name, and the
    /// two ways to use it (review C8).
    private func reference(_ controller: CanvasNativeAppController) -> some View {
        VStack(spacing: 10) {
            Group {
                if let appIcon {
                    Image(nsImage: appIcon).resizable().scaledToFit()
                } else {
                    Image(systemName: "macwindow").resizable().scaledToFit()
                        .foregroundStyle(theme.palette.textSecondary)
                }
            }
            .frame(width: 48, height: 48)
            .accessibilityHidden(true)
            Text(card.title).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.palette.textPrimary).lineLimit(1)
            Button("Open \(card.title)") { controller.openApp() }
                .buttonStyle(RafuProminentButtonStyle())
            if controller.isCapturing {
                Button("Stop Window Preview") { controller.stop() }
                    .buttonStyle(RafuSecondaryButtonStyle(compact: true))
            } else {
                Button("Show Window Preview…") { controller.chooseWindow() }
                    .buttonStyle(RafuSecondaryButtonStyle(compact: true))
            }
            if controller.status != CanvasNativeAppController.referenceStatus {
                Text(controller.status).font(.system(size: 11))
                    .foregroundStyle(theme.palette.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(12)
    }

    /// A picture never looks interactive: no text cursor, no hover highlight.
    /// A click selects the card and explains where input goes.
    private func picture(_ frame: CGImage, controller: CanvasNativeAppController) -> some View {
        Image(decorative: frame, scale: 1).resizable().scaledToFit()
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(.rect)
            .onTapGesture {
                board.backToBoard()
                board.select([card.id])
                showsPictureNote = true
            }
            .popover(isPresented: $showsPictureNote) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(CanvasCardPresentation.previewCaption(appName: card.title))
                        .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    Button("Open \(card.title)") {
                        showsPictureNote = false
                        controller.openApp()
                    }
                    .buttonStyle(RafuProminentButtonStyle(compact: true))
                }
                .padding(14).frame(width: 260)
            }
            .accessibilityLabel("Picture of a \(card.title) window")
            .accessibilityHint("Input goes to \(card.title), not to this picture.")
    }
}
