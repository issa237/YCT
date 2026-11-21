import Foundation

struct HighlightDetectionResult {
    let clips: [HighlightClipItem]
    let source: DetectionSource
    let timelineScores: [Double] // 1-second buckets normalized 0...1
}

enum HighlightDetector {

    /// Detects the top `clipDurations.count` high-moment windows in a video.
    static func detectHighlights(
        totalDuration: Double,
        clipDurations: [Double],
        heatmap: [HeatmapPoint]?,
        audioEnergy: [Double]?,
        chapters: [VideoChapter]?
    ) -> HighlightDetectionResult {
        let safeTotal = max(1.0, totalDuration)
        let numSeconds = max(1, Int(ceil(safeTotal)))
        let count = clipDurations.count
        guard count > 0 else {
            return HighlightDetectionResult(clips: [], source: .youtubeHeatmap, timelineScores: [])
        }

        // 1. Construct 1-second resolution excitement timeline [0.0 ... 1.0]
        var timeline = [Double](repeating: 0.1, count: numSeconds)
        var detectedSource: DetectionSource = .youtubeHeatmap

        let hasValidHeatmap: Bool = {
            guard let hm = heatmap, !hm.isEmpty else { return false }
            let maxVal = hm.map(\.value).max() ?? 0
            return maxVal > 0.001
        }()

        let hasValidAudio: Bool = {
            guard let ae = audioEnergy, !ae.isEmpty else { return false }
            let maxVal = ae.max() ?? 0
            return maxVal > 0.0001
        }()

        if hasValidHeatmap, let hm = heatmap {
            var raw = [Double](repeating: 0.0, count: numSeconds)
            for pt in hm {
                let s = max(0, min(numSeconds - 1, Int(floor(pt.start_time))))
                let e = max(s, min(numSeconds - 1, Int(ceil(pt.end_time))))
                for sec in s...e {
                    raw[sec] = max(raw[sec], pt.value)
                }
            }
            let normalizedHeatmap = normalize(raw)
            if hasValidAudio, let ae = audioEnergy {
                let normAudio = normalize(computeExcitementCurve(from: ae, targetCount: numSeconds))
                for i in 0..<numSeconds {
                    timeline[i] = 0.75 * normalizedHeatmap[i] + 0.25 * normAudio[i]
                }
            } else {
                timeline = normalizedHeatmap
            }
            timeline = normalize(smooth(timeline, radius: 2))
            detectedSource = .youtubeHeatmap
        } else if hasValidAudio, let ae = audioEnergy {
            let excitement = computeExcitementCurve(from: ae, targetCount: numSeconds)
            timeline = normalize(smooth(excitement, radius: 2))
            detectedSource = (chapters?.isEmpty == false) ? .chaptersAndEnergy : .audioEnergy
        } else {
            // Synthetic fallback curve using chapters or golden-ratio peaks if neither heatmap nor audio is loaded yet
            var raw = [Double](repeating: 0.3, count: numSeconds)
            if let chs = chapters, !chs.isEmpty {
                for ch in chs {
                    if let st = ch.start_time {
                        let center = min(numSeconds - 1, max(0, Int(st) + 10))
                        for offset in -15...15 {
                            let idx = center + offset
                            if idx >= 0 && idx < numSeconds {
                                let weight = 1.0 - (Double(abs(offset)) / 16.0)
                                raw[idx] = max(raw[idx], 0.5 + 0.5 * weight)
                            }
                        }
                    }
                }
                detectedSource = .chaptersAndEnergy
            } else {
                for i in 0..<numSeconds {
                    let pos = Double(i) / Double(max(1, numSeconds - 1))
                    let edgeFade = (pos < 0.04 || pos > 0.94) ? 0.4 : 1.0
                    let wave = 0.5 + 0.5 * sin(pos * Double(count + 1) * .pi * 1.7)
                    raw[i] = edgeFade * wave
                }
                detectedSource = .audioEnergy
            }
            timeline = normalize(raw)
        }

        // 2. Calculate how much guard separation we can afford between clips
        let sumDurations = clipDurations.reduce(0, +)
        let availableSlack = max(0.0, safeTotal - sumDurations)
        let idealGap = min(15.0, availableSlack / Double(max(1, count * 2)))

        // Prefix sum for O(1) window average lookup
        var prefix = [Double](repeating: 0.0, count: numSeconds + 1)
        for i in 0..<numSeconds {
            prefix[i + 1] = prefix[i] + timeline[i]
        }

        func windowMean(start: Int, length: Int) -> Double {
            guard length > 0 else { return 0 }
            let s = max(0, min(numSeconds - 1, start))
            let e = max(s + 1, min(numSeconds, s + length))
            return (prefix[e] - prefix[s]) / Double(e - s)
        }

        func windowCenterPeak(start: Int, length: Int) -> Double {
            let s = max(0, min(numSeconds - 1, start))
            let e = max(s + 1, min(numSeconds, s + length))
            let span = e - s
            let cStart = s + Int(Double(span) * 0.2)
            let cEnd = max(cStart + 1, s + Int(Double(span) * 0.8))
            var peak = 0.0
            for idx in cStart..<min(numSeconds, cEnd) {
                if timeline[idx] > peak {
                    peak = timeline[idx]
                }
            }
            return peak
        }

        struct SelectedInterval {
            let requestIndex: Int
            let startTime: Double
            let duration: Double
            let score: Double
        }

        var selected: [SelectedInterval] = []

        func overlaps(_ startA: Double, _ durA: Double, gap: Double) -> Bool {
            let endA = startA + durA
            for item in selected {
                let startB = item.startTime - gap
                let endB = item.startTime + item.duration + gap
                if startA < endB && endA > startB {
                    return true
                }
            }
            return false
        }

        // 3. Greedily pick top non-overlapping window for each requested clip
        for reqIdx in 0..<count {
            let rawDur = max(3.0, clipDurations[reqIdx])
            let dur = min(rawDur, safeTotal)
            let durInt = max(1, Int(round(dur)))
            let maxStartSec = max(0, numSeconds - durInt)

            var bestStart: Int? = nil
            var bestScore: Double = -1.0

            // Try with idealGap first, then 0 gap if video is tightly packed
            for gapToUse in [idealGap, 0.0] {
                for candidateStart in 0...maxStartSec {
                    let candidateTime = Double(candidateStart)
                    if overlaps(candidateTime, dur, gap: gapToUse) {
                        continue
                    }
                    let meanVal = windowMean(start: candidateStart, length: durInt)
                    let centerPeak = windowCenterPeak(start: candidateStart, length: durInt)

                    // Slight penalty for extreme start/end edges (first 3s / last 4s) on videos > 60s
                    var edgeWeight = 1.0
                    if safeTotal > 60 {
                        if candidateTime < 3.0 || (candidateTime + dur) > (safeTotal - 4.0) {
                            edgeWeight = 0.88
                        }
                    }

                    let combined = (0.58 * centerPeak + 0.42 * meanVal) * edgeWeight
                    if combined > bestScore {
                        bestScore = combined
                        bestStart = candidateStart
                    }
                }
                if bestStart != nil {
                    break
                }
            }

            // Fallback if total requested durations exceed total video duration
            let finalStart: Double
            let finalScore: Double
            if let bs = bestStart {
                finalStart = Double(bs)
                finalScore = max(0.15, min(1.0, bestScore))
            } else {
                let step = max(0.0, (safeTotal - dur) / Double(max(1, count - 1)))
                finalStart = min(max(0.0, safeTotal - dur), Double(reqIdx) * step)
                let sInt = max(0, min(numSeconds - 1, Int(finalStart)))
                finalScore = max(0.15, min(1.0, windowMean(start: sInt, length: durInt)))
            }

            selected.append(
                SelectedInterval(
                    requestIndex: reqIdx,
                    startTime: finalStart,
                    duration: dur,
                    score: finalScore
                )
            )
        }

        // If all requested durations are identical, sort chronologically for intuitive viewing
        let isUniformDuration = Set(clipDurations.map { Int($0.rounded()) }).count <= 1
        let ordered: [SelectedInterval]
        if isUniformDuration {
            ordered = selected.sorted { $0.startTime < $1.startTime }
        } else {
            ordered = selected.sorted { $0.requestIndex < $1.requestIndex }
        }

        // Build final HighlightClipItem array with chapter labels if present
        let clips: [HighlightClipItem] = ordered.enumerated().map { (idx, item) in
            let midPoint = item.startTime + item.duration / 2.0
            let chapterTitle = chapters?.first(where: { ch in
                guard let s = ch.start_time, let e = ch.end_time else { return false }
                return midPoint >= s && midPoint <= e
            })?.title

            let baseReason: String
            switch detectedSource {
            case .youtubeHeatmap:
                baseReason = "Most Replayed Peak"
            case .audioEnergy:
                baseReason = "High Audio Energy Peak"
            case .chaptersAndEnergy:
                baseReason = "Highlight Peak"
            }

            let reason: String
            if let chTitle = chapterTitle, !chTitle.isEmpty {
                reason = "\(baseReason) • \(chTitle)"
            } else {
                reason = baseReason
            }

            return HighlightClipItem(
                id: UUID(),
                index: idx + 1,
                startTime: item.startTime,
                duration: item.duration,
                score: item.score,
                reason: reason,
                status: .pending
            )
        }

        return HighlightDetectionResult(
            clips: clips,
            source: detectedSource,
            timelineScores: timeline
        )
    }

