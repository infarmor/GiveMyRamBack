import GiveMyRamBackCore
import SwiftUI

enum MainTab: String, CaseIterable, Identifiable {
    case apps
    case services
    case log

    var id: String { rawValue }
}

struct PopoverRootView: View {
    @ObservedObject var engine: FreezeEngine
    @ObservedObject var updates: UpdateChecker
    let isDetached: Bool
    let onToggleDetach: () -> Void
    let onQuit: () -> Void

    @State private var selectedTab: MainTab = .apps
    @State private var isShowingSettings = false

    private var eligibleBatchApps: [TrackedApp] {
        engine.apps.filter { $0.isEligibleForBatchFreezeNow }
    }

    private var eligibleBatchBytes: UInt64 {
        eligibleBatchApps.reduce(0) { $0 + $1.footprintBytes }
    }

    var body: some View {
        ZStack {
            dashboardView
                .opacity(isShowingSettings ? 0 : 1)
                .allowsHitTesting(!isShowingSettings)

            if isShowingSettings {
                SettingsView(
                    engine: engine,
                    updates: updates,
                    onBack: {
                        withAnimation(.snappy(duration: 0.22)) {
                            isShowingSettings = false
                        }
                    },
                    onQuit: onQuit
                )
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .tint(.primary)
        .frame(minWidth: 440, idealWidth: 460, minHeight: 570, idealHeight: 620)
        .background(
            Button("") {
                withAnimation(.snappy(duration: 0.22)) {
                    isShowingSettings.toggle()
                }
            }
            .keyboardShortcut(",", modifiers: .command)
            .hidden()
        )
    }

    private var dashboardView: some View {
        VStack(spacing: 12) {
            headerView
            if let release = updates.visibleUpdate {
                updateBanner(release)
            }
            memorySummaryCard
            actionStrip

            Picker("", selection: $selectedTab) {
                ForEach(MainTab.allCases) { tab in
                    Text(tabLabel(tab)).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Group {
                switch selectedTab {
                case .apps:
                    AppsListView(engine: engine)
                case .services:
                    ServicesListView(engine: engine)
                case .log:
                    ActivityLogView(engine: engine)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(14)
    }

    private func updateBanner(_ release: ReleaseInfo) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 14))
            VStack(alignment: .leading, spacing: 1) {
                Text("Доступна версия \(release.version)")
                    .font(.system(size: 12, weight: .semibold))
                Text("У вас \(updates.currentVersion)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Скачать") {
                NSWorkspace.shared.open(release.url)
            }
            .buttonStyle(MonochromePillButtonStyle(prominent: true))
            Button {
                updates.dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Скрыть до следующей версии")
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.primary.opacity(0.14), lineWidth: 0.5))
    }

    private func tabLabel(_ tab: MainTab) -> String {
        switch tab {
        case .apps:
            return String(localized: "Приложения")
        case .services:
            return engine.services.isEmpty ? String(localized: "Сервисы") : String(localized: "Сервисы (\(engine.services.count))")
        case .log:
            return String(localized: "Журнал")
        }
    }

    private var headerView: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: 30, height: 30)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.primary.opacity(0.14), lineWidth: 0.5)
                    )
                Image(systemName: "memorychip.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
            }

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text("Give my ram back")
                        .font(.system(size: 13.5, weight: .semibold))

                    pressurePill
                    batteryPill
                }

