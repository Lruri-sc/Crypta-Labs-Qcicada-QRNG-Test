// WaveformChart.swift
// Qcicada

import SwiftUI
import Charts
import Accessibility

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
    private var refLineColor: Color {
        colorScheme == .dark
            ? Color(nsColor: .tertiaryLabelColor)
            : Color(nsColor: .separatorColor)
    }

    var body: some View {
        let domain = yDomain
        // Swift Charts keeps drawing the axis, grid and plot background, which only
        // change with the Y range. The samples and rule lines change with every
        // reading, so they are drawn by one canvas placed exactly over the plot area
        // instead of being rebuilt as hundreds of chart marks.
        WaveformAxes(title: title, historySize: historySize, yDomain: domain, chartBackground: chartBackground)
            .equatable()
            .overlayPreferenceValue(WaveformPlotAreaKey.self) { anchor in
                GeometryReader { geometry in
                    if let anchor {
                        let plot = geometry[anchor]
                        series(domain: domain)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .frame(width: plot.width, height: plot.height)
                            .offset(x: plot.minX, y: plot.minY)
                    }
                }
            }
    }

    /// Same geometry, order and styles as the former LineMark/RuleMark content:
    /// the series first, then the threshold pairs, then the reference line.
    private func series(domain: ClosedRange<Double>) -> some View {
        Canvas { context, size in
            let span = domain.upperBound - domain.lowerBound
            guard span > 0 else { return }
            func yPosition(_ value: Double) -> CGFloat {
                size.height - CGFloat((value - domain.lowerBound) / span) * size.height
            }
            if data.count > 1 {
                let step = size.width / CGFloat(max(1, historySize))
                var line = Path()
                line.move(to: CGPoint(x: 0, y: yPosition(data[0])))
                for index in 1..<data.count {
                    line.addLine(to: CGPoint(x: CGFloat(index) * step, y: yPosition(data[index])))
                }
                context.stroke(line, with: .style(color.gradient), style: StrokeStyle(lineWidth: lineWidth))
            }
            func rule(_ value: Double, color: Color, style: StrokeStyle) {
                let y = yPosition(value)
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(path, with: .color(color), style: style)
            }
            for threshold in thresholds {
                rule(threshold, color: thresholdColor, style: StrokeStyle(lineWidth: 0.5, dash: [6, 4]))
                rule(-threshold, color: thresholdColor, style: StrokeStyle(lineWidth: 0.5, dash: [6, 4]))
            }
            if let ref = referenceValue {
                rule(ref, color: refLineColor, style: StrokeStyle(lineWidth: 0.8))
            }
        }
        .accessibilityLabel(Text(title))
        .accessibilityChartDescriptor(
            WaveformChartDescriptor(title: title, data: data, yDomain: domain, historySize: historySize)
        )
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

// MARK: - Axes

/// The plot area's frame inside a `WaveformAxes` chart.
private struct WaveformPlotAreaKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

/// The part of the chart that Swift Charts draws. It is equatable so a new sample
/// that leaves the Y range unchanged does not make Swift Charts lay it out again.
private struct WaveformAxes: View, Equatable {
    let title: String
    let historySize: Int
    let yDomain: ClosedRange<Double>
    let chartBackground: Color

    @Environment(\.colorScheme) private var colorScheme

    static func == (lhs: WaveformAxes, rhs: WaveformAxes) -> Bool {
        lhs.title == rhs.title && lhs.historySize == rhs.historySize
            && lhs.yDomain == rhs.yDomain && lhs.chartBackground == rhs.chartBackground
    }

    private var gridColor: Color {
        colorScheme == .dark
            ? Color(nsColor: .separatorColor).opacity(0.3)
            : Color(nsColor: .separatorColor).opacity(0.2)
    }

    var body: some View {
        Chart {
            // Invisible: gives the chart a quantitative Y value to build its axis from.
            RuleMark(y: .value(title, yDomain.lowerBound))
                .opacity(0)
                .accessibilityHidden(true)
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
        .chartBackground { proxy in
            Color.clear.preference(key: WaveformPlotAreaKey.self, value: proxy.plotFrame)
        }
    }
}

// MARK: - Accessibility

/// Describes the canvas-drawn series to VoiceOver and Audio Graphs. The descriptor
/// is only built when an assistive technology asks for it.
private struct WaveformChartDescriptor: AXChartDescriptorRepresentable {
    let title: String
    let data: [Double]
    let yDomain: ClosedRange<Double>
    let historySize: Int

    func makeChartDescriptor() -> AXChartDescriptor {
        AXChartDescriptor(title: title, summary: nil, xAxis: xAxis, yAxis: yAxis,
                          additionalAxes: [], series: [series])
    }

    func updateChartDescriptor(_ descriptor: AXChartDescriptor) {
        descriptor.title = title
        descriptor.xAxis = xAxis
        descriptor.yAxis = yAxis
        descriptor.series = [series]
    }

    private var xAxis: AXNumericDataAxisDescriptor {
        AXNumericDataAxisDescriptor(title: "Sample", range: 0...Double(max(1, historySize)),
                                    gridlinePositions: []) { String(format: "%.0f", $0) }
    }

    private var yAxis: AXNumericDataAxisDescriptor {
        AXNumericDataAxisDescriptor(title: title, range: yDomain,
                                    gridlinePositions: []) { String(format: "%.2f", $0) }
    }

    private var series: AXDataSeriesDescriptor {
        AXDataSeriesDescriptor(name: title, isContinuous: true, dataPoints: data.enumerated().map {
            AXDataPoint(x: Double($0.offset), y: $0.element)
        })
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

    private var pillBackground: Color {
        if colorScheme == .dark {
            return Color(nsColor: .quaternaryLabelColor).opacity(0.5)
        } else {
            return Color(nsColor: .controlBackgroundColor)
        }
    }
}
