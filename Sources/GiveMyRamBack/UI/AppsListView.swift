import GiveMyRamBackCore
import SwiftUI

enum AppFilterMode: String, CaseIterable, Identifiable {
    case heavy
    case frozen
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .heavy: return String(localized: "Тяжёлые")
        case .frozen: return String(localized: "На паузе")
        case .all: return String(localized: "Все")
        }
    }
}

struct AppsListView: View {
    @ObservedObject var engine: FreezeEngine
    @State private var searchText = ""
    @State private var filterMode: AppFilterMode = .heavy
    @State private var expandedAppID: String?
    @FocusState private var isSearchFocused: Bool

    private var filteredApps: [TrackedApp] {
        let minBytes = UInt64(max(0, engine.settings.minMemoryThresholdMB) * 1_048_576.0)
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        return engine.apps.filter { app in
            switch filterMode {
            case .heavy:
                if !app.isFrozen && !app.isFastRule && !app.isMemoryGrowing && app.footprintBytes < minBytes {
                    return false
                }
            case .frozen:
                if !app.isFrozen {
                    return false
                }
            case .all:
                break
            }

            if !query.isEmpty {
                return app.name.lowercased().contains(query)
                    || (app.bundleIdentifier?.lowercased().contains(query) ?? false)
            }
            return true
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 12))
                    TextField("Поиск", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .focused($isSearchFocused)
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

                Picker("", selection: $filterMode) {
                    ForEach(AppFilterMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 210)
            }

            if filteredApps.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: filterMode == .frozen ? "snowflake" : "checkmark.circle")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(.secondary)
                    (filterMode == .frozen ? Text("Нет приложений на паузе") : Text("Нет подходящих приложений"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(filteredApps.enumerated()), id: \.element.id) { index, app in
                            AppRowView(
                                app: app,
                                engine: engine,
                                isExpanded: expandedAppID == app.id,
                                onToggleExpand: {
                                    withAnimation(.snappy(duration: 0.2)) {
                                        expandedAppID = (expandedAppID == app.id) ? nil : app.id
                                    }
                                }
                            )

                            if index < filteredApps.count - 1 {
                                Divider()
                                    .padding(.leading, 52)
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
        .background(
            Button("") {
                isSearchFocused = true
            }
            .keyboardShortcut("f", modifiers: .command)
            .hidden()
        )
    }
}

private struct AppRowView: View {
    let app: TrackedApp
    @ObservedObject var engine: FreezeEngine
    let isExpanded: Bool
    let onToggleExpand: () -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                ZStack(alignment: .bottomTrailing) {
                    Image(nsImage: AppIconCache.shared.icon(for: app.bundlePath, name: app.name))
                        .resizable()
                        .saturation(0)
                        .contrast(1.06)
                        .frame(width: 32, height: 32)
                        .opacity(app.isFrozen ? 0.45 : 0.92)

                    if app.isFrozen {
                        Image(systemName: "snowflake.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.primary)
                            .background(Circle().fill(.windowBackground))
                            .offset(x: 3, y: 3)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(app.name)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)

                        if app.rule == .fast {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 9.5))
                                .foregroundStyle(.primary.opacity(0.75))
                                .help("Быстрый режим (\(Int(engine.settings.fastModeMinutes)) мин)")
                        } else if app.rule == .protected {
                            Image(systemName: "shield.fill")
                                .font(.system(size: 9.5))
                                .foregroundStyle(.secondary)
                                .help("В белом списке")
                        }

                        if app.isMemoryGrowing {
                            Text("↑ +\(ByteFormatter.formatCompact(UInt64(max(0, app.recentGrowthBytes))))")
                                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.primary.opacity(0.1), in: Capsule())
                                .overlay(Capsule().stroke(Color.primary.opacity(0.22), lineWidth: 0.5))
                        }
                    }

