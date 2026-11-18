import Combine
import GiveMyRamBackCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var engine: FreezeEngine
    @ObservedObject var updates: UpdateChecker
    let onBack: () -> Void
    let onQuit: () -> Void

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?
    @State private var isAccessibilityTrusted = WindowInspector.isAccessibilityTrusted

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

                    Toggle(isOn: $engine.settings.freezeOnlyUnderPressure) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Только при нехватке памяти")
                            Text("Пока памяти хватает, пауза почти ничего не освобождает, а уведомления пропадают. В этом режиме неактивные программы ждут жёлтой зоны; сразу на паузу встают только те, что нагружают процессор в фоне (≥ \(Int(FreezePolicy.cpuHogThresholdPercent))%)")
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

                    Toggle(isOn: $engine.settings.keepVisibleWindowsAwake) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Не трогать видимые окна")
                            Text("Отсчёт начинается, только когда окно скрыто, свёрнуто или перекрыто")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Toggle(isOn: $engine.settings.protectClipboardOwner) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Защищать источник буфера обмена")
                            Text("Программа, из которой вы последний раз копировали, не встанет на паузу — иначе вставка может зависнуть")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Пробуждение") {
                    Toggle(isOn: $engine.settings.showFrozenOverlay) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Отмечать окна на паузе")
                            Text("Затемняет окно и показывает «На паузе», чтобы его не путали с зависшим")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Toggle(isOn: $engine.settings.unfreezeHotkeyEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Разморозить всё: ⌃⌥⌘U")
                            Text("Работает из любой программы, без дополнительных разрешений")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Клик по иконке в Dock")
                            (isAccessibilityTrusted
                                 ? Text("Включено: клик по иконке замороженной программы сразу её размораживает")
                                 : Text("Нужен доступ «Универсальный доступ», иначе программу на паузе разбудит только клик по её окну или переключение на неё"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if isAccessibilityTrusted {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.secondary)
                        } else {
                            Button("Разрешить") {
                                WindowInspector.requestAccessibilityTrust()
                            }
                        }
                    }
                }

                if !customRuleEntries.isEmpty {
                    Section("Особые правила (\(customRuleEntries.count))") {
                        ForEach(customRuleEntries, id: \.bundleID) { item in
                            HStack(spacing: 8) {
                                Image(systemName: item.rule == .fast ? "bolt.fill" : "shield.fill")
                                    .foregroundStyle(item.rule == .fast ? Color.primary : Color.secondary)

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.name)
                                    (item.rule == .fast ? Text("Быстрая пауза") : Text("Белый список"))
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

                    Toggle(isOn: $engine.settings.checkForUpdates) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Проверять обновления")
                            Text("Раз в день спрашивает у GitHub, вышла ли новая версия. Никаких данных о вас не отправляется")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    HStack {
                        Text(updateStatusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if updates.isChecking {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Проверить сейчас") {
                                Task { await updates.checkNow() }
                            }
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
                    Button("Показать знакомство с приложением") {
                        NotificationCenter.default.post(name: OnboardingRequest.notification, object: nil)
                    }
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
            isAccessibilityTrusted = WindowInspector.isAccessibilityTrusted
        }
        .task {
            // The user grants access in System Settings; reflect it without reopening the view.
            while !Task.isCancelled && !isAccessibilityTrusted {
                try? await Task.sleep(for: .seconds(1.5))
                isAccessibilityTrusted = WindowInspector.isAccessibilityTrusted
            }
        }
    }

    private var updateStatusText: String {
        if let release = updates.available {
            return String(localized: "Доступна версия \(release.version) (у вас \(updates.currentVersion))")
        }
        if let error = updates.lastError {
            return error
        }
        if let last = updates.lastCheck {
            let when = last.formatted(date: .abbreviated, time: .shortened)
            return String(localized: "Версия \(updates.currentVersion) — последняя. Проверено \(when)")
        }
        return String(localized: "Версия \(updates.currentVersion)")
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
            launchAtLoginError = String(localized: "Для автозапуска запустите пакет Give my ram back.app (\(error.localizedDescription)).")
        }
    }
}
