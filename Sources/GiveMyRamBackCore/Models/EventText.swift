import Foundation

/// Why an app was paused or resumed. Stored as data and turned into text only when shown,
/// so saved state and the activity log follow the current interface language.
public enum FreezeReason: Codable, Sendable, Equatable {
    // Pausing
    case manual
    case batchButton
    case idle(seconds: Double, backgroundCPUPercent: Int?, pressure: MemoryPressureLevel?)
    case serviceAuto
    // Resuming
    case focusChange
    case windowActivated
    case appOpened
    case windowShown
    case windowClick
    case dockIconClick
    case protectedRule
    case hotkey
    case contextMenu
    case resumeButton
    case appQuit
    case shutdown
    case byUser

    public var localized: String {
        switch self {
        case .manual: return String(localized: "вручную")
        case .batchButton: return String(localized: "кнопка «Вернуть RAM»")
        case .idle(let seconds, let cpu, let pressure):
            var text = String(localized: "неактивна \(ByteFormatter.formatDuration(seconds))")
            if let cpu {
                text += String(localized: ", фоновая нагрузка CPU \(cpu)%")
            } else if let pressure, pressure != .normal {
                text += String(localized: ", давление памяти: \(pressure.displayTitle.lowercased())")
            }
            return text
        case .serviceAuto: return String(localized: "автопауза сервиса")
        case .focusChange: return String(localized: "переход фокуса")
        case .windowActivated: return String(localized: "активация окна")
        case .appOpened: return String(localized: "открытие приложения")
        case .windowShown: return String(localized: "показ окна")
        case .windowClick: return String(localized: "клик по окну")
        case .dockIconClick: return String(localized: "клик по иконке в Dock")
        case .protectedRule: return String(localized: "правило «Защита»")
        case .hotkey: return String(localized: "горячая клавиша \("⌃⌥⌘U")")
        case .contextMenu: return String(localized: "контекстное меню")
        case .resumeButton: return String(localized: "кнопка «Разморозить»")
        case .appQuit: return String(localized: "выход из приложения")
        case .shutdown: return String(localized: "завершение работы")
        case .byUser: return String(localized: "пользователем")
        }
    }
}

/// The detail line of an activity-log entry, as data.
public enum EventText: Codable, Sendable, Equatable {
    case frozen(bytes: UInt64, reason: FreezeReason)
    case frozenAuto(bytes: UInt64, reason: FreezeReason)
    case frozenBatch(count: Int, bytes: UInt64)
    case serviceFrozen(bytes: UInt64, reason: FreezeReason)
    case serviceAuto(bytes: UInt64)
    case resumed(reason: FreezeReason)
    case recovered
    case relaunched
    case relaunchQuitFailed
    case relaunchCancelled
    /// Plain text from logs saved by versions before 2.2.1.
    case legacy(String)

    public var localized: String {
        switch self {
        case .frozen(let bytes, let reason):
            return String(localized: "Заморожено (\(ByteFormatter.format(bytes)), \(reason.localized))")
        case .frozenAuto(let bytes, let reason):
            let text = reason.localized
            let capitalized = text.prefix(1).uppercased() + text.dropFirst()
            return String(localized: "\(capitalized) · \(ByteFormatter.format(bytes))")
        case .frozenBatch(let count, let bytes):
            return String(localized: "На паузу поставлено приложений: \(count) (~\(ByteFormatter.format(bytes)))")
        case .serviceFrozen(let bytes, let reason):
            return String(localized: "Сервис на паузе (\(ByteFormatter.format(bytes)), \(reason.localized))")
        case .serviceAuto(let bytes):
            return String(localized: "Автопауза сервиса (\(ByteFormatter.format(bytes)))")
        case .resumed(let reason):
            return String(localized: "Возобновлено (\(reason.localized))")
        case .recovered:
            return String(localized: "Возобновлено после предыдущего запуска")
        case .relaunched:
            return String(localized: "Мягкий перезапуск для сброса памяти")
        case .relaunchQuitFailed:
            return String(localized: "Не удалось запросить завершение приложения")
        case .relaunchCancelled:
            return String(localized: "Перезапуск отменён: приложение ожидает подтверждения")
        case .legacy(let text):
            return text
        }
    }
}
