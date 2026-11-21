import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var engine: ClipEngine

    private let durationPresets: [Double] = [15, 30, 45, 60, 90, 120]
    private let countPresets: [Int] = [3, 5, 8, 10]

    var body: some View {
        VStack(spacing: 0) {
            headerBar

            Divider()

            HSplitView {
                // LEFT PANEL: Controls & Inputs
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        sourceInputCard
                        clipConfigurationCard
                        destinationFolderCard
                        outputFormatCard
                        actionButtonsCard
                    }
                    .padding(18)
                }
                .frame(minWidth: 390, idealWidth: 420, maxWidth: 470)

                // RIGHT PANEL: Timeline, Detected High Moments, and Logs
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            if engine.videoDuration > 0 || !engine.videoTitle.isEmpty {
                                videoSummaryAndTimelineCard
                            }
                            clipsListCard
                        }
                        .padding(18)
                    }

                    Divider()

                    activityLogBar
                }
                .frame(minWidth: 500, maxWidth: .infinity)
            }
        }
        .frame(minWidth: 940, minHeight: 660)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Top Header Bar

    private var headerBar: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.red, Color.orange],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 38, height: 38)
                Image(systemName: "scissors.badge.ellipsis")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("YCT — YouTube High-Moment Clipper")
                    .font(.system(size: 16, weight: .bold))
                Text("Automatically detect Most Replayed & high-energy moments and extract ready-to-share MP4 clips")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Spacer()

            statusPill

            Button(action: { engine.openOutputFolderInFinder() }) {
                Label("Open Clips Folder", systemImage: "folder")
            }
            .controlSize(.regular)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var statusPill: some View {
        HStack(spacing: 6) {
            if engine.phase.isBusy {
                ProgressView()
                    .controlSize(.small)
            } else {
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 8, height: 8)
            }
            Text(engine.phase.statusTitle)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(Color(NSColor.quaternaryLabelColor).opacity(0.4))
        )
    }

    private var statusDotColor: Color {
        switch engine.phase {
        case .idle:
            return .gray
        case .completed:
            return .green
        case .failed:
            return .red
        default:
            return .orange
        }
    }

    // MARK: - 1. Video Source Input Card

    private var sourceInputCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("1. YouTube URL or Local Video", systemImage: "play.rectangle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.primary)
                    Spacer()
                    Button("Paste URL") {
                        if let str = NSPasteboard.general.string(forType: .string) {
                            engine.videoURL = str.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    }
                    .controlSize(.small)

                    Button("Local File...") {
                        engine.chooseLocalVideoFile()
                    }
                    .controlSize(.small)
                }

                HStack(spacing: 8) {
                    TextField("https://www.youtube.com/watch?v=...", text: $engine.videoURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .disabled(engine.phase.isBusy)

                    Button(action: {
                        Task { await engine.analyzeOnly() }
                    }) {
                        Label("Preview Moments", systemImage: "waveform.badge.magnifyingglass")
                    }
                    .disabled(engine.phase.isBusy || engine.videoURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Fetch video metadata and preview the detected high-moment timestamps before downloading")
                }
            }
            .padding(6)
        }
    }

    // MARK: - 2. Clip Count & Duration Card

    private var clipConfigurationCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                Label("2. Number of Clips & Duration", systemImage: "slider.horizontal.3")
                    .font(.system(size: 13, weight: .semibold))

                // NUMBER OF CLIPS
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Number of High-Moment Clips:")
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        Stepper(value: $engine.numberOfClips, in: 1...30) {
                            Text("\(engine.numberOfClips) \(engine.numberOfClips == 1 ? "clip" : "clips")")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundColor(.accentColor)
                        }
                        .disabled(engine.phase.isBusy)
                    }

                    HStack(spacing: 6) {
                        Text("Quick Select:")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        ForEach(countPresets, id: \.self) { count in
                            Button("\(count) clips") {
                                engine.numberOfClips = count
                            }
                            .controlSize(.small)
                            .buttonStyle(.bordered)
                            .tint(engine.numberOfClips == count ? .accentColor : .secondary)
                            .disabled(engine.phase.isBusy)
                        }
                    }
                }

                Divider()

                // DURATION PER CLIP
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Duration per Clip (seconds):")
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        HStack(spacing: 4) {
                            TextField(
                                "Seconds",
                                value: $engine.defaultClipDuration,
                                format: .number
                            )
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 64)
                            .multilineTextAlignment(.trailing)
                            .disabled(engine.phase.isBusy)

                            Text("sec")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                    }

                    HStack(spacing: 5) {
                        Text("Presets:")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        ForEach(durationPresets, id: \.self) { preset in
                            Button("\(Int(preset))s") {
                                engine.defaultClipDuration = preset
                            }
                            .controlSize(.small)
                            .buttonStyle(.bordered)
                            .tint(Int(engine.defaultClipDuration) == Int(preset) ? .accentColor : .secondary)
                            .disabled(engine.phase.isBusy)
                        }
                    }

                    Toggle(isOn: $engine.useCustomPerClipDurations) {
                        Text("Set custom duration for each individual clip")
                            .font(.system(size: 11))
                    }
                    .toggleStyle(.checkbox)
                    .disabled(engine.phase.isBusy)

                    if engine.useCustomPerClipDurations {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Individual Clip Durations (seconds):")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.secondary)

                            LazyVGrid(
                                columns: [
                                    GridItem(.flexible(), spacing: 8),
                                    GridItem(.flexible(), spacing: 8)
                                ],
                                spacing: 6
                            ) {
                                ForEach(0..<engine.numberOfClips, id: \.self) { idx in
                                    HStack(spacing: 4) {
                                        Text("Clip #\(idx + 1):")
                                            .font(.system(size: 11, weight: .medium))
                                            .frame(width: 52, alignment: .leading)
                                        TextField(
                                            "sec",
                                            value: Binding(
                                                get: {
                                                    idx < engine.customClipDurations.count
                                                        ? engine.customClipDurations[idx]
                                                        : engine.defaultClipDuration
                                                },
                                                set: { newVal in
                                                    engine.updateCustomDuration(at: idx, to: newVal)
                                                }
                                            ),
                                            format: .number
                                        )
                                        .textFieldStyle(.roundedBorder)
                                        .font(.system(size: 11))
                                        Text("s")
                                            .font(.system(size: 11))
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                        }
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color(NSColor.controlBackgroundColor))
                        )
                    }
                }
            }
            .padding(6)
        }
    }

    // MARK: - 3. Destination Folder Card

    private var destinationFolderCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("3. Output Folder (Where to Keep Clips)", systemImage: "folder.fill")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button("Choose Folder...") {
                        engine.chooseOutputFolder()
                    }
                    .controlSize(.small)
                    .disabled(engine.phase.isBusy)
                }

                HStack(spacing: 8) {
                    Image(systemName: "externaldrive.fill")
                        .foregroundColor(.accentColor)
                    Text(engine.outputDirectory.path)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer()
                    Button(action: { engine.openOutputFolderInFinder() }) {
                        Image(systemName: "arrow.up.forward.square")
                    }
                    .buttonStyle(.borderless)
                    .help("Open this folder in Finder")
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(NSColor.controlBackgroundColor))
                )
            }
            .padding(6)
        }
    }

    // MARK: - 4. Format & Full-Video Options Card

    private var outputFormatCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Label("4. Export Format & Options", systemImage: "aspectratio")
                    .font(.system(size: 13, weight: .semibold))

                Picker("Aspect Ratio:", selection: $engine.aspectRatioMode) {
                    ForEach(AspectRatioMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                .font(.system(size: 12))
                .disabled(engine.phase.isBusy)

                Toggle(isOn: $engine.keepFullVideo) {
                    Text("Also keep the full downloaded video in the output folder")
                        .font(.system(size: 12))
                }
                .toggleStyle(.checkbox)
                .disabled(engine.phase.isBusy)
            }
            .padding(6)
        }
    }

    // MARK: - 5. Primary Action Buttons Card

    private var actionButtonsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if engine.phase.isBusy {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(engine.phase.statusTitle)
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Text("\(Int((engine.overallProgress * 100).rounded()))%")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                    }
                    ProgressView(value: engine.overallProgress, total: 1.0)
                        .progressViewStyle(.linear)
                }
            }

            HStack(spacing: 10) {
                Button(action: {
                    Task { await engine.startDownloadAndExtract() }
                }) {
                    HStack {
                        Spacer()
                        Image(systemName: "bolt.fill")
                        Text("Download & Extract \(engine.numberOfClips) High-Moment Clips")
                            .font(.system(size: 13, weight: .bold))
                        Spacer()
                    }
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
                .disabled(engine.phase.isBusy || engine.videoURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if engine.phase.isBusy {
                    Button(role: .destructive, action: {
                        engine.cancelCurrentTask()
                    }) {
                        Text("Cancel")
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            }

            if case .completed(let count, let folder) = engine.phase {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Saved \(count) clips to \(folder.lastPathComponent)")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Button("Show in Finder") {
                        engine.openOutputFolderInFinder()
                    }
                    .controlSize(.small)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.green.opacity(0.12))
                )
            }

            if case .failed(let errMsg) = engine.phase {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                    Text(errMsg)
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                        .textSelection(.enabled)
                    Spacer()
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.red.opacity(0.12))
                )
            }
        }
    }

    // MARK: - Right Panel: Video Summary & Excitement Timeline

    private var videoSummaryAndTimelineCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(engine.videoTitle.isEmpty ? "Video Loaded" : engine.videoTitle)
                            .font(.system(size: 14, weight: .bold))
                            .lineLimit(2)

                        HStack(spacing: 12) {
                            if !engine.videoChannel.isEmpty {
                                Label(engine.videoChannel, systemImage: "person.crop.square")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                            if engine.videoDuration > 0 {
                                Label(
                                    "Total Duration: \(TimeFormatter.format(seconds: engine.videoDuration))",
                                    systemImage: "clock"
                                )
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                            }
                            Label(engine.detectionSource.rawValue, systemImage: "sparkles")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.orange)
                        }
                    }
                    Spacer()
                }

                if !engine.timelineScores.isEmpty && engine.videoDuration > 0 {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("High-Moment Intensity Timeline (Highlighted = Selected Clips)")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("00:00 → \(TimeFormatter.format(seconds: engine.videoDuration))")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                        }

                        HeatmapTimelineView(
                            scores: engine.timelineScores,
                            totalDuration: engine.videoDuration,
                            clips: engine.clips
                        )
                        .frame(height: 68)
                    }
                }
            }
            .padding(8)
        }
    }

    // MARK: - Right Panel: Detected / Extracted Clips List

    private var clipsListCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(
                        "High-Moment Clips (\(engine.clips.isEmpty ? engine.numberOfClips : engine.clips.count))",
                        systemImage: "film.stack"
                    )
                    .font(.system(size: 13, weight: .semibold))

                    Spacer()

                    if !engine.clips.isEmpty {
                        Button("Reset to Auto Peaks") {
                            engine.recalculateHighlightsIfPossible()
                        }
                        .controlSize(.small)
                        .disabled(engine.phase.isBusy)
                    }
                }

                if engine.clips.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 28))
                            .foregroundColor(.secondary)
                        Text("Enter a YouTube URL and click \"Download & Extract\" (or \"Preview Moments\")")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                        Text("YCT will automatically rank the highest-engagement peaks and extract \(engine.numberOfClips) non-overlapping clips of \(Int(engine.defaultClipDuration))s each into your output folder.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 420)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 36)
                } else {
                    VStack(spacing: 8) {
                        ForEach($engine.clips) { $clip in
                            ClipRowView(
                                clip: $clip,
                                maxVideoDuration: max(engine.videoDuration, clip.endTime),
                                isBusy: engine.phase.isBusy,
                                onReveal: { url in
                                    engine.revealFileInFinder(url)
                                }
                            )
                        }
                    }
                }
            }
            .padding(8)
        }
    }

    // MARK: - Bottom Activity Log Bar

    private var activityLogBar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button(action: { withAnimation { engine.showLogs.toggle() } }) {
                    HStack(spacing: 6) {
                        Image(systemName: engine.showLogs ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                        Text("Activity Log (\(engine.activityLogs.count))")
                            .font(.system(size: 11, weight: .semibold))
                    }
                }
                .buttonStyle(.plain)

                if let lastLog = engine.activityLogs.last {
                    Text(lastLog)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.leading, 8)
                }

                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))

            if engine.showLogs {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(engine.activityLogs.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(10)
                }
                .frame(height: 120)
                .background(Color(NSColor.textBackgroundColor))
            }
        }
    }
}

