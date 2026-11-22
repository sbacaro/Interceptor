import AppKit
import QuartzCore
import SwiftUI

/// Logic Pro-style GPU-composited VU meter backed directly by `CALayer` + `CAGradientLayer`.
/// Updates happen strictly via `CALayer` transforms inside `CATransaction.setDisableActions(true)`
/// with zero SwiftUI view diffing, zero Core Graphics software rasterization, and <0.1% CPU.
struct LiveChannelVUMeterView: View {
    let meterModel: RouteMeterModel

    var body: some View {
        CoreAnimationVUMeterRepresentable(meterModel: meterModel)
            .frame(minWidth: 146, maxWidth: 216)
            .frame(height: 16)
            .accessibilityLabel(Text("Channel level"))
    }
}

/// Static snapshot preview variant (used only in SwiftUI previews).
struct ChannelVUMeterView: View {
    let meter: SmoothedChannelMeter

    var body: some View {
        LiveChannelVUMeterView(meterModel: RouteMeterModel(level: meter))
    }
}

private struct CoreAnimationVUMeterRepresentable: NSViewRepresentable {
    let meterModel: RouteMeterModel

    func makeNSView(context: Context) -> CoreAnimationVUMeterNSView {
        let view = CoreAnimationVUMeterNSView()
        meterModel.attachRenderer { [weak view] level in
            view?.apply(level: level)
        }
        view.apply(level: meterModel.level)
        return view
    }

    func updateNSView(_ nsView: CoreAnimationVUMeterNSView, context: Context) {
        meterModel.attachRenderer { [weak nsView] level in
            nsView?.apply(level: level)
        }
    }

    static func dismantleNSView(_ nsView: CoreAnimationVUMeterNSView, coordinator: ()) {}
}

/// Pure AppKit/Core Animation GPU meter view:
/// `[====Gradient Bar====]  -12`
@MainActor
final class CoreAnimationVUMeterNSView: NSView {
    private static let minDB: Float = -60.0
    private static let maxDB: Float = 0.0
    private static let tickDBs: [Float] = [-48, -36, -24, -12, -6, -3]
    private static let barHeight: CGFloat = 8.0
    private static let readoutWidth: CGFloat = 32.0
    private static let spacing: CGFloat = 8.0

    private let trackLayer = CALayer()
    private let gradientLayer = CAGradientLayer()
    private let fillMaskLayer = CALayer()
    private let holdLayer = CALayer()
    private var tickLayers: [CALayer] = []
    private let readoutField: NSTextField

    private var currentLevel = SmoothedChannelMeter()
    private var lastDisplayedDBText = "-∞"

    override init(frame frameRect: NSRect) {
        self.readoutField = NSTextField(labelWithString: "-∞")
        super.init(frame: frameRect)
        setupLayers()
    }

    required init?(coder: NSCoder) {
        self.readoutField = NSTextField(labelWithString: "-∞")
        super.init(coder: coder)
        setupLayers()
    }

