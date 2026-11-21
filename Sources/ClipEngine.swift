import AppKit
import Combine
import Foundation
import SwiftUI

enum EnginePhase: Equatable {
    case idle
    case fetchingMetadata
    case analyzingAudio
    case downloadingVideo(progress: Double, speedText: String)
    case extractingClips(currentClip: Int, totalClips: Int)
    case completed(savedCount: Int, folder: URL)
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .fetchingMetadata, .analyzingAudio, .downloadingVideo, .extractingClips:
            return true
        case .idle, .completed, .failed:
            return false
        }
    }

    var statusTitle: String {
        switch self {
        case .idle:
            return "Ready to extract high moments"
        case .fetchingMetadata:
            return "Fetching video info & YouTube Most Replayed heatmap..."
        case .analyzingAudio:
            return "Analyzing audio excitement & energy peaks..."
        case .downloadingVideo(let p, let speed):
            let pct = Int((p * 100).rounded())
            return speed.isEmpty
                ? "Downloading source video (\(pct)%)..."
                : "Downloading source video (\(pct)% • \(speed))..."
        case .extractingClips(let curr, let total):
            return "Extracting high-moment clip \(curr) of \(total)..."
        case .completed(let count, _):
            return "Done! Extracted \(count) high-moment clips."
        case .failed(let msg):
            return "Error: \(msg)"
        }
    }
}

@MainActor
final class ClipEngine: ObservableObject {

    // MARK: - User Inputs
    @Published var videoURL: String = ""
    @Published var localVideoURL: URL? = nil
    @Published var numberOfClips: Int = 5 {
        didSet {
            let clamped = max(1, min(30, numberOfClips))
            if clamped != numberOfClips {
                numberOfClips = clamped
                return
            }
            syncCustomDurationsCount()
            recalculateHighlightsIfPossible()
        }
    }
    @Published var defaultClipDuration: Double = 30.0 {
        didSet {
            let clamped = max(3.0, min(600.0, defaultClipDuration))
            if clamped != defaultClipDuration {
                defaultClipDuration = clamped
                return
            }
            if !useCustomPerClipDurations {
                customClipDurations = [Double](repeating: defaultClipDuration, count: numberOfClips)
            }
            recalculateHighlightsIfPossible()
        }
    }
    @Published var useCustomPerClipDurations: Bool = false {
        didSet {
            syncCustomDurationsCount()
            recalculateHighlightsIfPossible()
        }
    }
    @Published var customClipDurations: [Double] = [30, 30, 30, 30, 30]
    @Published var outputDirectory: URL
    @Published var aspectRatioMode: AspectRatioMode = .original
    @Published var keepFullVideo: Bool = false

    // MARK: - Detected Metadata & Clips
    @Published var videoTitle: String = ""
    @Published var videoChannel: String = ""
    @Published var videoDuration: Double = 0.0
    @Published var thumbnailURL: URL? = nil
    @Published var hasYouTubeHeatmap: Bool = false
    @Published var detectionSource: DetectionSource = .youtubeHeatmap
    @Published var timelineScores: [Double] = []
    @Published var clips: [HighlightClipItem] = []

    // MARK: - Execution State
    @Published var phase: EnginePhase = .idle
    @Published var overallProgress: Double = 0.0
    @Published var activityLogs: [String] = []
    @Published var showLogs: Bool = false

    private var cachedMetadata: YtDlpMetadata? = nil
    private var cachedAudioEnergy: [Double]? = nil
    private var lastAnalyzedURL: String = ""
    private var activeProcess: Process? = nil
    private var isCancelled: Bool = false

    init() {
        let moviesDir = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies")
        let defaultOut = moviesDir.appendingPathComponent("YCT_Clips", isDirectory: true)
        self.outputDirectory = defaultOut
        try? FileManager.default.createDirectory(at: defaultOut, withIntermediateDirectories: true)
    }

    // MARK: - Folder & File Pickers

    func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Folder to Save Extracted Clips"
        panel.message = "Select the destination folder where YCT should save your high-moment clips."
        panel.prompt = "Select Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = outputDirectory

