import GiveMyRamBackCore
import SwiftUI

struct ServicesListView: View {
    @ObservedObject var engine: FreezeEngine
    @State private var searchText = ""

    private var filteredServices: [TrackedService] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return engine.services }
        return engine.services.filter {
            $0.name.lowercased().contains(query) || $0.executablePath.lowercased().contains(query)
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
                TextField("Поиск фоновых процессов (≥ 30 МБ)", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))

            if filteredServices.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "gearshape.2")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("Тяжёлых фоновых процессов не найдено")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(filteredServices.enumerated()), id: \.element.id) { index, service in
                            ServiceRowView(service: service, engine: engine)
                            if index < filteredServices.count - 1 {
                                Divider()
                                    .padding(.leading, 46)
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
}

private struct ServiceRowView: View {
    let service: TrackedService
    @ObservedObject var engine: FreezeEngine

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: service.isFrozen ? "snowflake.circle.fill" : "gearshape.fill")
                .font(.system(size: 16))
                .foregroundStyle(service.isFrozen ? Color.primary : Color.secondary)
                .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(service.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)

                    if service.pids.count > 1 {
                        Text("\(service.pids.count) проц.")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary.opacity(0.7), in: Capsule())
                    }
                }

                if service.isFrozen {
                    Text("На паузе · PID \(service.mainPID)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.8))
                } else if let reason = service.protectionReason {
                    Text("Защита: \(reason.shortLabel)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    Text("PID \(service.mainPID) · \(service.isAutoFreezeEnabled ? "Автопауза включена" : "Только вручную")")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .help(service.executablePath)

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 2) {
                Text(ByteFormatter.format(service.footprintBytes))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.primary)

                if service.isFrozen && service.reclaimedDRAMBytes >= 5 * 1_048_576 {
                    Text("−\(ByteFormatter.formatCompact(service.reclaimedDRAMBytes)) DRAM")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.primary.opacity(0.8))
                } else if service.cpuPercent >= 1.0 {
                    Text(String(format: "%.0f%% CPU", service.cpuPercent))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            Toggle("", isOn: Binding(
                get: { service.isAutoFreezeEnabled },
                set: { _ in engine.toggleServiceAutoFreeze(serviceKey: service.serviceKey) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .help("Автоматически ставить этот сервис на паузу при простое")

            if service.isFrozen {
                Button("Вернуть") {
                    engine.resumeService(service)
                }
                .buttonStyle(MonochromePillButtonStyle(prominent: true))
            } else {
                Button("Пауза") {
                    engine.freezeService(service)
                }
                .buttonStyle(MonochromePillButtonStyle(prominent: false))
                .disabled(service.isProtected)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(service.isFrozen ? Color.primary.opacity(0.06) : Color.clear)
    }
}
