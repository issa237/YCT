import Foundation

enum AspectRatioMode: String, CaseIterable, Identifiable {
    case original = "Original (16:9 / Source)"
    case vertical9x16 = "Vertical 9:16 (Shorts / Reels / TikTok)"

    var id: String { rawValue }
}

enum DetectionSource: String {
    case youtubeHeatmap = "YouTube Most Replayed Heatmap"
    case audioEnergy = "Audio Excitement & Energy Peaks"
    case chaptersAndEnergy = "Chapter Highlights + Audio Energy"
}

enum ClipExtractionStatus: Equatable {
    case pending
    case queued
    case extracting(progress: Double)
    case completed(URL)
    case failed(String)

    var displayText: String {
        switch self {
        case .pending:
            return "Ready"
        case .queued:
            return "Queued"
        case .extracting(let p):
            return p > 0 ? String(format: "Extracting %.0f%%", p * 100) : "Extracting..."
        case .completed:
            return "Saved"
        case .failed(let err):
            return "Error: \(err)"
        }
    }

    var isCompleted: Bool {
        if case .completed = self { return true }
        return false
    }
}

struct HeatmapPoint: Codable, Equatable {
    let start_time: Double
    let end_time: Double
    let value: Double
}

struct VideoChapter: Codable, Equatable {
    let start_time: Double?
    let end_time: Double?
    let title: String?
}

struct YtDlpMetadata: Codable {
    let id: String?
    let title: String?
    let duration: Double?
    let thumbnail: String?
    let uploader: String?
    let channel: String?
    let view_count: Int?
    let heatmap: [HeatmapPoint]?
    let chapters: [VideoChapter]?
}

struct HighlightClipItem: Identifiable, Equatable {
    let id: UUID
    var index: Int
    var startTime: Double
    var duration: Double
    var score: Double // 0.0 to 1.0
    var reason: String
    var status: ClipExtractionStatus

    var endTime: Double {
        startTime + duration
    }

    var scorePercentage: Int {
        min(100, max(1, Int((score * 100.0).rounded())))
    }

    var formattedTimeRange: String {
        "\(TimeFormatter.format(seconds: startTime)) → \(TimeFormatter.format(seconds: endTime))"
    }
}

enum TimeFormatter {
    static func format(seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hrs = total / 3600
        let mins = (total % 3600) / 60
        let secs = total % 60
        if hrs > 0 {
            return String(format: "%d:%02d:%02d", hrs, mins, secs)
        } else {
            return String(format: "%02d:%02d", mins, secs)
        }
    }

    static func filenameTimestamp(seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hrs = total / 3600
        let mins = (total % 3600) / 60
        let secs = total % 60
        if hrs > 0 {
            return String(format: "%02dh%02dm%02ds", hrs, mins, secs)
        } else {
            return String(format: "%02dm%02ds", mins, secs)
        }
    }
}