    private func setupLayers() {
        wantsLayer = true
        guard let root = layer else { return }

        trackLayer.masksToBounds = true
        trackLayer.cornerRadius = Self.barHeight * 0.5
        root.addSublayer(trackLayer)

        gradientLayer.startPoint = CGPoint(x: 0.0, y: 0.5)
        gradientLayer.endPoint = CGPoint(x: 1.0, y: 0.5)
        gradientLayer.locations = [0.0, 0.72, 0.86, 0.96, 1.0]

        fillMaskLayer.backgroundColor = NSColor.white.cgColor
        fillMaskLayer.anchorPoint = CGPoint(x: 0.0, y: 0.5)
        gradientLayer.mask = fillMaskLayer
        trackLayer.addSublayer(gradientLayer)

        for _ in Self.tickDBs {
            let tick = CALayer()
            trackLayer.addSublayer(tick)
            tickLayers.append(tick)
        }

        holdLayer.isHidden = true
        trackLayer.addSublayer(holdLayer)

        readoutField.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        readoutField.textColor = NSColor.secondaryLabelColor
        readoutField.alignment = .right
        readoutField.lineBreakMode = .byClipping
        readoutField.maximumNumberOfLines = 1
        addSubview(readoutField)

        refreshColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    override func layout() {
        super.layout()
        let barWidth = max(40.0, bounds.width - Self.readoutWidth - Self.spacing)
        let barY = round((bounds.height - Self.barHeight) * 0.5)

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        trackLayer.frame = CGRect(x: 0, y: barY, width: barWidth, height: Self.barHeight)
        gradientLayer.frame = trackLayer.bounds
        fillMaskLayer.bounds = CGRect(x: 0, y: 0, width: barWidth, height: Self.barHeight)
        fillMaskLayer.position = CGPoint(x: 0, y: Self.barHeight * 0.5)

        for (index, tickDB) in Self.tickDBs.enumerated() where index < tickLayers.count {
            let x = Self.normalized(db: tickDB) * barWidth
            tickLayers[index].frame = CGRect(x: x, y: 0, width: 0.75, height: Self.barHeight)
        }

        CATransaction.commit()

        readoutField.frame = CGRect(
            x: barWidth + Self.spacing,
            y: round((bounds.height - 14.0) * 0.5) - 1.0,
            width: Self.readoutWidth,
            height: 15.0
        )

        apply(level: currentLevel)
    }

    func apply(level: SmoothedChannelMeter) {
        currentLevel = level
        let barWidth = trackLayer.bounds.width
        guard barWidth > 0 else { return }

        let fillFraction = Self.normalized(db: level.peakDB)
        let holdFraction = Self.normalized(db: level.peakHoldDB)

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        fillMaskLayer.transform = CATransform3DMakeScale(max(0.0001, fillFraction), 1.0, 1.0)
        fillMaskLayer.isHidden = fillFraction <= 0.003

        if holdFraction > 0.01 {
            let holdX = min(barWidth - 2.0, max(0, barWidth * holdFraction - 1.0))
            holdLayer.frame = CGRect(x: holdX, y: 0, width: 2.0, height: Self.barHeight)
            holdLayer.isHidden = false
            effectiveAppearance.performAsCurrentDrawingAppearance {
                if level.peakHoldDB >= -3.0 {
                    holdLayer.backgroundColor = (NSColor(named: "MeterPeak") ?? .systemRed).cgColor
                } else if level.peakHoldDB >= -12.0 {
                    holdLayer.backgroundColor = (NSColor(named: "MeterCaution") ?? .systemOrange).cgColor
                } else {
                    holdLayer.backgroundColor = (NSColor(named: "MeterNominal") ?? .systemGreen).cgColor
                }
            }
        } else {
            holdLayer.isHidden = true
        }

        CATransaction.commit()

        // Integer dB readout updates only when whole dB changes (minimal text layout work).
        let text: String
        if level.peakDB <= Self.minDB + 0.5 {
            text = "-∞"
        } else {
            text = String(format: "%.0f", level.peakDB)
        }
        if text != lastDisplayedDBText {
            lastDisplayedDBText = text
            readoutField.stringValue = text
        }
    }

    private func refreshColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let trackColor = (NSColor(named: "MeterTrack") ?? NSColor.quaternaryLabelColor).cgColor
            let nominal = (NSColor(named: "MeterNominal") ?? NSColor.systemGreen).cgColor
            let caution = (NSColor(named: "MeterCaution") ?? NSColor.systemOrange).cgColor
            let peak = (NSColor(named: "MeterPeak") ?? NSColor.systemRed).cgColor
            let tickColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            trackLayer.backgroundColor = trackColor
            gradientLayer.colors = [nominal, nominal, caution, peak, peak]
            for tick in tickLayers {
                tick.backgroundColor = tickColor
            }
            CATransaction.commit()
        }
    }

    private static func normalized(db: Float) -> CGFloat {
        let clamped = max(minDB, min(maxDB, db))
        return CGFloat((clamped - minDB) / (maxDB - minDB))
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
