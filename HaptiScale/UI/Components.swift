//
//  Components.swift
//  HaptiScale
//
//  Small reusable views: quality badge, live waveform, spectrum plot, result card.
//

import SwiftUI

// MARK: - Quality badge

struct QualityBadge: View {
    let quality: SetupQuality

    private var color: Color {
        switch quality {
        case .good: return .green
        case .marginal: return .yellow
        case .bad: return .red
        }
    }

    private var label: String {
        switch quality {
        case .good: return "Good setup"
        case .marginal: return "Marginal"
        case .bad: return "Rejected"
        }
    }

    var body: some View {
        Label(label, systemImage: quality.symbol)
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

// MARK: - Live waveform

struct WaveformView: View {
    let samples: [Float]

    var body: some View {
        Canvas { context, size in
            guard samples.count > 1 else { return }
            let midY = size.height / 2
            let stepX = size.width / CGFloat(samples.count - 1)
            let gain: CGFloat = 6   // visual gain; mic values are small
            var path = Path()
            for (i, s) in samples.enumerated() {
                let x = CGFloat(i) * stepX
                let y = midY - CGFloat(s) * midY * gain
                if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            context.stroke(path, with: .color(.green.opacity(0.85)), lineWidth: 1.5)
        }
        .frame(height: 70)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Spectrum plot

struct SpectrumView: View {
    let magnitudes: [Float]
    let title: String
    var logScale: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Canvas { context, size in
                guard !magnitudes.isEmpty else { return }
                let vals = logScale ? magnitudes.map { log10(max($0, 1e-6)) } : magnitudes.map { $0 }
                let minV = vals.min() ?? 0
                let maxV = vals.max() ?? 1
                let range = max(maxV - minV, 1e-6)
                let stepX = size.width / CGFloat(vals.count - 1)
                var path = Path()
                for (i, v) in vals.enumerated() {
                    let x = CGFloat(i) * stepX
                    let norm = CGFloat((v - minV) / range)
                    let y = size.height - norm * size.height
                    if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                    else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
                context.stroke(path, with: .color(.teal), lineWidth: 1.2)
            }
            .frame(height: 90)
            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

// MARK: - Result card

struct ResultCard: View {
    let result: MeasurementResult

    var body: some View {
        VStack(spacing: 10) {
            if result.quality == .bad {
                Text("—")
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                    .foregroundStyle(.red)
                Text("Setup rejected")
                    .font(.headline).foregroundStyle(.red)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(Int(result.grams.rounded()))")
                        .font(.system(size: 64, weight: .bold, design: .rounded))
                    Text("g").font(.title2).foregroundStyle(.secondary)
                }
                Text("± \(Int(result.ciHalfWidth.rounded())) g")
                    .font(.headline).foregroundStyle(.secondary)
            }
            QualityBadge(quality: result.quality)

            if !result.issues.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(result.issues) { issue in
                        Label(issue.message, systemImage: issue.severity.symbol)
                            .font(.footnote)
                            .foregroundStyle(issue.severity == .bad ? .red : .yellow)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            }

            Text(String(format: "coherence %.2f", result.coherence))
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
    }
}
