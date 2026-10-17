import AppKit
import CoreMedia
import ScreenCaptureKit
import Testing
import WebKit

@testable import RafuApp

@Suite("Canvas native boundary probes")
@MainActor
struct CanvasFeasibilityTests {
    @Test("A native terminal can transfer windows without replacing its parser or input policy")
    func terminalTransfer() {
        _ = NSApplication.shared
        let first = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        let second = NSWindow(
            contentRect: first.frame, styleMask: [.titled],
            backing: .buffered, defer: false)
        first.isReleasedWhenClosed = false
        second.isReleasedWhenClosed = false
        defer {
            first.close()
            second.close()
        }
        let originalRegistrations = TerminalNewlineMonitor.registrationCount
        let view = RafuTerminalView(frame: first.contentView!.bounds)
        let parser = view.getTerminal()
        view.feed(text: "\u{1b}[>1u")
        first.contentView?.addSubview(view)
        #expect(view.window === first)
        #expect(TerminalNewlineMonitor.registrationCount == originalRegistrations + 1)
        first.makeFirstResponder(nil)
        view.removeFromSuperview()
        second.contentView?.addSubview(view)
        #expect(view.window === second)
        #expect(view.getTerminal() === parser)
        #expect(!view.getTerminal().keyboardEnhancementFlags.isEmpty)
        #expect(TerminalNewlineMonitor.registrationCount == originalRegistrations + 1)
        view.removeFromSuperview()
        #expect(TerminalNewlineMonitor.registrationCount == originalRegistrations)
    }

    @Test("Public capture settings permit a bounded single-window preview without starting capture")
    func captureConfiguration() {
        var picker = SCContentSharingPickerConfiguration()
        picker.allowedPickerModes = [.singleWindow]
        picker.allowsChangingSelectedContent = false
        #expect(picker.allowedPickerModes == [.singleWindow])
        let stream = SCStreamConfiguration()
        stream.width = 960
        stream.height = 540
        stream.queueDepth = 3
        stream.minimumFrameInterval = CMTime(value: 1, timescale: 10)
        stream.capturesAudio = false
        #expect(stream.width == 960 && stream.height == 540)
        #expect(stream.queueDepth == 3 && !stream.capturesAudio)
    }

    @Test("A local app can use isolated nonpersistent web storage without a document web view")
    func webConfiguration() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.mediaTypesRequiringUserActionForPlayback = .all
        #expect(!config.websiteDataStore.isPersistent)
        #expect(!config.preferences.javaScriptCanOpenWindowsAutomatically)
        #expect(config.mediaTypesRequiringUserActionForPlayback == .all)
    }
}
