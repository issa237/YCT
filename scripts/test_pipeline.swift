import Foundation

// Unit & integration test for HighlightDetector and TimeFormatter
func runTests() {
    print("Running YCT HighlightDetector tests...")

    // 1. Test YouTube Heatmap Peak Detection
    let sampleHeatmap: [HeatmapPoint] = [
        HeatmapPoint(start_time: 0, end_time: 30, value: 0.15),
        HeatmapPoint(start_time: 30, end_time: 60, value: 0.95),  // Peak #1 around 30..60
        HeatmapPoint(start_time: 60, end_time: 120, value: 0.20),
        HeatmapPoint(start_time: 120, end_time: 150, value: 0.88), // Peak #2 around 120..150
        HeatmapPoint(start_time: 150, end_time: 210, value: 0.10),
        HeatmapPoint(start_time: 210, end_time: 240, value: 0.99), // Peak #3 around 210..240
        HeatmapPoint(start_time: 240, end_time: 300, value: 0.12)
    ]

    let result = HighlightDetector.detectHighlights(
        totalDuration: 300.0,
        clipDurations: [20.0, 20.0, 20.0],
        heatmap: sampleHeatmap,
        audioEnergy: nil,
        chapters: [
            VideoChapter(start_time: 0, end_time: 100, title: "Intro & First Action"),
            VideoChapter(start_time: 100, end_time: 200, title: "Midgame Clash"),
            VideoChapter(start_time: 200, end_time: 300, title: "Grand Finale")
        ]
    )

    assert(result.clips.count == 3, "Expected 3 clips, got \(result.clips.count)")
    assert(result.source == .youtubeHeatmap, "Expected youtubeHeatmap source")

    for clip in result.clips {
        print("  Clip #\(clip.index): \(clip.formattedTimeRange) (\(Int(clip.duration))s) | Score: \(clip.scorePercentage)% | \(clip.reason)")
    }

    // Verify no overlap between clips
    for i in 0..<result.clips.count {
        for j in (i + 1)..<result.clips.count {
            let a = result.clips[i]
            let b = result.clips[j]
            let overlaps = (a.startTime < b.endTime) && (a.endTime > b.startTime)
            assert(!overlaps, "Clips \(a.index) and \(b.index) should not overlap!")
        }
    }

    // 2. Test Custom Per-Clip Durations (e.g., 15s, 30s, 45s)
    let customResult = HighlightDetector.detectHighlights(
        totalDuration: 300.0,
        clipDurations: [15.0, 30.0, 45.0],
        heatmap: sampleHeatmap,
        audioEnergy: nil,
        chapters: nil
    )
    assert(customResult.clips.count == 3)
    assert(Int(customResult.clips[0].duration) == 15)
    assert(Int(customResult.clips[1].duration) == 30)
    assert(Int(customResult.clips[2].duration) == 45)
    print("  Custom per-clip durations verified: \(customResult.clips.map { Int($0.duration) })s")

    print("ALL HIGHLIGHT DETECTOR TESTS PASSED!")
}

@main
struct TestRunner {
    static func main() {
        runTests()
    }
}
