import Foundation
import Testing

@testable import RafuApp

@Test("nil bytes render as an em dash")
func resourceMemoryFormatRendersNilAsEmDash() {
    #expect(ResourceMemoryFormat.label(nil) == "—")
}

@Test("zero bytes render as 0.0 MB")
func resourceMemoryFormatRendersZeroBytes() {
    #expect(ResourceMemoryFormat.label(0) == "0.0 MB")
}

@Test("sub-gigabyte byte counts render as MB with one decimal place")
func resourceMemoryFormatRendersMegabytes() {
    #expect(ResourceMemoryFormat.label(149_000_000) == "142.1 MB")
}

@Test("gigabyte-scale byte counts render as GB with one decimal place")
func resourceMemoryFormatRendersGigabytes() {
    let bytes = UInt64(1.5 * 1024 * 1024 * 1024)
    #expect(ResourceMemoryFormat.label(bytes) == "1.5 GB")
}

@Test("exactly one gibibyte renders as GB, not MB")
func resourceMemoryFormatRendersGigabyteBoundary() {
    let bytes = UInt64(1024) * 1024 * 1024
    #expect(ResourceMemoryFormat.label(bytes) == "1.0 GB")
}