// MARK: - Visual Excitement & Heatmap Timeline Component

struct HeatmapTimelineView: View {
    let scores: [Double]
    let totalDuration: Double
    let clips: [HighlightClipItem]

    var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width)
            let height = max(1, geo.size.height)

            ZStack(alignment: .leading) {
                // Background
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(NSColor.controlBackgroundColor))

                // Waveform / Heatmap bars
                Canvas { context, size in
                    let n = scores.count
                    guard n > 0 else { return }
                    let step = size.width / CGFloat(n)
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: size.height))
                    for i in 0..<n {
                        let x = CGFloat(i) * step
                        let norm = CGFloat(min(1.0, max(0.05, scores[i])))
                        let y = size.height - (norm * (size.height - 8))
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                    path.addLine(to: CGPoint(x: size.width, y: size.height))
                    path.closeSubpath()

                    context.fill(
                        path,
                        with: .linearGradient(
                            Gradient(colors: [Color.orange.opacity(0.55), Color.red.opacity(0.15)]),
                            startPoint: CGPoint(x: 0, y: 0),
                            endPoint: CGPoint(x: 0, y: size.height)
                        )
                    )
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))

                // Highlighted Clip Windows
                ForEach(clips) { clip in
                    let startFrac = CGFloat(max(0, min(1, clip.startTime / max(1, totalDuration))))
                    let durFrac = CGFloat(max(0.01, min(1.0 - Double(startFrac), clip.duration / max(1, totalDuration))))
                    let xOffset = startFrac * width
                    let boxWidth = max(6, durFrac * width)

                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.red.opacity(0.32))
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color.red, lineWidth: 1.5)
                            )
                        Text("#\(clip.index)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.red.cornerRadius(3))
                            .padding(2)
                    }
                    .frame(width: boxWidth, height: height - 4)
                    .offset(x: xOffset, y: 2)
                }
            }
        }
    }
}

