import GiveMyRamBackCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var engine: FreezeEngine
    let onBack: () -> Void
    let onQuit: () -> Void

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?

    private var customRuleEntries: [(bundleID: String, name: String, rule: AppFreezeRule)] {
        engine.settings.appRules
            .filter { $0.value != .automatic }
            .map { bundleID, rule in
                let displayName = engine.settings.appRuleDisplayNames[bundleID]
                    ?? engine.apps.first(where: { $0.bundleIdentifier == bundleID })?.name
                    ?? bundleID
                return (bundleID, displayName, rule)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    onBack()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Назад")
                    }
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.escape, modifiers: [])

                Spacer()

                Text("Настройки")
                    .font(.system(size: 13.5, weight: .semibold))

                Spacer()

                // Balance spacing cleanly
                Text("Назад")
                    .opacity(0)
                    .font(.system(size: 13))
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            Form {
                Section("Автоматическая пауза") {
                    Toggle("Автоматически ставить на паузу неактивные программы", isOn: $engine.settings.isAutoFreezeEnabled)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Ожидание до паузы")
                            Spacer()
                            Text("\(Int(engine.settings.idleTimeoutMinutes)) мин")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $engine.settings.idleTimeoutMinutes, in: 1...60, step: 1)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Режим «Быстро»")
                            Spacer()
                            Text("\(Int(engine.settings.fastModeMinutes)) мин")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $engine.settings.fastModeMinutes, in: 1...15, step: 1)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Минимальный размер в памяти")
                            Spacer()
                            Text("\(Int(engine.settings.minMemoryThresholdMB)) МБ")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $engine.settings.minMemoryThresholdMB, in: 50...1024, step: 25)
                    }

                    Toggle(isOn: $engine.settings.aggressivePressureMode) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Ускорять при нехватке RAM")
                            Text("Вдвое быстрее в жёлтой зоне и вчетверо в красной")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Toggle(isOn: $engine.settings.batterySaverMode) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Экономия от батареи")
                            Text("Вдвое сокращает паузу ожидания без зарядки")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Умная защита") {
                    Toggle("Не трогать звук и микрофон", isOn: $engine.settings.protectAudioApps)
                    Toggle("Не трогать видео, звонки и загрузки", isOn: $engine.settings.protectSleepAssertions)
                    Toggle("Защищать терминалы, IDE и системные утилиты", isOn: $engine.settings.protectDevAndSystemTools)
                }

                if !customRuleEntries.isEmpty {
                    Section("Особые правила (\(customRuleEntries.count))") {
                        ForEach(customRuleEntries, id: \.bundleID) { item in
                            HStack(spacing: 8) {
                                Image(systemName: item.rule == .fast ? "bolt.fill" : "shield.fill")
                                    .foregroundStyle(item.rule == .fast ? Color.primary : Color.secondary)

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.name)
                                    Text(item.rule == .fast ? "Быстрая пауза" : "Белый список")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Button("Сбросить") {
                                    engine.setRule(.automatic, for: item.bundleID)
                                }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.secondary)
                                .font(.caption)
                            }
                        }
                    }
                }

                Section("Строка меню и система") {
                    Picker("Индикатор в строке меню", selection: $engine.settings.menuBarDisplayMode) {
                        ForEach(MenuBarDisplayMode.allCases, id: \.self) { mode in
                            Text(mode.displayTitle).tag(mode)
                        }
                    }

                    Toggle("Запускать при входе в macOS", isOn: Binding(
                        get: { launchAtLogin },
                        set: { toggleLaunchAtLogin(enabled: $0) }
                    ))

                    if let launchAtLoginError {
                        Text(launchAtLoginError)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button {
                        onQuit()
                    } label: {
                        HStack {
                            Spacer()
                            Text("Разморозить все программы и выйти")
                                .fontWeight(.medium)
                            Spacer()
                        }
                    }
                    .foregroundStyle(.primary)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .onAppear {
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
        }
    }

    private func toggleLaunchAtLogin(enabled: Bool) {
        launchAtLoginError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
        } catch {
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
            launchAtLoginError = "Для автозапуска запустите пакет Give my ram back.app (\(error.localizedDescription))."
        }
    }
}
