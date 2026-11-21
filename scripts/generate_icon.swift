import AppKit
import CoreGraphics
import Foundation

func drawIconPNGData(pixelSize: Int) throws -> Data {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw NSError(domain: "IconGen", code: 1)
    }
    rep.size = NSSize(width: pixelSize, height: pixelSize)

    NSGraphicsContext.saveGraphicsState()
    guard let nsCtx = NSGraphicsContext(bitmapImageRep: rep) else {
        NSGraphicsContext.restoreGraphicsState()
        throw NSError(domain: "IconGen", code: 2)
    }
    NSGraphicsContext.current = nsCtx
    let ctx = nsCtx.cgContext

    let s = CGFloat(pixelSize)
    let pad = s * 0.08
    let rect = CGRect(x: pad, y: pad, width: s - pad * 2, height: s - pad * 2)
    let radius = rect.width * 0.225

    // Background squircle with red-to-orange gradient
    let bgPath = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let colors = [
        CGColor(red: 0.92, green: 0.12, blue: 0.18, alpha: 1.0),
        CGColor(red: 0.98, green: 0.42, blue: 0.10, alpha: 1.0)
    ] as CFArray
    if let grad = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0.0, 1.0]) {
        ctx.drawLinearGradient(
            grad,
            start: CGPoint(x: rect.minX, y: rect.maxY),
            end: CGPoint(x: rect.maxX, y: rect.minY),
            options: []
        )
    }
    ctx.restoreGState()

    // Draw high-moment waveform bars in bottom half
    ctx.saveGState()
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.92))
    let barHeights: [CGFloat] = [0.12, 0.22, 0.44, 0.28, 0.56, 0.36, 0.18]
    let numBars = barHeights.count
    let barWidth = rect.width * 0.065
    let barSpacing = rect.width * 0.032
    let totalBarsWidth = CGFloat(numBars) * barWidth + CGFloat(numBars - 1) * barSpacing
    let startX = rect.midX - totalBarsWidth / 2.0
    let baseY = rect.minY + rect.height * 0.18

    for (i, hFrac) in barHeights.enumerated() {
        let bx = startX + CGFloat(i) * (barWidth + barSpacing)
        let bh = rect.height * hFrac
        let barRect = CGRect(x: bx, y: baseY, width: barWidth, height: bh)
        let barPath = CGPath(roundedRect: barRect, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil)
        ctx.addPath(barPath)
        ctx.fillPath()
    }
    ctx.restoreGState()

    // Draw Play triangle badge near top center
    ctx.saveGState()
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.97))
    let playCenterY = rect.minY + rect.height * 0.72
    let playSize = rect.width * 0.22
    let playPath = CGMutablePath()
    playPath.move(to: CGPoint(x: rect.midX - playSize * 0.38, y: playCenterY + playSize * 0.5))
    playPath.addLine(to: CGPoint(x: rect.midX - playSize * 0.38, y: playCenterY - playSize * 0.5))
    playPath.addLine(to: CGPoint(x: rect.midX + playSize * 0.52, y: playCenterY))
    playPath.closeSubpath()
    ctx.addPath(playPath)
    ctx.fillPath()
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()

    guard let pngData = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "IconGen", code: 3)
    }
    return pngData
}

func appendUInt32BE(_ value: UInt32, to data: inout Data) {
    var be = value.bigEndian
    withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
}

let chunks: [(String, Int)] = [
    ("icp4", 16),
    ("icp5", 32),
    ("icp6", 64),
    ("ic07", 128),
    ("ic08", 256),
    ("ic09", 512),
    ("ic10", 1024)
]

var bodyData = Data()
for (ostype, px) in chunks {
    let png = try drawIconPNGData(pixelSize: px)
    bodyData.append(contentsOf: ostype.utf8)
    appendUInt32BE(UInt32(8 + png.count), to: &bodyData)
    bodyData.append(png)
}

var icnsData = Data()
icnsData.append(contentsOf: "icns".utf8)
appendUInt32BE(UInt32(8 + bodyData.count), to: &icnsData)
icnsData.append(bodyData)

let projectDir: String = {
    if CommandLine.arguments.count > 1 {
        return CommandLine.arguments[1]
    }
    return FileManager.default.currentDirectoryPath
}()
let outputURL = URL(fileURLWithPath: projectDir).appendingPathComponent("Resources/AppIcon.icns")
try icnsData.write(to: outputURL)
print("Generated Resources/AppIcon.icns (\(icnsData.count) bytes) successfully.")
