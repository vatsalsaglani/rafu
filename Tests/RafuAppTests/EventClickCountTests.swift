import AppKit
import Foundation
import Testing

@testable import RafuApp

/// Regression for the Ensemble freeze on a touch screen (macOS 27.2,
/// 2026-11-19): a tap on a card header ended a SwiftUI gesture inside a
/// direct-touch event, `finishClick` read `NSApp.currentEvent?.clickCount`,
/// AppKit raised `NSInternalInconsistencyException`, and the window stopped
/// updating. A call below that reached `-[NSEvent clickCount]` for a
/// non-mouse event would raise and stop this test process, so the test
/// passes only when the type check comes first.
@Suite("Event click count")
@MainActor
struct EventClickCountTests {
    /// The event types whose click count AppKit answers, read from
    /// `-[NSEvent clickCount]` in AppKit on macOS 27.2: types 1 to 7, 25 to
    /// 27, and 40 (mouse cancelled). Direct touch (37) is not in it.
    private static let appKitClickCountMask: UInt64 = 0x0100_0E00_00FE

    @Test("Only mouse button, move and drag events carry a click count")
    func typeTable() {
        for type: NSEvent.EventType in [
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .mouseMoved,
            .leftMouseDragged, .rightMouseDragged, .otherMouseDown, .otherMouseUp,
            .otherMouseDragged,
        ] {
            #expect(EventClickCount.carriesClickCount(type), "\(type.rawValue)")
        }
        for type: NSEvent.EventType in [
            .directTouch, .keyDown, .keyUp, .flagsChanged, .scrollWheel, .magnify, .rotate,
            .gesture, .swipe, .smartMagnify, .pressure, .mouseEntered, .mouseExited,
            .cursorUpdate, .appKitDefined, .systemDefined, .applicationDefined, .periodic,
            .tabletPoint, .tabletProximity, .quickLook, .changeMode,
        ] {
            #expect(!EventClickCount.carriesClickCount(type), "\(type.rawValue)")
        }
    }

    @Test("Every type the helper reads is one AppKit answers")
    func subsetOfAppKitTypes() {
        for raw in UInt(0)...63 {
            guard let type = NSEvent.EventType(rawValue: raw),
                EventClickCount.carriesClickCount(type)
            else { continue }
            #expect(Self.appKitClickCountMask & (1 << UInt64(raw)) != 0, "\(raw)")
        }
        #expect(Self.appKitClickCountMask & (1 << 37) == 0)
    }

    @Test("A missing event counts as one click")
    func missingEvent() {
        #expect(EventClickCount.of(nil) == 1)
    }

    @Test("A key, scroll or app-defined event counts as one click and never raises")
    func nonMouseEventsDoNotRaise() throws {
        let key = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
                windowNumber: 0, context: nil, characters: " ",
                charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        #expect(EventClickCount.of(key) == 1)

        let defined = try #require(
            NSEvent.otherEvent(
                with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 1,
                windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0))
        #expect(EventClickCount.of(defined) == 1)

        let wheel = try #require(
            CGEvent(
                scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 3,
                wheel2: 0, wheel3: 0))
        let scroll = try #require(NSEvent(cgEvent: wheel))
        #expect(scroll.type == .scrollWheel)
        #expect(EventClickCount.of(scroll) == 1)
    }

    @Test("A mouse event keeps its click count")
    func mouseEventsKeepTheirCount() throws {
        for clicks in [1, 2, 3] {
            let event = try #require(
                NSEvent.mouseEvent(
                    with: .leftMouseUp, location: NSPoint(x: 10, y: 10), modifierFlags: [],
                    timestamp: 1, windowNumber: 0, context: nil, eventNumber: 0,
                    clickCount: clicks, pressure: 0))
            #expect(EventClickCount.of(event) == clicks)
        }
    }

    @Test("No source reads clickCount from the current event directly")
    func noUncheckedCurrentEventClickCount() throws {
        let sources = try Self.repositoryRoot().appending(
            path: "Sources/RafuApp", directoryHint: .isDirectory)
        let enumerator = try #require(FileManager.default.enumerator(atPath: sources.path))
        var offenders: [String] = []
        for case let relative as String in enumerator where relative.hasSuffix(".swift") {
            let text = try String(contentsOf: sources.appending(path: relative), encoding: .utf8)
            if text.contains("currentEvent?.clickCount") || text.contains("currentEvent.clickCount")
                || text.contains("currentEvent!.clickCount")
            {
                offenders.append(relative)
            }
        }
        #expect(offenders.isEmpty, "\(offenders)")
    }

    private static func repositoryRoot(file: StaticString = #filePath) throws -> URL {
        var directory = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        while directory.path != "/" {
            if FileManager.default.fileExists(
                atPath: directory.appending(path: "Package.swift").path)
            {
                return directory
            }
            directory = directory.deletingLastPathComponent()
        }
        throw RootLookupError.notFound
    }

    private enum RootLookupError: Error {
        case notFound
    }
}