        if panel.runModal() == .OK, let selectedURL = panel.url {
            outputDirectory = selectedURL
            appendLog("Output folder set to: \(selectedURL.path)")
        }
    }

    func chooseLocalVideoFile() {
        let panel = NSOpenPanel()
        panel.title = "Select a Local Video File"
        panel.prompt = "Choose Video"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            localVideoURL = url
            videoURL = url.path
            cachedMetadata = nil
            cachedAudioEnergy = nil
            videoTitle = url.deletingPathExtension().lastPathComponent
            appendLog("Selected local video file: \(url.lastPathComponent)")
            Task {
                await analyzeOnly()
            }
        }
    }

    func openOutputFolderInFinder() {
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(outputDirectory)
    }

    func revealFileInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Per-Clip Duration Helpers

    func effectiveClipDurations() -> [Double] {
        if useCustomPerClipDurations {
            var result = customClipDurations
            while result.count < numberOfClips {
                result.append(defaultClipDuration)
            }
            if result.count > numberOfClips {
                result = Array(result.prefix(numberOfClips))
            }
            return result.map { max(3.0, min(600.0, $0)) }
        } else {
            return [Double](repeating: max(3.0, defaultClipDuration), count: numberOfClips)
        }
    }

    func updateCustomDuration(at index: Int, to newValue: Double) {
        syncCustomDurationsCount()
        guard index >= 0 && index < customClipDurations.count else { return }
        customClipDurations[index] = max(3.0, min(600.0, newValue))
        if index < clips.count {
            clips[index].duration = customClipDurations[index]
        }
        recalculateHighlightsIfPossible()
    }

    private func syncCustomDurationsCount() {
        if customClipDurations.count < numberOfClips {
            let extra = [Double](repeating: defaultClipDuration, count: numberOfClips - customClipDurations.count)
            customClipDurations.append(contentsOf: extra)
        } else if customClipDurations.count > numberOfClips {
            customClipDurations = Array(customClipDurations.prefix(numberOfClips))
        }
    }

    func recalculateHighlightsIfPossible() {
        guard videoDuration > 0 else { return }
        let durations = effectiveClipDurations()
        let detection = HighlightDetector.detectHighlights(
            totalDuration: videoDuration,
            clipDurations: durations,
            heatmap: cachedMetadata?.heatmap,
            audioEnergy: cachedAudioEnergy,
            chapters: cachedMetadata?.chapters
        )
        self.clips = detection.clips
        self.detectionSource = detection.source
        self.timelineScores = detection.timelineScores
    }

    // MARK: - Actions: Analyze Only vs. Full Download & Extract

    func cancelCurrentTask() {
        isCancelled = true
        if let proc = activeProcess, proc.isRunning {
            proc.terminate()
        }
        activeProcess = nil
        phase = .idle
        overallProgress = 0.0
        appendLog("Operation cancelled by user.")
    }

    func analyzeOnly() async {
        let trimmed = videoURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            phase = .failed("Please enter a YouTube URL or select a local video file.")
            return
        }
        isCancelled = false
        overallProgress = 0.1

        do {
            if FileManager.default.fileExists(atPath: trimmed) {
                let fileURL = URL(fileURLWithPath: trimmed)
                localVideoURL = fileURL
                phase = .analyzingAudio
                appendLog("Probing local video duration and analyzing audio energy peaks...")
                let dur = try await probeLocalVideoDuration(fileURL: fileURL)
                self.videoTitle = fileURL.deletingPathExtension().lastPathComponent
                self.videoChannel = "Local Video"
                self.videoDuration = dur
                self.hasYouTubeHeatmap = false
                overallProgress = 0.4

                let energy = try await extractAudioEnergyTimeline(from: fileURL)
                self.cachedAudioEnergy = energy
                self.lastAnalyzedURL = trimmed
                recalculateHighlightsIfPossible()
                overallProgress = 1.0
                phase = .idle
                appendLog("Detected \(clips.count) high-energy moments from local video audio.")
            } else {
                localVideoURL = nil
                phase = .fetchingMetadata
                appendLog("Fetching YouTube video info & heatmap for: \(trimmed)")
                let meta = try await fetchYouTubeMetadata(url: trimmed)
                applyMetadata(meta, forURL: trimmed)
                recalculateHighlightsIfPossible()
                overallProgress = 1.0
                phase = .idle
                if hasYouTubeHeatmap {
                    appendLog("Loaded YouTube 'Most Replayed' heatmap (\(meta.heatmap?.count ?? 0) data segments). Identified top \(clips.count) high moments.")
                } else {
                    appendLog("Video metadata loaded (\(TimeFormatter.format(seconds: videoDuration))). Audio peak analysis will run automatically during download.")
                }
            }
        } catch {
            if !isCancelled {
                phase = .failed(error.localizedDescription)
                appendLog("Error: \(error.localizedDescription)")
            }
        }
    }

    func startDownloadAndExtract() async {
        let trimmed = videoURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            phase = .failed("Please enter a YouTube URL or select a local video file.")
            return
        }
        isCancelled = false
        overallProgress = 0.02

        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

            let sourceVideoFile: URL
            var shouldDeleteSourceAfter = false

            if FileManager.default.fileExists(atPath: trimmed) {
                // Local video file
                let fileURL = URL(fileURLWithPath: trimmed)
                sourceVideoFile = fileURL
                if videoDuration <= 0 || lastAnalyzedURL != trimmed {
                    phase = .analyzingAudio
                    let dur = try await probeLocalVideoDuration(fileURL: fileURL)
                    self.videoTitle = fileURL.deletingPathExtension().lastPathComponent
                    self.videoChannel = "Local Video"
                    self.videoDuration = dur
                    self.hasYouTubeHeatmap = false
                    let energy = try await extractAudioEnergyTimeline(from: fileURL)
                    self.cachedAudioEnergy = energy
                    self.lastAnalyzedURL = trimmed
                    recalculateHighlightsIfPossible()
                }
            } else {
                // 1. Fetch YouTube metadata if not already cached for this URL
                if cachedMetadata == nil || lastAnalyzedURL != trimmed || videoDuration <= 0 {
                    phase = .fetchingMetadata
                    overallProgress = 0.05
                    appendLog("Fetching YouTube metadata & Most Replayed heatmap...")
                    let meta = try await fetchYouTubeMetadata(url: trimmed)
                    applyMetadata(meta, forURL: trimmed)
                    recalculateHighlightsIfPossible()
                }

                try checkCancellation()

                // 2. Download the video via yt-dlp
                let safeBaseName = sanitizeFilename(videoTitle.isEmpty ? "YouTube_Video" : videoTitle)
                let downloadedFilename = keepFullVideo
                    ? "\(safeBaseName)_Full_Video.mp4"
                    : ".yct_temp_\(UUID().uuidString.prefix(8)).mp4"
                let targetDownloadURL = outputDirectory.appendingPathComponent(downloadedFilename)

                // Remove any pre-existing temp file
                if FileManager.default.fileExists(atPath: targetDownloadURL.path) {
                    try? FileManager.default.removeItem(at: targetDownloadURL)
                }

                phase = .downloadingVideo(progress: 0.0, speedText: "")
                appendLog("Downloading video stream to \(targetDownloadURL.lastPathComponent)...")
                try await downloadYouTubeVideo(url: trimmed, destination: targetDownloadURL)
                sourceVideoFile = targetDownloadURL
                shouldDeleteSourceAfter = !keepFullVideo

                try checkCancellation()

                // 3. Analyze audio energy from downloaded video to refine highlights (essential when YouTube heatmap is absent, and blends with heatmap when present)
                phase = .analyzingAudio
                overallProgress = 0.55
                appendLog("Analyzing audio energy peaks across video timeline...")
                if let energy = try? await extractAudioEnergyTimeline(from: sourceVideoFile), !energy.isEmpty {
                    self.cachedAudioEnergy = energy
                    // If the user hasn't manually edited clips or if we didn't have a heatmap, recompute highlights with real audio energy
                    recalculateHighlightsIfPossible()
                    appendLog("High-moment detection complete using \(detectionSource.rawValue).")
                }
            }

            try checkCancellation()

            guard !clips.isEmpty else {
                throw NSError(domain: "YCT", code: 2, userInfo: [NSLocalizedDescriptionKey: "No clips to extract."])
            }

            // 4. Extract each high-moment clip with FFmpeg
            let safeTitle = sanitizeFilename(videoTitle.isEmpty ? "Video" : videoTitle)
            let totalClips = clips.count
            var savedCount = 0

            for i in 0..<totalClips {
                try checkCancellation()
                phase = .extractingClips(currentClip: i + 1, totalClips: totalClips)
                clips[i].status = .extracting(progress: 0.0)

                let clip = clips[i]
                let startTag = TimeFormatter.filenameTimestamp(seconds: clip.startTime)
                let endTag = TimeFormatter.filenameTimestamp(seconds: clip.endTime)
                let aspectTag = (aspectRatioMode == .vertical9x16) ? "_9x16" : ""
                let clipFilename = String(
                    format: "%@_Clip_%02d_%@-%@_Score%d%@.mp4",
                    safeTitle,
                    i + 1,
                    startTag,
                    endTag,
                    clip.scorePercentage,
                    aspectTag
                )
                let clipOutputURL = outputDirectory.appendingPathComponent(clipFilename)

                if FileManager.default.fileExists(atPath: clipOutputURL.path) {
                    try? FileManager.default.removeItem(at: clipOutputURL)
                }

                appendLog("Extracting Clip #\(i + 1) [\(clip.formattedTimeRange)] (\(Int(clip.duration))s) → \(clipFilename)")

                try await extractClipWithFFmpeg(
                    sourceFile: sourceVideoFile,
                    startTime: clip.startTime,
                    duration: clip.duration,
                    aspectMode: aspectRatioMode,
                    outputFile: clipOutputURL
                )

                clips[i].status = .completed(clipOutputURL)
                savedCount += 1
                overallProgress = 0.60 + (0.40 * Double(i + 1) / Double(totalClips))
            }

            // 5. Cleanup temporary full video if keepFullVideo is unchecked
            if shouldDeleteSourceAfter && FileManager.default.fileExists(atPath: sourceVideoFile.path) {
                try? FileManager.default.removeItem(at: sourceVideoFile)
                appendLog("Cleaned up temporary full video file (kept extracted clips only).")
            } else if keepFullVideo {
                appendLog("Kept full video at: \(sourceVideoFile.lastPathComponent)")
            }

            overallProgress = 1.0
            phase = .completed(savedCount: savedCount, folder: outputDirectory)
            appendLog("Successfully extracted \(savedCount) high-moment clips to \(outputDirectory.path)")

        } catch {
            if !isCancelled {
                phase = .failed(error.localizedDescription)
                appendLog("Error: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Subprocess Execution (yt-dlp & ffmpeg)

    private func applyMetadata(_ meta: YtDlpMetadata, forURL url: String) {
        self.cachedMetadata = meta
        self.lastAnalyzedURL = url
        self.videoTitle = meta.title ?? "YouTube Video"
        self.videoChannel = meta.channel ?? meta.uploader ?? "YouTube"
        self.videoDuration = max(1.0, meta.duration ?? 60.0)
        if let thumbStr = meta.thumbnail, let tURL = URL(string: thumbStr) {
            self.thumbnailURL = tURL
        } else {
            self.thumbnailURL = nil
        }
        let hmCount = meta.heatmap?.count ?? 0
        self.hasYouTubeHeatmap = hmCount > 0
    }

    private func fetchYouTubeMetadata(url: String) async throws -> YtDlpMetadata {
        let ytdlp = try locateBinary(named: "yt-dlp")
        let args = [
            "--dump-single-json",
            "--no-playlist",
            "--no-warnings",
            url
        ]
        let outputData = try await runCommandCaptureStdout(executable: ytdlp, arguments: args)
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(YtDlpMetadata.self, from: outputData)
        } catch {
            let rawText = String(data: outputData, encoding: .utf8) ?? ""
            throw NSError(
                domain: "YCT",
                code: 10,
                userInfo: [NSLocalizedDescriptionKey: "Failed to parse YouTube metadata. \(rawText.prefix(200))"]
            )
        }
    }

    private func downloadYouTubeVideo(url: String, destination: URL) async throws {
        let ytdlp = try locateBinary(named: "yt-dlp")
        let ffmpegDir = (try? locateBinary(named: "ffmpeg"))?.deletingLastPathComponent().path

        var args = [
            "--no-playlist",
            "--newline",
            "-f", "bv*[ext=mp4]+ba[ext=m4a]/b[ext=mp4]/bv*+ba/b",
            "--merge-output-format", "mp4",
            "-o", destination.path,
            url
        ]
        if let ffDir = ffmpegDir {
            args.insert(contentsOf: ["--ffmpeg-location", ffDir], at: 0)
        }

        try await runCommandWithLineCallback(executable: ytdlp, arguments: args) { [weak self] line in
            guard let self = self else { return }
            if let prog = Self.parseYtDlpProgress(line: line) {
                Task { @MainActor in
                    self.phase = .downloadingVideo(progress: prog.fraction, speedText: prog.speed)
                    self.overallProgress = 0.10 + (0.45 * prog.fraction)
                }
            }
        }

        guard FileManager.default.fileExists(atPath: destination.path) else {
            throw NSError(
                domain: "YCT",
                code: 11,
                userInfo: [NSLocalizedDescriptionKey: "Video download did not produce output file."]
            )
        }
    }

    private func extractAudioEnergyTimeline(from videoFile: URL) async throws -> [Double] {
        let ffmpeg = try locateBinary(named: "ffmpeg")
        // Decode mono audio at 1000 Hz into raw 32-bit float PCM on stdout (4 KB/sec, ultra fast)
        let args = [
            "-hide_banner",
            "-loglevel", "error",
            "-i", videoFile.path,
            "-vn",
            "-ac", "1",
            "-ar", "1000",
            "-f", "f32le",
            "pipe:1"
        ]
        let pcmData = try await runCommandCaptureStdout(executable: ffmpeg, arguments: args)
        return HighlightDetector.parsePCMFloat32ToSecondsRMS(data: pcmData, sampleRate: 1000)
    }

    private func probeLocalVideoDuration(fileURL: URL) async throws -> Double {
        let ffmpeg = try locateBinary(named: "ffmpeg")
        let args = ["-hide_banner", "-i", fileURL.path]
        let output = try await runCommandCaptureStderr(executable: ffmpeg, arguments: args)
        // Parse "Duration: 00:04:15.23"
        if let range = output.range(of: #"Duration:\s*(\d+):(\d+):(\d+(?:\.\d+)?)"#, options: .regularExpression) {
            let matchStr = String(output[range])
            let parts = matchStr.replacingOccurrences(of: "Duration:", with: "")
                .trimmingCharacters(in: .whitespaces)
                .split(separator: ":")
            if parts.count == 3,
               let h = Double(parts[0]),
               let m = Double(parts[1]),
               let s = Double(parts[2]) {
                return max(1.0, h * 3600.0 + m * 60.0 + s)
            }
        }
        return 60.0
    }

    private func extractClipWithFFmpeg(
        sourceFile: URL,
        startTime: Double,
        duration: Double,
        aspectMode: AspectRatioMode,
        outputFile: URL
    ) async throws {
        let ffmpeg = try locateBinary(named: "ffmpeg")
        var args: [String] = [
            "-hide_banner",
            "-loglevel", "error",
            "-y",
            "-ss", String(format: "%.3f", max(0.0, startTime)),
            "-i", sourceFile.path,
            "-t", String(format: "%.3f", max(1.0, duration))
        ]

        if aspectMode == .vertical9x16 {
            // Center-crop horizontal video to 9:16 and scale cleanly to 1080x1920
            args.append(contentsOf: [
                "-vf", "crop='min(iw,ih*9/16)':'min(ih,iw*16/9)',scale=1080:1920:flags=lanczos,setsar=1"
            ])
        }

        args.append(contentsOf: [
            "-c:v", "libx264",
            "-preset", "veryfast",
            "-crf", "20",
            "-pix_fmt", "yuv420p",
            "-c:a", "aac",
            "-b:a", "192k",
            "-movflags", "+faststart",
            outputFile.path
        ])

        _ = try await runCommandCaptureStdout(executable: ffmpeg, arguments: args)
        guard FileManager.default.fileExists(atPath: outputFile.path) else {
            throw NSError(
                domain: "YCT",
                code: 12,
                userInfo: [NSLocalizedDescriptionKey: "FFmpeg failed to create clip \(outputFile.lastPathComponent)."]
            )
        }
    }

    // MARK: - Binary Locator

    func locateBinary(named name: String) throws -> URL {
        var candidates: [URL] = []

        // 1. Inside YCT.app/Contents/Resources/bin/<name>
        if let resURL = Bundle.main.resourceURL {
            candidates.append(resURL.appendingPathComponent("bin/\(name)"))
            candidates.append(resURL.appendingPathComponent(name))
        }

        // 2. Relative to current executable / working directory
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        candidates.append(cwd.appendingPathComponent("Resources/bin/\(name)"))

        // 3. Standard macOS Homebrew & system paths
        let systemPaths = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)"
        ]
        for p in systemPaths {
            candidates.append(URL(fileURLWithPath: p))
        }

        for candidate in candidates {
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }

        throw NSError(
            domain: "YCT",
            code: 404,
            userInfo: [NSLocalizedDescriptionKey: "Required tool '\(name)' was not found in app bundle or system paths."]
        )
    }

    // MARK: - Async Process Helpers

    private func runCommandCaptureStdout(executable: URL, arguments: [String]) async throws -> Data {
        let proc = Process()
        proc.executableURL = executable
        proc.arguments = arguments

        var env = ProcessInfo.processInfo.environment
        let extraPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        env["PATH"] = "\(extraPath):\(env["PATH"] ?? "")"
        proc.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        self.activeProcess = proc

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try proc.run()
                    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    proc.waitUntilExit()

                    if proc.terminationStatus == 0 {
                        continuation.resume(returning: outData)
                    } else {
                        let errMsg = String(data: errData, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Exit code \(proc.terminationStatus)"
                        continuation.resume(
                            throwing: NSError(
                                domain: "YCT",
                                code: Int(proc.terminationStatus),
                                userInfo: [NSLocalizedDescriptionKey: errMsg.isEmpty ? "Command failed (\(proc.terminationStatus))" : errMsg]
                            )
                        )
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func runCommandCaptureStderr(executable: URL, arguments: [String]) async throws -> String {
        let proc = Process()
        proc.executableURL = executable
        proc.arguments = arguments

        var env = ProcessInfo.processInfo.environment
        let extraPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        env["PATH"] = "\(extraPath):\(env["PATH"] ?? "")"
        proc.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        self.activeProcess = proc

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try proc.run()
                    _ = outPipe.fileHandleForReading.readDataToEndOfFile()
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    proc.waitUntilExit()
                    let text = String(data: errData, encoding: .utf8) ?? ""
                    continuation.resume(returning: text)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func runCommandWithLineCallback(
        executable: URL,
        arguments: [String],
        onLine: @escaping @Sendable (String) -> Void
    ) async throws {
        let proc = Process()
        proc.executableURL = executable
        proc.arguments = arguments

        var env = ProcessInfo.processInfo.environment
        let extraPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        env["PATH"] = "\(extraPath):\(env["PATH"] ?? "")"
        proc.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        self.activeProcess = proc

        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            let lines = chunk.components(separatedBy: CharacterSet.newlines)
            for line in lines where !line.isEmpty {
                onLine(line)
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try proc.run()
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    proc.waitUntilExit()
                    outPipe.fileHandleForReading.readabilityHandler = nil

                    if proc.terminationStatus == 0 {
                        continuation.resume(returning: ())
                    } else {
                        let errMsg = String(data: errData, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Download failed (\(proc.terminationStatus))"
                        continuation.resume(
                            throwing: NSError(
                                domain: "YCT",
                                code: Int(proc.terminationStatus),
                                userInfo: [NSLocalizedDescriptionKey: errMsg]
                            )
                        )
                    }
                } catch {
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Utilities

    private nonisolated static func parseYtDlpProgress(line: String) -> (fraction: Double, speed: String)? {
        // Matches lines like: "[download]  45.2% of  120.50MiB at    8.45MiB/s ETA 00:08"
        guard line.contains("[download]"), line.contains("%") else { return nil }
        guard let pctRange = line.range(of: #"(\d+(?:\.\d+)?)%"#, options: .regularExpression) else {
            return nil
        }
        let pctStr = line[pctRange].replacingOccurrences(of: "%", with: "")
        guard let pct = Double(pctStr) else { return nil }

        var speedStr = ""
        if let speedRange = line.range(of: #"at\s+([^\s]+/s)"#, options: .regularExpression) {
            speedStr = line[speedRange]
                .replacingOccurrences(of: "at", with: "")
                .trimmingCharacters(in: .whitespaces)
        }
        return (min(1.0, max(0.0, pct / 100.0)), speedStr)
    }

    private func sanitizeFilename(_ name: String) -> String {
        let invalidChars = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let cleaned = name.components(separatedBy: invalidChars).joined(separator: "_")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = String(cleaned.prefix(48)).trimmingCharacters(in: .whitespacesAndNewlines)
        return prefix.isEmpty ? "YouTube_Clip" : prefix.replacingOccurrences(of: " ", with: "_")
    }

    private func checkCancellation() throws {
        if isCancelled {
            throw NSError(domain: "YCT", code: -999, userInfo: [NSLocalizedDescriptionKey: "Cancelled"])
        }
    }

    func appendLog(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let timestamp = formatter.string(from: Date())
        activityLogs.append("[\(timestamp)] \(message)")
        if activityLogs.count > 200 {
            activityLogs.removeFirst(activityLogs.count - 200)
        }
    }
}