    // MARK: - Audio Energy Processing

    /// Extracts 1-second RMS energy buckets from a raw 1000Hz Float32 PCM stream.
    static func parsePCMFloat32ToSecondsRMS(data: Data, sampleRate: Int = 1000) -> [Double] {
        let floatSize = MemoryLayout<Float>.size
        let totalFloats = data.count / floatSize
        guard totalFloats > 0, sampleRate > 0 else { return [] }

        let numSeconds = max(1, (totalFloats + sampleRate - 1) / sampleRate)
        var rmsPerSecond = [Double](repeating: 0.0, count: numSeconds)

        data.withUnsafeBytes { rawBuffer in
            guard let floatPtr = rawBuffer.bindMemory(to: Float.self).baseAddress else { return }
            for sec in 0..<numSeconds {
                let startSample = sec * sampleRate
                let endSample = min(totalFloats, startSample + sampleRate)
                let count = endSample - startSample
                if count <= 0 { continue }

                var sumSq: Double = 0.0
                for i in startSample..<endSample {
                    let sample = Double(floatPtr[i])
                    if sample.isFinite {
                        sumSq += sample * sample
                    }
                }
                rmsPerSecond[sec] = sqrt(sumSq / Double(count))
            }
        }
        return rmsPerSecond
    }

    /// Combines absolute loudness and local dynamic surge so exciting moments stand out.
    private static func computeExcitementCurve(from rms: [Double], targetCount: Int) -> [Double] {
        guard !rms.isEmpty else { return [Double](repeating: 0.1, count: targetCount) }

        var resampled = [Double](repeating: 0.0, count: targetCount)
        for i in 0..<targetCount {
            let srcIdx = min(rms.count - 1, Int((Double(i) / Double(max(1, targetCount))) * Double(rms.count)))
            resampled[i] = rms[srcIdx]
        }

        let normRMS = normalize(resampled)
        let localBaseline = smooth(normRMS, radius: 15)

        var excitement = [Double](repeating: 0.0, count: targetCount)
        for i in 0..<targetCount {
            let surge = max(0.0, normRMS[i] - localBaseline[i])
            excitement[i] = 0.65 * normRMS[i] + 0.35 * surge
        }
        return normalize(excitement)
    }

    private static func smooth(_ values: [Double], radius: Int) -> [Double] {
        guard values.count > 1, radius > 0 else { return values }
        let n = values.count
        var result = [Double](repeating: 0.0, count: n)
        for i in 0..<n {
            var sum = 0.0
            var weightSum = 0.0
            let low = max(0, i - radius)
            let high = min(n - 1, i + radius)
            for j in low...high {
                let dist = abs(i - j)
                let w = Double(radius + 1 - dist)
                sum += values[j] * w
                weightSum += w
            }
            result[i] = weightSum > 0 ? (sum / weightSum) : values[i]
        }
        return result
    }

    private static func normalize(_ values: [Double]) -> [Double] {
        guard let minVal = values.min(), let maxVal = values.max() else { return values }
        let span = maxVal - minVal
        guard span > 1e-9 else {
            return [Double](repeating: 0.5, count: values.count)
        }
        return values.map { ($0 - minVal) / span }
    }
}
