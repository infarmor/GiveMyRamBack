import GiveMyRamBackCore
import SwiftUI

struct MemorySparklineView: View {
    let points: [MemoryHistoryPoint]
    let pressure: MemoryPressureLevel

    var body: some View {
        Canvas { context, size in
            guard size.width > 4, size.height > 4 else { return }

            let lineOpacity: Double
            switch pressure {
            case .normal: lineOpacity = 0.72
            case .warning: lineOpacity = 0.88
            case .critical: lineOpacity = 1.0
            }

            if points.count < 2 {
                let y = size.height * 0.5
                var flat = Path()
                flat.move(to: CGPoint(x: 0, y: y))
                flat.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(flat, with: .color(.primary.opacity(0.4)), lineWidth: 1.5)
                return
            }

            let stepX = size.width / CGFloat(max(1, points.count - 1))
            var usedPath = Path()
            var fillPath = Path()

            for (index, point) in points.enumerated() {
                let x = CGFloat(index) * stepX
                let clamped = min(1.0, max(0.0, point.usedRatio))
                let y = size.height - (CGFloat(clamped) * (size.height - 4)) - 2
                let pt = CGPoint(x: x, y: y)
                if index == 0 {
                    usedPath.move(to: pt)
                    fillPath.move(to: CGPoint(x: x, y: size.height))
                    fillPath.addLine(to: pt)
                } else {
                    usedPath.addLine(to: pt)
                    fillPath.addLine(to: pt)
                }
            }

            fillPath.addLine(to: CGPoint(x: CGFloat(points.count - 1) * stepX, y: size.height))
            fillPath.closeSubpath()

            context.fill(
                fillPath,
                with: .linearGradient(
                    Gradient(colors: [.primary.opacity(0.20), .primary.opacity(0.01)]),
                    startPoint: CGPoint(x: 0, y: 0),
                    endPoint: CGPoint(x: 0, y: size.height)
                )
            )
            context.stroke(usedPath, with: .color(.primary.opacity(lineOpacity)), lineWidth: 1.5)
        }
    }
}
