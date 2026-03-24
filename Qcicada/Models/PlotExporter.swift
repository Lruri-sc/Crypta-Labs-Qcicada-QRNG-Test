// PlotExporter.swift
// Qcicada
//
// Exports full-session waveform as a high-resolution PNG.
// Uses Core Graphics for rendering — no matplotlib dependency.
// Width scales with data count, no upper limit.

import AppKit
import Foundation

final class PlotExporter {
    
    typealias Stats = (
        sampleCount: Int,
        totalBits: Int,
        totalOnes: Int,
        peakInstHi: Double,
        peakInstLo: Double,
        peakCumHi: Double,
        peakCumLo: Double,
        izMean: Double,
        izVariance: Double
    )
    
    static func saveFullPlot(
        iz: [Double],
        cz: [Double],
        vr: [Double],
        stats: Stats,
        to directory: String
    ) {
        guard !iz.isEmpty else { return }
        
        let n = iz.count
        
        // Scale: 3 pixels per sample, minimum 3600px (1200 samples)
        let pixelsPerSample: CGFloat = 3.0
        let width = max(3600, CGFloat(n) * pixelsPerSample)
        let height: CGFloat = 900.0
        
        // Chart areas: iz gets 45%, cz gets 35%, var gets 20%
        let izHeight = height * 0.42
        let czHeight = height * 0.33
        let vrHeight = height * 0.15
        let headerHeight = height * 0.10
        
        let margin: CGFloat = 60
        let chartWidth = width - margin * 2
        
        let size = NSSize(width: width, height: height)
        let image = NSImage(size: size)
        
        image.lockFocus()
        guard let ctx = NSGraphicsContext.current?.cgContext else {
            image.unlockFocus()
            return
        }
        
        // Background
        ctx.setFillColor(NSColor(white: 0.06, alpha: 1.0).cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))
        
        // Header text
        let headerAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 14, weight: .medium)
        ]
        let cumZ = stats.totalBits > 0
            ? (Double(stats.totalOnes) - Double(stats.totalBits) * 0.5) / sqrt(Double(stats.totalBits) * 0.25)
            : 0.0
        let headerText = "随机数测试 Full Session — QCicada QRNG  |  "
            + "samples=\(stats.sampleCount)  bits=\(stats.totalBits)  "
            + "iZ hi=\(String(format: "%+.2f", stats.peakInstHi)) lo=\(String(format: "%+.2f", stats.peakInstLo))  "
            + "cZ=\(String(format: "%+.4f", cumZ))  "
            + "mean=\(String(format: "%+.4f", stats.izMean))  var=\(String(format: "%.4f", stats.izVariance))"
        
        (headerText as NSString).draw(
            at: NSPoint(x: margin, y: height - headerHeight + 10),
            withAttributes: headerAttrs
        )
        
        // Draw charts
        let izOriginY = height - headerHeight - izHeight
        let czOriginY = izOriginY - czHeight - 10
        let vrOriginY = czOriginY - vrHeight - 10
        
        drawChart(ctx: ctx, data: iz, rect: CGRect(x: margin, y: izOriginY, width: chartWidth, height: izHeight),
                  color: NSColor(red: 0.0, green: 1.0, blue: 0.67, alpha: 1.0), // green
                  label: "Instant Z", thresholds: [1.96, 2.58], refLine: 0)
        
        drawChart(ctx: ctx, data: cz, rect: CGRect(x: margin, y: czOriginY, width: chartWidth, height: czHeight),
                  color: NSColor(red: 1.0, green: 0.67, blue: 0.0, alpha: 1.0), // orange
                  label: "Cumulative Z", thresholds: [1.96], refLine: 0)
        
        drawChart(ctx: ctx, data: vr, rect: CGRect(x: margin, y: vrOriginY, width: chartWidth, height: vrHeight),
                  color: NSColor(red: 1.0, green: 0.4, blue: 0.6, alpha: 1.0), // pink
                  label: "Variance", thresholds: [], refLine: 1.0)
        
        image.unlockFocus()
        
        // Save as PNG
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [.compressionFactor: 0.9]) else {
            return
        }
        
        let ts = dateString()
        let filename = "rng_session_\(ts).png"
        let path = (directory as NSString).appendingPathComponent(filename)
        try? pngData.write(to: URL(fileURLWithPath: path))
    }
    
    // MARK: - Draw single chart
    
    private static func drawChart(
        ctx: CGContext,
        data: [Double],
        rect: CGRect,
        color: NSColor,
        label: String,
        thresholds: [Double],
        refLine: Double?
    ) {
        guard !data.isEmpty else { return }
        
        let n = data.count
        let mn = data.min()!
        let mx = data.max()!
        let pad = max(0.5, (mx - mn) * 0.15)
        let yMin: Double
        let yMax: Double
        
        if let ref = refLine, ref > 0 {
            yMin = max(0, mn - pad)
            yMax = mx + pad
        } else {
            yMin = min(mn - pad, -2)
            yMax = max(mx + pad, 2)
        }
        
        let yRange = yMax - yMin
        guard yRange > 0 else { return }
        
        func xPos(_ i: Int) -> CGFloat {
            return rect.minX + CGFloat(i) / CGFloat(max(1, n - 1)) * rect.width
        }
        
        func yPos(_ v: Double) -> CGFloat {
            return rect.minY + CGFloat((v - yMin) / yRange) * rect.height
        }
        
        // Background
        ctx.setFillColor(NSColor(white: 0.04, alpha: 1.0).cgColor)
        ctx.fill(rect)
        
        // Reference line
        if let ref = refLine {
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.15).cgColor)
            ctx.setLineWidth(0.8)
            ctx.move(to: CGPoint(x: rect.minX, y: yPos(ref)))
            ctx.addLine(to: CGPoint(x: rect.maxX, y: yPos(ref)))
            ctx.strokePath()
        }
        
        // Threshold lines
        ctx.setStrokeColor(NSColor.yellow.withAlphaComponent(0.3).cgColor)
        ctx.setLineWidth(0.5)
        ctx.setLineDash(phase: 0, lengths: [6, 4])
        for t in thresholds {
            ctx.move(to: CGPoint(x: rect.minX, y: yPos(t)))
            ctx.addLine(to: CGPoint(x: rect.maxX, y: yPos(t)))
            ctx.move(to: CGPoint(x: rect.minX, y: yPos(-t)))
            ctx.addLine(to: CGPoint(x: rect.maxX, y: yPos(-t)))
        }
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])
        
        // Data line
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(0.8)
        ctx.move(to: CGPoint(x: xPos(0), y: yPos(data[0])))
        for i in 1..<n {
            ctx.addLine(to: CGPoint(x: xPos(i), y: yPos(data[i])))
        }
        ctx.strokePath()
        
        // Label
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: color,
            .font: NSFont.systemFont(ofSize: 11, weight: .medium)
        ]
        (label as NSString).draw(
            at: NSPoint(x: rect.minX + 4, y: rect.maxY - 16),
            withAttributes: labelAttrs
        )
        
        // Y-axis labels
        let axisAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.gray,
            .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
        ]
        let steps = 5
        for i in 0...steps {
            let v = yMin + yRange * Double(i) / Double(steps)
            let text = String(format: "%.1f", v)
            (text as NSString).draw(
                at: NSPoint(x: rect.minX - 36, y: yPos(v) - 5),
                withAttributes: axisAttrs
            )
        }
    }
    
    private static func dateString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f.string(from: Date())
    }
}