                    statusView
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(ByteFormatter.format(app.footprintBytes))
                        .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.primary)

                    secondaryMetricView
                }

                actionButton
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
            .onTapGesture {
                onToggleExpand()
            }
            .onHover { hovering in
                isHovered = hovering
            }
            .background(
                app.isFrozen
                    ? Color.primary.opacity(isHovered ? 0.095 : 0.06)
                    : (isHovered ? Color.primary.opacity(0.045) : Color.clear)
            )

            if isExpanded {
                expandedDrawer
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .contextMenu {
            if app.isFrozen {
                Button("Вернуть в работу") { engine.resumeApp(app) }
            } else if canManualFreeze {
                Button("Поставить на паузу") { engine.freezeApp(app) }
            }

            if let bundleID = app.bundleIdentifier {
                Divider()
                Menu("Правило для приложения") {
                    ForEach(AppFreezeRule.allCases, id: \.self) { rule in
                        Button(rule.displayTitle) {
                            engine.setRule(rule, for: bundleID, appName: app.name)
                        }
                    }
                }
            }

            if app.bundlePath != nil && !isProtectedFromTermination {
                Divider()
                Button("Перезапустить (сбросить память)") {
                    engine.relaunchApp(app)
                }
            }
        }
    }

    @ViewBuilder
    private var secondaryMetricView: some View {
        if app.isFrozen {
            if app.reclaimedDRAMBytes >= 5 * 1_048_576 {
                Text("−\(ByteFormatter.formatCompact(app.reclaimedDRAMBytes)) DRAM")
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.primary.opacity(0.8))
            } else {
                Text("на паузе")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        } else if app.cpuPercent >= 1.0 {
            Text(String(format: "%.0f%% CPU", app.cpuPercent))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(app.cpuPercent >= 35 ? .primary : .secondary)
        } else {
            (app.processCount > 1 ? Text("\(app.processCount) проц.") : Text("в фоне"))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if app.isFrozen {
            Button("Вернуть") {
                engine.resumeApp(app)
            }
            .buttonStyle(MonochromePillButtonStyle(prominent: true))
        } else if canManualFreeze {
            Button("Пауза") {
                engine.freezeApp(app)
            }
            .buttonStyle(MonochromePillButtonStyle(prominent: false))
            .opacity(isHovered || isExpanded ? 1.0 : 0.85)
        } else {
            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 24)
        }
    }

    private var explanationLines: [String] {
        FreezeExplainer.explain(
            app,
            context: FreezeExplainer.Context(
                settings: engine.settings,
                pressure: engine.memoryStats.pressure,
                powerSource: engine.memoryStats.powerSource
            )
        )
    }

    private var expandedDrawer: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Label("Почему?", systemImage: "questionmark.circle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.85))
                ForEach(Array(explanationLines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 8) {
                Text("Процессов: \(app.processCount)")
                Text("·")
                Text("В DRAM сейчас: \(ByteFormatter.format(app.residentBytes))")
                Spacer()
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                if let bundleID = app.bundleIdentifier {
                    Picker("", selection: Binding(
                        get: { app.rule },
                        set: { engine.setRule($0, for: bundleID, appName: app.name) }
                    )) {
                        Text("Авто").tag(AppFreezeRule.automatic)
                        Text("Быстро").tag(AppFreezeRule.fast)
                        Text("Защита").tag(AppFreezeRule.protected)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                }

                Spacer()

                if app.bundlePath != nil && !isProtectedFromTermination {
                    Button {
                        engine.relaunchApp(app)
                    } label: {
                        Label("Перезапустить", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(MonochromePillButtonStyle(prominent: false))
                    .help("Закрыть и открыть заново для полного сброса накопленной памяти")
                }
            }
        }
        .padding(.leading, 54)
        .padding(.trailing, 11)
        .padding(.bottom, 10)
        .padding(.top, 2)
        .background(Color.primary.opacity(0.025))
    }

    private var canManualFreeze: Bool {
        if case .active = app.status { return false }
        if case .protected(let reasons) = app.status {
            return !reasons.contains(.frontmost) && !reasons.contains(.builtInSafelist)
        }
        return true
    }

    private var isProtectedFromTermination: Bool {
        if case .active = app.status { return true }
        if case .protected(let reasons) = app.status {
            return reasons.contains(.builtInSafelist) || reasons.contains(.userWhitelist)
        }
        return false
    }

    @ViewBuilder
    private var statusView: some View {
        switch app.status {
        case .active:
            HStack(spacing: 5) {
                Circle()
                    .fill(.primary)
                    .frame(width: 5, height: 5)
                Text("Активно")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

        case .frozen(let since, _):
            let elapsed = max(0, Date().timeIntervalSince(since))
            Text("На паузе · \(ByteFormatter.formatDuration(elapsed))")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary.opacity(0.8))

        case .protected(let reasons):
            let text = reasons.map(\.shortLabel).joined(separator: ", ")
            Text("Защита: \(text)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)

        case .countingDown(let remaining, let total):
            let progress = total > 0 ? max(0, min(1, 1.0 - (remaining / total))) : 0
            HStack(spacing: 6) {
                Text("Пауза через \(ByteFormatter.formatDuration(remaining))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: 44)
                    .tint(.primary)
            }

        case .belowThreshold:
            Text("Ниже порога \(Int(engine.settings.minMemoryThresholdMB)) МБ")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

        case .manualOnly:
            Text("Ручной режим")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

        case .waitingForPressure:
            Text("Ждёт нехватки памяти")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}