                Text(subtitleText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            Toggle("", isOn: $engine.settings.isAutoFreezeEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .help("Автоматически ставить неактивные программы на паузу")

            Button {
                onToggleDetach()
            } label: {
                Image(systemName: isDetached ? "menubar.arrow.up.rectangle" : "macwindow.on.rectangle")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isDetached ? Text("Вернуть в строку меню") : Text("Закрепить отдельным окном"))

            Button {
                withAnimation(.snappy(duration: 0.22)) {
                    isShowingSettings = true
                }
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Настройки (⌘,)")
        }
    }

    private var subtitleText: String {
        if !engine.settings.isAutoFreezeEnabled {
            return String(localized: "Автоматический режим отключён")
        }
        let mins = max(
            1,
            Int(
                FreezePolicy.effectiveIdleTimeoutSeconds(
                    settings: engine.settings,
                    pressure: engine.memoryStats.pressure,
                    powerSource: engine.memoryStats.powerSource
                ) / 60.0
            )
        )
        return String(localized: "Пауза фона после \(mins) мин бездействия")
    }

    private var pressurePill: some View {
        let level = engine.memoryStats.pressure
        let dotOpacity: Double = level == .critical ? 1.0 : (level == .warning ? 0.72 : 0.35)

        return HStack(spacing: 4) {
            Circle()
                .fill(Color.primary.opacity(dotOpacity))
                .frame(width: 6, height: 6)
            Text(level.displayTitle)
                .font(.system(size: 10, weight: level == .critical ? .semibold : .medium))
                .foregroundStyle(level == .normal ? .secondary : .primary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.primary.opacity(level == .critical ? 0.12 : 0.055), in: Capsule())
        .overlay(
            Capsule()
                .stroke(Color.primary.opacity(level == .critical ? 0.3 : 0.0), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var batteryPill: some View {
        if engine.memoryStats.powerSource == .battery {
            Image(systemName: "battery.50")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .help("Питание от батареи")
        }
    }

    private var memorySummaryCard: some View {
        let stats = engine.memoryStats
        let total = Double(max(1, stats.totalPhysicalBytes))
        let appFrac = min(1.0, Double(stats.appMemoryBytes) / total)
        let wiredFrac = min(1.0 - appFrac, Double(stats.wiredBytes) / total)
        let compressedFrac = min(1.0 - appFrac - wiredFrac, Double(stats.compressedBytes) / total)
        let cachedFrac = min(1.0 - appFrac - wiredFrac - compressedFrac, Double(stats.cachedFilesBytes) / total)

        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(ByteFormatter.format(stats.usedBytes))
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Text("из \(ByteFormatter.format(stats.totalPhysicalBytes))")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 8) {
                        if engine.totalReclaimedDRAMBytes >= 5 * 1_048_576 {
                            Label("Возвращено \(ByteFormatter.format(engine.totalReclaimedDRAMBytes)) в DRAM", systemImage: "arrow.down.circle.fill")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.primary)
                        } else if engine.frozenCount > 0 {
                            Label("На паузе: \(ByteFormatter.format(engine.totalFrozenFootprintBytes))", systemImage: "snowflake")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.primary)
                        } else {
                            Text("Свободно и кэш: \(ByteFormatter.format(stats.freeBytes + stats.cachedFilesBytes))")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }

                        if stats.swapUsedBytes > 0 {
                            Text("· Swap \(ByteFormatter.formatCompact(stats.swapUsedBytes))")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer(minLength: 6)

                MemorySparklineView(
                    points: engine.memoryHistory,
                    pressure: stats.pressure
                )
                .frame(width: 86, height: 28)
                .padding(.horizontal, 4)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
            }

            GeometryReader { geo in
                let w = geo.size.width
                HStack(spacing: 1.5) {
                    Rectangle().fill(Color.primary.opacity(0.88))
                        .frame(width: max(0, w * appFrac))
                    Rectangle().fill(Color.primary.opacity(0.55))
                        .frame(width: max(0, w * wiredFrac))
                    Rectangle().fill(Color.primary.opacity(0.32))
                        .frame(width: max(0, w * compressedFrac))
                    Rectangle().fill(Color.primary.opacity(0.14))
                        .frame(width: max(0, w * cachedFrac))
                    Spacer(minLength: 0)
                }
                .background(Color.primary.opacity(0.05))
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
                )
            }
            .frame(height: 7)

            HStack(spacing: 12) {
                legendItem(opacity: 0.88, label: "Программы")
                legendItem(opacity: 0.55, label: "Система")
                legendItem(opacity: 0.32, label: "Сжато")
                legendItem(opacity: 0.14, label: "Кэш")
                Spacer()
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
        }
        .padding(11)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 11))
        .overlay(
            RoundedRectangle(cornerRadius: 11)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }

    private func legendItem(opacity: Double, label: LocalizedStringKey) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color.primary.opacity(opacity))
                .frame(width: 6, height: 6)
                .overlay(Circle().stroke(Color.primary.opacity(0.25), lineWidth: 0.5))
            Text(label)
        }
    }

    private var actionStrip: some View {
        HStack(spacing: 8) {
            Button {
                engine.freezeAllEligibleBackground()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                    if eligibleBatchApps.isEmpty {
                        Text("Все фоновые обработаны")
                    } else {
                        Text("Вернуть RAM (\(eligibleBatchApps.count) · ~\(ByteFormatter.formatCompact(eligibleBatchBytes)))")
                    }
                }
                .padding(.vertical, 2)
            }
            .buttonStyle(MonochromePillButtonStyle(prominent: true, fullWidth: true))
            .disabled(eligibleBatchApps.isEmpty)

            if engine.frozenCount > 0 {
                Button {
                    engine.resumeAll(reason: .resumeButton)
                } label: {
                    Text("Разморозить (\(engine.frozenCount))")
                        .padding(.vertical, 2)
                }
                .buttonStyle(MonochromePillButtonStyle(prominent: false, fullWidth: false))
            }
        }
    }
}
