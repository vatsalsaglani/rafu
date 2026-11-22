// Diarization error rate: 10 ms frames, miss / false alarm / confusion,
// best speaker mapping (exact, via a bitmask assignment search), collar 0
// and 0.25 s, overlap included. Throw-away spike code; see
// .rafu/plans/meeting-speech-spike.md.
import Foundation

public struct DiarizationErrorResult: Sendable, Equatable {
    public var missSeconds: Double
    public var falseAlarmSeconds: Double
    public var confusionSeconds: Double
    public var totalReferenceSpeakerSeconds: Double
    /// Hypothesis speaker label -> reference speaker label, from the best
    /// one-to-one mapping found.
    public var speakerMapping: [String: String]

    public var missRate: Double { rate(missSeconds) }
    public var falseAlarmRate: Double { rate(falseAlarmSeconds) }
    public var confusionRate: Double { rate(confusionSeconds) }

    /// (miss + false alarm + confusion) / total reference speaker time.
    /// 0.0 when there is no reference speech and no hypothesis speech.
    public var der: Double {
        guard totalReferenceSpeakerSeconds > 0 else {
            return (missSeconds + falseAlarmSeconds + confusionSeconds) == 0 ? 0.0 : 1.0
        }
        return (missSeconds + falseAlarmSeconds + confusionSeconds) / totalReferenceSpeakerSeconds
    }

    private func rate(_ seconds: Double) -> Double {
        guard totalReferenceSpeakerSeconds > 0 else { return seconds == 0 ? 0.0 : 1.0 }
        return seconds / totalReferenceSpeakerSeconds
    }
}

public enum DiarizationScorer {
    /// Scores a hypothesis against a reference.
    ///
    /// - collar: a window, in seconds, around each reference segment's
    ///   start and end edge that is excluded from scoring (the usual
    ///   diarization convention; 0 is strict, 0.25 is common).
    /// - frameDuration: the frame width used for the frame-level accounting.
    public static func score(
        reference: [DiarSegment],
        hypothesis: [DiarSegment],
        collar: Double = 0.0,
        frameDuration: Double = 0.01
    ) -> DiarizationErrorResult {
        let refLabels = Array(Set(reference.map(\.speaker))).sorted()
        let hypLabels = Array(Set(hypothesis.map(\.speaker))).sorted()

        let endTime = max(
            reference.map(\.end).max() ?? 0,
            hypothesis.map(\.end).max() ?? 0
        )
        guard endTime > 0 else {
            return DiarizationErrorResult(
                missSeconds: 0, falseAlarmSeconds: 0, confusionSeconds: 0,
                totalReferenceSpeakerSeconds: 0, speakerMapping: [:]
            )
        }
        let frameCount = Int((endTime / frameDuration).rounded(.up))

        // Collar frames: excluded from scoring entirely.
        var excluded = [Bool](repeating: false, count: frameCount)
        if collar > 0 {
            for seg in reference {
                markCollar(around: seg.start, collar: collar, frameDuration: frameDuration, frameCount: frameCount, in: &excluded)
                markCollar(around: seg.end, collar: collar, frameDuration: frameDuration, frameCount: frameCount, in: &excluded)
            }
        }

        // Active-speaker bitsets per frame, indexed into refLabels / hypLabels.
        var refActive = [[Bool]](repeating: [Bool](repeating: false, count: refLabels.count), count: frameCount)
        var hypActive = [[Bool]](repeating: [Bool](repeating: false, count: hypLabels.count), count: frameCount)
        fill(&refActive, segments: reference, labels: refLabels, frameDuration: frameDuration, frameCount: frameCount)
        fill(&hypActive, segments: hypothesis, labels: hypLabels, frameDuration: frameDuration, frameCount: frameCount)

        // Overlap matrix: total seconds each (ref, hyp) pair is simultaneously active.
        var overlap = [[Double]](repeating: [Double](repeating: 0, count: hypLabels.count), count: refLabels.count)
        for f in 0..<frameCount where !excluded[f] {
            for r in 0..<refLabels.count where refActive[f][r] {
                for h in 0..<hypLabels.count where hypActive[f][h] {
                    overlap[r][h] += frameDuration
                }
            }
        }

        let mapping = bestMapping(overlap: overlap, refLabels: refLabels, hypLabels: hypLabels)
        // mapping[r] = h index, for matched pairs.

        var missSeconds = 0.0
        var falseAlarmSeconds = 0.0
        var confusionSeconds = 0.0
        var totalRefSeconds = 0.0

        for f in 0..<frameCount where !excluded[f] {
            let nRef = refActive[f].filter { $0 }.count
            let nHyp = hypActive[f].filter { $0 }.count
            totalRefSeconds += Double(nRef) * frameDuration

            var correct = 0
            for (r, h) in mapping {
                if refActive[f][r] && hypActive[f][h] { correct += 1 }
            }
            let missed = max(0, nRef - nHyp)
            let falseAlarm = max(0, nHyp - nRef)
            let confusion = min(nRef, nHyp) - correct

            missSeconds += Double(missed) * frameDuration
            falseAlarmSeconds += Double(falseAlarm) * frameDuration
            confusionSeconds += Double(max(0, confusion)) * frameDuration
        }

        var labelMapping: [String: String] = [:]
        for (r, h) in mapping {
            labelMapping[hypLabels[h]] = refLabels[r]
        }

        return DiarizationErrorResult(
            missSeconds: missSeconds,
            falseAlarmSeconds: falseAlarmSeconds,
            confusionSeconds: confusionSeconds,
            totalReferenceSpeakerSeconds: totalRefSeconds,
            speakerMapping: labelMapping
        )
    }