// MARK: - Individual Clip Row Component

struct ClipRowView: View {
    @Binding var clip: HighlightClipItem
    let maxVideoDuration: Double
    let isBusy: Bool
    let onReveal: (URL) -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Clip Index Badge
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.red.opacity(0.14))
                    .frame(width: 36, height: 36)
                Text("#\(clip.index)")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(.red)
            }

            // Clip Details & Editable Start/Duration
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(clip.formattedTimeRange)
                        .font(.system(size: 13, weight: .bold, design: .monospaced))

                    Text("Peak Score: \(clip.scorePercentage)%")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(Color.orange.opacity(0.2))
                        )
                        .foregroundColor(.orange)

                    Text(clip.reason)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 14) {
                    HStack(spacing: 4) {
                        Text("Start (s):")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        TextField("Start", value: $clip.startTime, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 65)
                            .font(.system(size: 11, design: .monospaced))
                            .disabled(isBusy)
                    }

                    HStack(spacing: 4) {
                        Text("Duration (s):")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        TextField("Duration", value: $clip.duration, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                            .font(.system(size: 11, design: .monospaced))
                            .disabled(isBusy)
                    }
                }
            }

            Spacer()

            // Status & Action
            HStack(spacing: 8) {
                switch clip.status {
                case .pending, .queued:
                    Text(clip.status.displayText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                case .extracting:
                    HStack(spacing: 4) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Cutting...")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.orange)
                    }
                case .completed(let fileURL):
                    Button(action: { onReveal(fileURL) }) {
                        Label("Show Clip", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                    .tint(.green)
                    .controlSize(.small)
                case .failed(let msg):
                    Text(msg)
                        .font(.system(size: 10))
                        .foregroundColor(.red)
                        .lineLimit(1)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor))
        )
    }
}
