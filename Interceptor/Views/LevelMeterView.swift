import SwiftUI

/// High-precision horizontal dBFS VU meter bar rendered via SwiftUI `Canvas`
/// with RMS fill, translucent peak envelope, peak-hold hairline, and studio dB graduation ticks.
/// Used directly inside each mono channel row (zero `GeometryReader` layout cycles).
struct ChannelVUMeterView: View {
    let meter: SmoothedChannelMeter

    private static let minDB: Float = -60.0
    private static let maxDB: Float = 0.0
    private static let tickDBs: [Float] = [-48, -36, -24, -12, -6, -3]

    var body: some View {
        HStack(spacing: 8) {
            Canvas { context, size in
                let trackRect = CGRect(origin: .zero, size: size)
                let cornerRadius = size.height * 0.5
                let trackPath = Path(roundedRect: trackRect, cornerRadius: cornerRadius)

                context.fill(trackPath, with: .color(Color("MeterTrack")))

                let rmsFraction = normalizedPosition(forDB: meter.rmsDB)
                let peakFraction = normalizedPosition(forDB: meter.peakDB)
                let holdFraction = normalizedPosition(forDB: meter.peakHoldDB)

                let meterGradient = Gradient(stops: [
                    .init(color: Color("MeterNominal"), location: 0.0),
                    .init(color: Color("MeterNominal"), location: 0.72),
                    .init(color: Color("MeterCaution"), location: 0.86),
                    .init(color: Color("MeterPeak"), location: 0.96),
                    .init(color: Color("MeterPeak"), location: 1.0)
                ])
                let linearShading = GraphicsContext.Shading.linearGradient(
                    meterGradient,
                    startPoint: CGPoint(x: 0, y: size.height * 0.5),
                    endPoint: CGPoint(x: size.width, y: size.height * 0.5)
                )

                context.clip(to: trackPath)

                if peakFraction > 0.002 {
                    let peakRect = CGRect(x: 0, y: 0, width: size.width * peakFraction, height: size.height)
                    context.opacity = 0.38
                    context.fill(Path(peakRect), with: linearShading)
                    context.opacity = 1.0
                }

                if rmsFraction > 0.002 {
                    let rmsRect = CGRect(x: 0, y: 0, width: size.width * rmsFraction, height: size.height)
                    context.fill(Path(rmsRect), with: linearShading)
                }

                // Subtle studio graduation hairlines
                for tickDB in Self.tickDBs {
                    let x = normalizedPosition(forDB: tickDB) * size.width
                    let tickRect = CGRect(x: x, y: 0, width: 0.75, height: size.height)
                    context.fill(Path(tickRect), with: .color(Color.primary.opacity(0.08)))
                }

                if holdFraction > 0.01 {
                    let holdX = min(size.width - 2.0, max(0, size.width * holdFraction - 1.0))
                    let holdRect = CGRect(x: holdX, y: 0, width: 2.0, height: size.height)
                    let holdColor: Color = meter.peakHoldDB >= -3.0
                        ? Color("MeterPeak")
                        : (meter.peakHoldDB >= -12.0 ? Color("MeterCaution") : Color("MeterNominal"))
                    context.fill(Path(holdRect), with: .color(holdColor))
                }
            }
            .frame(minWidth: 110, maxWidth: 180)
            .frame(height: 8)
            .accessibilityLabel(Text("Channel level"))
            .accessibilityValue(Text(formattedPeakReadout))

            Text(formattedPeakReadout)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
        }
    }

    private var formattedPeakReadout: String {
        if meter.peakDB <= Self.minDB + 0.2 {
            return "-∞"
        }
        return String(format: "%.1f", meter.peakDB)
    }

    private func normalizedPosition(forDB db: Float) -> CGFloat {
        let clamped = max(Self.minDB, min(Self.maxDB, db))
        return CGFloat((clamped - Self.minDB) / (Self.maxDB - Self.minDB))
    }
}

#Preview("Channel VU Meter") {
    VStack(spacing: 10) {
        ChannelVUMeterView(
            meter: SmoothedChannelMeter(rmsDB: -18.5, peakDB: -12.2, peakHoldDB: -8.0, peakHoldTimestamp: 0, isClipped: false)
        )
        ChannelVUMeterView(
            meter: SmoothedChannelMeter(rmsDB: -6.0, peakDB: -1.5, peakHoldDB: -0.5, peakHoldTimestamp: 0, isClipped: false)
        )
    }
    .padding()
    .frame(width: 240)
}