    private static func markCollar(
        around edge: Double, collar: Double, frameDuration: Double, frameCount: Int, in excluded: inout [Bool]
    ) {
        let startFrame = max(0, Int(((edge - collar) / frameDuration).rounded(.down)))
        let endFrame = min(frameCount, Int(((edge + collar) / frameDuration).rounded(.up)))
        guard startFrame < endFrame else { return }
        for f in startFrame..<endFrame { excluded[f] = true }
    }

    private static func fill(
        _ active: inout [[Bool]], segments: [DiarSegment], labels: [String], frameDuration: Double, frameCount: Int
    ) {
        guard !labels.isEmpty else { return }
        let index = Dictionary(uniqueKeysWithValues: labels.enumerated().map { ($1, $0) })
        for seg in segments {
            guard let li = index[seg.speaker] else { continue }
            let startFrame = max(0, Int((seg.start / frameDuration).rounded(.down)))
            let endFrame = min(frameCount, Int((seg.end / frameDuration).rounded(.up)))
            guard startFrame < endFrame else { continue }
            for f in startFrame..<endFrame { active[f][li] = true }
        }
    }

    /// Exact optimal one-to-one assignment of reference speakers to
    /// hypothesis speakers, maximizing total matched overlap seconds, via
    /// a bitmask dynamic program over the hypothesis speakers (at most 8
    /// speakers per the plan's model limit; falls back to a greedy
    /// maximum-overlap match above that, since the bitmask would blow up).
    /// Returns pairs (refIndex, hypIndex).
    static func bestMapping(overlap: [[Double]], refLabels: [String], hypLabels: [String]) -> [(Int, Int)] {
        let nRef = refLabels.count
        let nHyp = hypLabels.count
        guard nRef > 0, nHyp > 0 else { return [] }

        if nHyp > 20 {
            return greedyMapping(overlap: overlap, nRef: nRef, nHyp: nHyp)
        }

        return exactAssignment(overlap: overlap, nRef: nRef, nHyp: nHyp)
    }

    /// Direct bitmask DP for the assignment problem (rows = reference
    /// speakers, columns = hypothesis speakers), with full backtrace.
    /// `best[i][mask]` = best total overlap assigning rows `0..<i` using
    /// exactly the hypothesis speakers in `mask` that were chosen (some
    /// rows may be left unmatched).
    private static func exactAssignment(overlap: [[Double]], nRef: Int, nHyp: Int) -> [(Int, Int)] {
        let fullMask = (1 << nHyp) - 1
        var best = [[Double]](repeating: [Double](repeating: -Double.infinity, count: fullMask + 1), count: nRef + 1)
        best[0][0] = 0

        for i in 0..<nRef {
            for mask in 0...fullMask {
                guard best[i][mask] > -.infinity else { continue }
                let base = best[i][mask]
                // Leave row i unmatched.
                if base > best[i + 1][mask] { best[i + 1][mask] = base }
                // Match row i to each unused hypothesis speaker.
                for h in 0..<nHyp where mask & (1 << h) == 0 {
                    let newMask = mask | (1 << h)
                    let candidate = base + overlap[i][h]
                    if candidate > best[i + 1][newMask] { best[i + 1][newMask] = candidate }
                }
            }
        }

        // Find the best final mask.
        var bestMask = 0
        var bestValue = -Double.infinity
        for mask in 0...fullMask where best[nRef][mask] > bestValue {
            bestValue = best[nRef][mask]
            bestMask = mask
        }

        // Backtrace.
        var pairs: [(Int, Int)] = []
        var mask = bestMask
        for i in stride(from: nRef - 1, through: 0, by: -1) {
            let target = best[i + 1][mask]
            // Row i unmatched case.
            if best[i][mask] == target {
                continue
            }
            // Find which hypothesis speaker was matched.
            for h in 0..<nHyp where mask & (1 << h) != 0 {
                let prevMask = mask & ~(1 << h)
                if best[i][prevMask] + overlap[i][h] == target {
                    pairs.append((i, h))
                    mask = prevMask
                    break
                }
            }
        }
        return pairs
    }

    private static func greedyMapping(overlap: [[Double]], nRef: Int, nHyp: Int) -> [(Int, Int)] {
        var pairs: [(Int, Int)] = []
        var usedRef = Set<Int>()
        var usedHyp = Set<Int>()
        var candidates: [(Double, Int, Int)] = []
        for r in 0..<nRef {
            for h in 0..<nHyp where overlap[r][h] > 0 {
                candidates.append((overlap[r][h], r, h))
            }
        }
        candidates.sort { $0.0 > $1.0 }
        for (_, r, h) in candidates {
            if usedRef.contains(r) || usedHyp.contains(h) { continue }
            usedRef.insert(r)
            usedHyp.insert(h)
            pairs.append((r, h))
        }
        return pairs
    }
}
