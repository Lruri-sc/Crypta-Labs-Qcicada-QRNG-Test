// WaveformChart.swift
// Qcicada

import SwiftUI
import Charts

struct WaveformChart: View {
    let title: String
    let data: [Double]
    let color: Color
    let lineWidth: Double
    let thresholds: [Double]
    let thresholdColor: Color
    let referenceValue: Double?
    let historySize: Int
    let chartBackground: Color
    
    @Environment(\.colorScheme) private var colorScheme
    
    init(
        title: String,
        data: [Double],
        color: Color,
        lineWidth: Double = 1.2,
        thresholds: [Double] = [],
        thresholdColor: Color = .yellow.opacity(0.5),
        referenceValue: Double? = nil,
        historySize: Int = 600,
        chartBackground: Color = .clear
    ) {
        self.title = title
        self.data = data
        self.color = color
        self.lineWidth = lineWidth
        self.thresholds = thresholds
        self.thresholdColor = thresholdColor
        self.referenceValue = referenceValue
        self.historySize = historySize
        self.chartBackground = chartBackground
    }
    
    // Adaptive colors based on light/dark
    private var gridColor: Color {
        colorScheme == .dark
            ? Color(nsColor: .separatorColor).opacity(0.3)
            : Color(nsColor: .separatorColor).opacity(0.2)
    }
    
    private var refLineColor: Color {
        colorScheme == .dark
            ? Color(nsColor: .tertiaryLabelColor)
            : Color(nsColor: .separatorColor)
    }
    
    var body: some View {
        Chart {
            ForEach(Array(data.enumerated()), id: \.offset) { index, value in
                LineMark(
                    x: .value("Sample", index),
                    y: .value(title, value)
                )
                .foregroundStyle(color.gradient)
                .lineStyle(StrokeStyle(lineWidth: lineWidth))
            }
            
            ForEach(thresholds, id: \.self) { threshold in
                RuleMark(y: .value("Threshold", threshold))
                    .foregroundStyle(thresholdColor)
                    .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [6, 4]))
                
                RuleMark(y: .value("Threshold", -threshold))
                    .foregroundStyle(thresholdColor)
                    .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [6, 4]))
            }
            
            if let ref = referenceValue {
                RuleMark(y: .value("Reference", ref))
                    .foregroundStyle(refLineColor)
                    .lineStyle(StrokeStyle(lineWidth: 0.8))
            }
        }
        .chartXScale(domain: 0...max(1, historySize))
        .chartYScale(domain: yDomain)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.3))
                    .foregroundStyle(gridColor)
                AxisValueLabel()
                    .foregroundStyle(.secondary)
                    .font(.system(size: 10, design: .monospaced))
            }
        }
        .chartPlotStyle { plotArea in
            plotArea
                .background(chartBackground)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }
    
    private var yDomain: ClosedRange<Double> {
        guard !data.isEmpty else { return -3...3 }
        let mn = data.min() ?? -3
        let mx = data.max() ?? 3
        let pad = max(0.5, (mx - mn) * 0.15)
        
        if let ref = referenceValue, ref > 0 {
            return max(0, mn - pad)...(mx + pad)
        } else {
            return min(mn - pad, -2)...max(mx + pad, 2)
        }
    }
}

// MARK: - Stat Pill

struct StatPill: View {
    let label: String
    let value: String
    let color: Color
    
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(pillBackground))
    }
    
    @ViewBuilder
    private var pillBackground: Color {
        if colorScheme == .dark {
            return Color(nsColor: .quaternaryLabelColor).opacity(0.5)
        } else {
            return Color(nsColor: .controlBackgroundColor)
        }
    }
}
