import AppKit
import GiveMyRamBackCore
import ServiceManagement
import SwiftUI

enum OnboardingRequest {
    static let notification = Notification.Name("dev.givemyramback.showOnboarding")
}

/// Installed messenger offered for protection on the setup page.
struct InstalledMessenger: Identifiable {
    let bundleID: String
    let name: String
    let icon: NSImage
    var id: String { bundleID }

    static func detect() -> [InstalledMessenger] {
        var seenPaths = Set<String>()
        return KnownApps.messengers.compactMap { entry in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry.bundleID),
                  seenPaths.insert(url.path).inserted else {
                return nil
            }
            let bundle = Bundle(url: url)
            let displayName = (bundle?.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
                ?? (bundle?.infoDictionary?["CFBundleDisplayName"] as? String)
                ?? (bundle?.infoDictionary?["CFBundleName"] as? String)
                ?? entry.name
            return InstalledMessenger(
                bundleID: entry.bundleID,
                name: displayName,
                icon: NSWorkspace.shared.icon(forFile: url.path)
            )
        }
    }
}

struct OnboardingView: View {
    @ObservedObject var engine: FreezeEngine
    let onFinish: () -> Void

    @State private var page = 0
    @State private var messengers: [InstalledMessenger] = []
    @State private var protectedMessengers: Set<String> = []
    @State private var isAccessibilityTrusted = WindowInspector.isAccessibilityTrusted
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    private let trustPoll = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    private let pageCount = 4

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch page {
                case 0: welcomePage
                case 1: wakePage
                case 2: modePage
                default: permissionsPage
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 32)
            .padding(.top, 28)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .opacity))
            .id(page)

            Divider()

            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<pageCount, id: \.self) { index in
                        Circle()
                            .fill(Color.primary.opacity(index == page ? 0.85 : 0.2))
                            .frame(width: 6, height: 6)
                    }
                }
                Spacer()
                if page > 0 {
                    Button("Назад") {
                        withAnimation(.snappy(duration: 0.25)) { page -= 1 }
                    }
                    .keyboardShortcut(.cancelAction)
                }
                Button {
                    if page == pageCount - 1 {
                        finish()
                    } else {
                        withAnimation(.snappy(duration: 0.25)) { page += 1 }
                    }
                } label: {
                    page == pageCount - 1 ? Text("Готово") : Text("Далее")
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(.primary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 540, height: 500)
        .onAppear {
            messengers = InstalledMessenger.detect()
            // Default: protect every installed messenger unless the user already chose a rule.
            protectedMessengers = Set(messengers.filter { engine.settings.appRules[$0.bundleID] != .fast }.map(\.bundleID))
        }
        .onReceive(trustPoll) { _ in
            if page == 3 && !isAccessibilityTrusted {
                isAccessibilityTrusted = WindowInspector.isAccessibilityTrusted
            }
        }
    }

    // MARK: Pages

    private var welcomePage: some View {
        VStack(spacing: 14) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 96, height: 96)
            }
            Text("Give my ram back")
                .font(.system(size: 26, weight: .bold))
            Text("Ставит на паузу программы, которыми вы давно не пользуетесь, и возвращает память и заряд батареи.")
                .font(.system(size: 14))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                feature("pause.circle", "Пауза — не закрытие", "Программа замирает целиком (SIGSTOP) и ничего не теряет: вкладки, документы и состояние остаются на месте.")
                feature("cpu", "Ноль процессора", "Программа на паузе не тратит процессор, а её память macOS освобождает в первую очередь.")
                feature("shield.lefthalf.filled", "Не мешает работе", "Не трогает активные окна, звук, звонки, загрузки, терминалы и окна, которые видно на экране.")
            }
            .padding(.top, 8)
        }
    }

    private var wakePage: some View {
        VStack(alignment: .leading, spacing: 16) {
            title("Как разбудить программу", subtitle: "Всё происходит само, мгновенно и с того же места.")
            VStack(alignment: .leading, spacing: 12) {
                feature("cursorarrow.click.2", "Кликните по её окну", "Окна на паузе затемнены и подписаны «На паузе».")
                feature("command", "Переключитесь на неё", "Через Cmd+Tab, Dock, Mission Control или просто откройте программу снова.")
                feature("keyboard", "⌃⌥⌘U — разморозить всё", "Работает из любой программы, если что-то пошло не так.")
                feature("menubar.rectangle", "Иконка в строке меню", "Список программ, кнопки «Пауза» и «Вернуть», журнал и настройки.")
            }
        }
    }

    private var modePage: some View {
        VStack(alignment: .leading, spacing: 14) {
            title("Как работать", subtitle: "Всё это можно поменять позже в настройках.")

            VStack(alignment: .leading, spacing: 10) {
                Toggle("Автоматически ставить на паузу неактивные программы", isOn: $engine.settings.isAutoFreezeEnabled)

                HStack {
                    Text("Через")
                    Picker("", selection: $engine.settings.idleTimeoutMinutes) {
                        Text("5 мин").tag(5.0)
                        Text("10 мин").tag(10.0)
                        Text("20 мин").tag(20.0)
                        Text("30 мин").tag(30.0)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 260)
                    Text("бездействия")
                }
                .disabled(!engine.settings.isAutoFreezeEnabled)

                Toggle(isOn: $engine.settings.freezeOnlyUnderPressure) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Только когда памяти мало")
                        Text("Иначе программы ждут, пока памяти станет мало. Сразу на паузу встанут только те, что нагружают процессор в фоне.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(!engine.settings.isAutoFreezeEnabled)
            }

            if !messengers.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Мессенджеры на паузе не присылают уведомлений. Не трогать:")
                        .font(.system(size: 12.5, weight: .medium))
                    ScrollView {
                        VStack(spacing: 4) {
                            ForEach(messengers) { messenger in
                                Toggle(isOn: Binding(
                                    get: { protectedMessengers.contains(messenger.bundleID) },
                                    set: { on in
                                        if on { protectedMessengers.insert(messenger.bundleID) }
                                        else { protectedMessengers.remove(messenger.bundleID) }
                                    }
                                )) {
                                    HStack(spacing: 8) {
                                        Image(nsImage: messenger.icon)
                                            .resizable()
                                            .frame(width: 20, height: 20)
                                        Text(messenger.name)
                                    }
                                }
                                .toggleStyle(.checkbox)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(maxHeight: 110)
                }
                .padding(10)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private var permissionsPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            title("Последние штрихи", subtitle: "Всё необязательно: приложение работает и без этого.")

            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "dock.rectangle")
                    .font(.system(size: 20))
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Пробуждение по иконке в Dock")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Программа на паузе не может ответить Dock'у. С доступом «Универсальный доступ» клик по её иконке сразу её разбудит.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if isAccessibilityTrusted {
                    Label("Включено", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                } else {
                    Button("Разрешить") {
                        WindowInspector.requestAccessibilityTrust()
                    }
                }
            }

            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "power")
                    .font(.system(size: 20))
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Запускать при входе в macOS")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Чтобы память освобождалась без вашего участия.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { launchAtLogin },
                    set: { setLaunchAtLogin($0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }

            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 20))
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Проверять обновления")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Раз в день спрашивать GitHub о новой версии.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: $engine.settings.checkForUpdates)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
        }
    }

    // MARK: Helpers

    private func title(_ text: LocalizedStringKey, subtitle: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text).font(.system(size: 22, weight: .bold))
            Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
        }
    }

    private func feature(_ symbol: String, _ heading: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 18))
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(heading).font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.ui.error("Launch at login: \(error.localizedDescription, privacy: .public)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func finish() {
        for messenger in messengers {
            if protectedMessengers.contains(messenger.bundleID) {
                engine.setRule(.protected, for: messenger.bundleID, appName: messenger.name)
            } else if engine.settings.appRules[messenger.bundleID] == .protected {
                engine.setRule(.automatic, for: messenger.bundleID)
            }
        }
        engine.settings.hasCompletedOnboarding = true
        onFinish()
    }
}
