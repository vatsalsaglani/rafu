import Testing

@testable import RafuApp

@Suite("Memory settling")
struct MemorySettlingTests {
    private func settling(_ values: [UInt64]) -> MemorySettling {
        var settling = MemorySettling()
        for value in values { settling.append(value) }
        return settling
    }

    @Test("The median of odd and even counts")
    func median() {
        #expect(MemorySettling.median([]) == nil)
        #expect(MemorySettling.median([5, 1, 3]) == 3)
        #expect(MemorySettling.median([4, 1, 3, 2]) == 2)
        #expect(MemorySettling.median([10, 20]) == 15)
    }

    @Test("With fewer than six samples, settled is the live value")
    func settledBeforeWindow() {
        let early = settling([100, 500, 200])
        #expect(early.live == 200)
        #expect(early.settled == 200)
        #expect(MemorySettling().settled == nil)
    }

    @Test("A single spike does not move the settled value; peak keeps it")
    func spike() {
        let spiked = settling([200, 200, 900, 200, 200, 200])
        #expect(spiked.settled == 200)
        #expect(spiked.live == 200)
        #expect(spiked.peak == 900)
    }

    @Test("The ring keeps 24 samples")
    func ringCap() {
        let full = settling(Array(1...30).map { UInt64($0) })
        #expect(full.samples.count == MemorySettling.trendWindow)
        #expect(full.samples.first == 7)
        #expect(full.peak == 30)
    }

    @Test("The trend is up only for a climb above 15 % on a full ring")
    func trend() {
        let flatPartial = settling(
            Array(repeating: 100, count: 6) + Array(repeating: 200, count: 6))
        #expect(flatPartial.trend == .flat)
        let climb = settling(Array(repeating: 100, count: 18) + Array(repeating: 120, count: 6))
        #expect(climb.trend == .up)
        let small = settling(Array(repeating: 100, count: 18) + Array(repeating: 110, count: 6))
        #expect(small.trend == .flat)
        let drop = settling(Array(repeating: 200, count: 18) + Array(repeating: 100, count: 6))
        #expect(drop.trend == .down)
    }

    @Test("The chip shows the settled value and the tooltip all three")
    func chip() {
        let mebibyte: UInt64 = 1_024 * 1_024
        let value = settling([100, 100, 300, 100, 100, 100].map { $0 * mebibyte })
        #expect(MemoryChipPresentation.label(value, live: 100 * mebibyte) == "100.0 MB")
        #expect(
            MemoryChipPresentation.values(value, live: 100 * mebibyte)
                == "Live 100.0 MB · Peak 300.0 MB · Settled 100.0 MB (median of 30 s).")
        #expect(MemoryChipPresentation.trendSymbol(.flat) == nil)
        #expect(MemoryChipPresentation.trendSymbol(.up) == "arrow.up.right")
    }
}
