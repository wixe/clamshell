import AppKit
import Foundation

public final class TelemetryGraphView: NSView {
    public struct Sample {
        public let timestamp: Date
        public let brightnessPercent: Double
        public let isClamshellClosed: Bool
        public let isAwake: Bool
    }

    private var samples: [Sample] = []
    private let maxSamples = 180

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func addSample(brightnessPercent: Double, isClamshellClosed: Bool, isAwake: Bool) {
        let now = Date()
        if let last = samples.last, now.timeIntervalSince(last.timestamp) < 2.0 {
            samples[samples.count - 1] = Sample(
                timestamp: now,
                brightnessPercent: brightnessPercent,
                isClamshellClosed: isClamshellClosed,
                isAwake: isAwake
            )
        } else {
            samples.append(Sample(
                timestamp: now,
                brightnessPercent: brightnessPercent,
                isClamshellClosed: isClamshellClosed,
                isAwake: isAwake
            ))
            if samples.count > maxSamples {
                samples.removeFirst(samples.count - maxSamples)
            }
        }
        needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let bounds = self.bounds
        NSColor.controlBackgroundColor.withAlphaComponent(0.55).setFill()
        let bgPath = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
        bgPath.fill()

        let padLeft: CGFloat = 28
        let padRight: CGFloat = 8
        let padTop: CGFloat = 10
        let padBottom: CGFloat = 16
        let plotRect = NSRect(
            x: padLeft,
            y: padBottom,
            width: max(10, bounds.width - padLeft - padRight),
            height: max(10, bounds.height - padTop - padBottom)
        )

        let gridAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ]

        for pct in [0, 50, 100] {
            let y = plotRect.minY + (CGFloat(pct) / 100.0) * plotRect.height
            let line = NSBezierPath()
            line.move(to: NSPoint(x: plotRect.minX, y: y))
            line.line(to: NSPoint(x: plotRect.maxX, y: y))
            NSColor.separatorColor.withAlphaComponent(0.45).setStroke()
            line.lineWidth = 0.5
            line.stroke()

            let label = "\(pct)%" as NSString
            label.draw(at: NSPoint(x: 2, y: y - 6), withAttributes: gridAttrs)
        }

        guard !samples.isEmpty else { return }

        let count = samples.count
        let path = NSBezierPath()
        let fillPath = NSBezierPath()

        for (i, s) in samples.enumerated() {
            let fracX = count == 1 ? 1.0 : CGFloat(i) / CGFloat(max(1, count - 1))
            let x = plotRect.minX + fracX * plotRect.width
            let clamped = max(0.0, min(100.0, s.brightnessPercent))
            let y = plotRect.minY + CGFloat(clamped / 100.0) * plotRect.height

            if i == 0 {
                path.move(to: NSPoint(x: x, y: y))
                fillPath.move(to: NSPoint(x: x, y: plotRect.minY))
                fillPath.line(to: NSPoint(x: x, y: y))
            } else {
                path.line(to: NSPoint(x: x, y: y))
                fillPath.line(to: NSPoint(x: x, y: y))
            }

            if i == count - 1 {
                if count == 1 {
                    path.move(to: NSPoint(x: plotRect.minX, y: y))
                    path.line(to: NSPoint(x: plotRect.maxX, y: y))
                    fillPath.move(to: NSPoint(x: plotRect.minX, y: plotRect.minY))
                    fillPath.line(to: NSPoint(x: plotRect.minX, y: y))
                    fillPath.line(to: NSPoint(x: plotRect.maxX, y: y))
                }
                fillPath.line(to: NSPoint(x: x, y: plotRect.minY))
                fillPath.close()
            }
        }

        let lastSample = samples.last!
        let strokeColor: NSColor = lastSample.isClamshellClosed
            ? .systemPurple
            : (lastSample.brightnessPercent <= 1.0 ? .systemIndigo : .systemCyan)

        strokeColor.withAlphaComponent(0.18).setFill()
        fillPath.fill()

        strokeColor.setStroke()
        path.lineWidth = 2.0
        path.stroke()
    }
}
