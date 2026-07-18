import Foundation
import Testing

@testable import RafuApp

/// `base` mirrors `MarkdownPreviewView.documentDirectory`: the directory a
/// Markdown document lives in, used as both `baseURL` and `imageBaseURL`.
private let documentBase = URL(fileURLWithPath: "/Users/test/notes/README.md")
    .deletingLastPathComponent()

@Test("A relative path resolves against the document directory as local")
func resolvesRelativePathAsLocal() {
    let reference = MarkdownImageReference.resolve(
        source: "images/pic.png", relativeTo: documentBase)
    #expect(
        reference
            == .local(URL(fileURLWithPath: "/Users/test/notes/images/pic.png")))
}

@Test("An absolute filesystem path resolves against a file:// base as local")
func resolvesAbsolutePathAsLocal() {
    let reference = MarkdownImageReference.resolve(source: "/abs/x.png", relativeTo: documentBase)
    #expect(reference == .local(URL(fileURLWithPath: "/abs/x.png")))
}

@Test("An explicit file:// URL resolves as local")
func resolvesExplicitFileURLAsLocal() {
    let reference = MarkdownImageReference.resolve(
        source: "file:///abs/x.png", relativeTo: documentBase)
    #expect(reference == .local(URL(fileURLWithPath: "/abs/x.png")))
}

@Test("An http URL resolves as remote")
func resolvesHTTPAsRemote() {
    let reference = MarkdownImageReference.resolve(
        source: "http://example.com/x.png", relativeTo: documentBase)
    #expect(reference == .remote(URL(string: "http://example.com/x.png")!))
}

@Test("An https URL resolves as remote")
func resolvesHTTPSAsRemote() {
    let reference = MarkdownImageReference.resolve(
        source: "https://example.com/x.png", relativeTo: documentBase)
    #expect(reference == .remote(URL(string: "https://example.com/x.png")!))
}

@Test("An empty source fails to resolve to any URL and classifies as invalid")
func emptySourceIsInvalid() {
    let reference = MarkdownImageReference.resolve(source: "", relativeTo: documentBase)
    #expect(reference == .invalid)
}

@Test("A data: URI is neither a file nor an http(s) URL and classifies as invalid")
func dataURIIsInvalid() {
    let reference = MarkdownImageReference.resolve(
        source: "data:image/png;base64,abcd", relativeTo: documentBase)
    #expect(reference == .invalid)
}

@Test("A path with an unescaped space never crashes resolution")
func unescapedSpacePathNeverCrashes() {
    // `URL(string:relativeTo:)` on the pinned Swift 6.2 toolchain
    // percent-encodes an unescaped space rather than failing to parse, so
    // this resolves cleanly to a local file URL. The behavior this test
    // guards is "never crashes" — whichever classification the platform
    // produces, `resolve` must return a value, never trap.
    let reference = MarkdownImageReference.resolve(
        source: "pic with space.png", relativeTo: documentBase)
    #expect(
        reference
            == .local(URL(fileURLWithPath: "/Users/test/notes/pic with space.png")))
}
