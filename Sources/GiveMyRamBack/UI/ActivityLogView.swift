import GiveMyRamBackCore
import SwiftUI

struct ActivityLogView: View {
    @ObservedObject var engine: FreezeEngine

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(engine.events.isEmpty ? "События" : "Событий: \(engine.events.count)")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if !engine.events.isEmpty {
                    Button("Очистить") {
                        engine.clearEvents()
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11.5))
                }
            }

            if engine.events.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("История действий пока пуста")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(engine.events.enumerated()), id: \.element.id) { index, event in
                            HStack(spacing: 10) {
                                icon(for: event.kind)
                                    .frame(width: 22)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(event.title)
                                        .font(.system(size: 12.5, weight: .medium))
                                    Text(event.detail)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Text(Self.timeFormatter.string(from: event.timestamp))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 11)
                            .padding(.vertical, 8)

                            if index < engine.events.count - 1 {
                                Divider()
                                    .padding(.leading, 43)
                                    .opacity(0.55)
                            }
                        }
                    }
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 11))
                    .overlay(
                        RoundedRectangle(cornerRadius: 11)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                    )
                    .padding(.vertical, 1)
                }
            }
        }
    }

    @ViewBuilder
    private func icon(for kind: ActivityEvent.Kind) -> some View {
        switch kind {
        case .frozen:
            Image(systemName: "snowflake.circle.fill")
                .foregroundStyle(.primary)
        case .resumed:
            Image(systemName: "play.circle.fill")
                .foregroundStyle(.primary.opacity(0.72))
        case .recovered:
            Image(systemName: "arrow.uturn.backward.circle.fill")
                .foregroundStyle(.primary.opacity(0.85))
        case .relaunched:
            Image(systemName: "arrow.clockwise.circle.fill")
                .foregroundStyle(.primary.opacity(0.8))
        case .skipped:
            Image(systemName: "shield.fill")
                .foregroundStyle(.secondary)
        }
    }
}
