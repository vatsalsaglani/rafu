import Foundation
import Testing

@testable import RafuApp

@Test("A plain path round-trips through fileURI and filePath")
func plainPathRoundTrips() {
    let path = "/Users/rafu/Projects/App/Sources/main.swift"
    let uri = fileURI(forPath: path)
    #expect(uri.hasPrefix("file://"))
    #expect(filePath(forURI: uri) == path)
}

@Test("A path containing spaces round-trips")
func spacedPathRoundTrips() {
    let path = "/Users/rafu/My Projects/App Name/main.swift"
    let uri = fileURI(forPath: path)
    #expect(filePath(forURI: uri) == path)
}

@Test("A path containing non-ASCII characters round-trips")
func nonASCIIPathRoundTrips() {
    let path = "/Users/rafu/Projets/Café ☕️/naïve.swift"
    let uri = fileURI(forPath: path)
    #expect(filePath(forURI: uri) == path)
}

@Test("filePath declines a non-file-scheme URI")
func filePathDeclinesNonFileScheme() {
    #expect(filePath(forURI: "https://example.com/a.swift") == nil)
}

@Test("filePath declines a malformed URI string")
func filePathDeclinesMalformedURI() {
    #expect(filePath(forURI: "") == nil)
}
