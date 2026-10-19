import Foundation
import Testing

@testable import RafuApp

@Test("ProcessMemorySampler: this process reports a footprint, and the shown figure is it")
func processMemorySamplerReportsFootprint() throws {
    let sample = try #require(ProcessMemorySampler().sample())
    let footprint = try #require(sample.footprintBytes)
    #expect(footprint > 0)
    #expect(sample.residentBytes > 0)
    #expect(sample.displayBytes == footprint)
}

@Test("ProcessMemorySample.displayBytes: falls back to resident size without a footprint")
func processMemorySampleFallsBackToResident() {
    let sample = ProcessMemorySample(residentBytes: 42, footprintBytes: nil, sampledAt: Date())
    #expect(sample.displayBytes == 42)
}
