// WaveformArea.swift
// Qcicada

import SwiftUI

/// The live statistics and charts. This is a separate view so that the values
/// published for each sample only refresh this area: the window toolbar and its
/// AppKit controls no longer take part in every update.
struct WaveformArea: View {
    let engine: RandomTestEngine
    let settings: AppSettings
    let showAuditProgress: Bool
    let auditStatus: String

    var body: some View {
        VStack(spacing: 10) {
            statsBar

            if showAuditProgress {
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text(auditStatus)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Instant Z
                VStack(alignment: .leading, spacing: 4) {
                    chartHeader(
                        title: tx("chart.header.instant_z"),
                        value: engine.instantZ,
                        hi: engine.peakInstHi,
                        lo: engine.peakInstLo,
                        color: settings.instantZColor
                    )
                    WaveformChart(
                        title: tx("chart.instant_z"),
                        data: engine.izHistory,
                        color: settings.instantZColor,
                        lineWidth: settings.chartLineWidth,
                        thresholds: [1.96, 2.58],
                        thresholdColor: settings.thresholdColor,
                        referenceValue: 0,
                        historySize: engine.historySize,
                        chartBackground: settings.chartBackground
                    )
                    .frame(maxHeight: .infinity)
                }

                // Inset divider (Apple style: not edge-to-edge)
                if settings.showDividers {
                    Divider()
                        .opacity(settings.dividerOpacity)
                        .padding(.horizontal, 4)
                }

                // Cumulative Z
                VStack(alignment: .leading, spacing: 4) {
                    chartHeader(
                        title: tx("chart.header.cumulative_z"),
                        value: engine.cumulativeZ,
                        hi: engine.peakCumHi,
                        lo: engine.peakCumLo,
                        color: settings.cumulativeZColor
                    )
                    WaveformChart(
                        title: tx("chart.cumulative_z"),
                        data: engine.czHistory,
                        color: settings.cumulativeZColor,
                        lineWidth: settings.chartLineWidth,
                        thresholds: [1.96],
                        thresholdColor: settings.thresholdColor,
                        referenceValue: 0,
                        historySize: engine.historySize,
                        chartBackground: settings.chartBackground
                    )
                    .frame(maxHeight: .infinity)
                }

                if settings.showDividers {
                    Divider()
                        .opacity(settings.dividerOpacity)
                        .padding(.horizontal, 4)
                }

                // Variance
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(LocalizedStringResource("chart.variance_axis"))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(settings.varianceColor)
                        StatPill(label: tx("pill.var"), value: String(format: "%.4f", engine.izVariance), color: settings.varianceColor)
                        StatPill(
                            label: tx("pill.z_var"),
                            value: String(format: "%+.2f", engine.varianceZScore),
                            color: abs(engine.varianceZScore) > 1.96 ? .red : .secondary
                        )
                    }
                    WaveformChart(
                        title: tx("chart.variance"),
                        data: engine.varHistory,
                        color: settings.varianceColor,
                        lineWidth: settings.chartLineWidth,
                        referenceValue: 1.0,
                        historySize: engine.historySize,
                        chartBackground: settings.chartBackground
                    )
                    .frame(height: 80)
                }
            }
        }
    }

    // MARK: - Stats Bar

    private var statsBar: some View {
        HStack(spacing: 6) {
            StatPill(label: tx("pill.sample_index"), value: "\(engine.sampleCount)", color: .primary)
            StatPill(label: tx("pill.bits"), value: formatNumber(engine.totalBits), color: .primary)
            StatPill(
                label: tx("pill.ones_pct"),
                value: engine.totalBits > 0
                    ? String(format: "%.4f%%", Double(engine.totalOnes) / Double(engine.totalBits) * 100)
                    : tx("placeholder.em_dash"),
                color: .primary
            )
            StatPill(label: tx("pill.mean"), value: String(format: "%+.3f", engine.izMean), color: .secondary)
            Spacer()
            significanceLabel
        }
    }

    @ViewBuilder
    private var significanceLabel: some View {
        let z = engine.cumulativeZ
        let label = localizedSignificance(z)
        if !label.isEmpty {
            Text(label)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(significanceColor(z))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(significanceColor(z).opacity(0.12), in: Capsule())
        }
    }

    private func chartHeader(title: String, value: Double, hi: Double, lo: Double, color: Color) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(color)
            StatPill(label: tx("pill.z"), value: String(format: "%+.2f", value), color: color)
            StatPill(label: tx("pill.high"), value: String(format: "%+.2f", hi > -900 ? hi : 0), color: .green)
            StatPill(label: tx("pill.low"), value: String(format: "%+.2f", lo < 900 ? lo : 0), color: .red)
        }
    }

    private func significanceColor(_ z: Double) -> Color {
        let az = abs(z)
        if az >= 3.29 { return .red }
        if az >= 2.58 { return .orange }
        if az >= 1.96 { return .yellow }
        if az >= 1.645 { return .mint }
        return .secondary
    }

    private func formatNumber(_ n: Int) -> String {
        if n >= 1_000_000_000 { return String(format: "%.1fB", Double(n) / 1e9) }
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1e6) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1e3) }
        return "\(n)"
    }

    private func tx(_ key: String) -> String {
        String(localized: String.LocalizationValue(key), locale: settings.stringResolutionLocale ?? .current)
    }

    private func localizedSignificance(_ z: Double) -> String {
        let code = RandomTestEngine.interpret(z)
        switch code {
        case "EXTREME": return tx("sig.extreme")
        case "VERY SIG": return tx("sig.very_significant")
        case "SIGNIF": return tx("sig.significant")
        case "MARGINAL": return tx("sig.marginal")
        case "trend": return tx("sig.trend")
        default: return code
        }
    }
}
