import Foundation

/// Turns an app's current status into plain-language sentences for the «Почему?» section.
public enum FreezeExplainer {
    public struct Context: Sendable {
        public let settings: EngineSettings
        public let pressure: MemoryPressureLevel
        public let powerSource: PowerSourceKind
        public let now: Date

        public init(settings: EngineSettings, pressure: MemoryPressureLevel, powerSource: PowerSourceKind, now: Date = Date()) {
            self.settings = settings
            self.pressure = pressure
            self.powerSource = powerSource
            self.now = now
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    public static func explain(_ app: TrackedApp, context: Context) -> [String] {
        var lines: [String] = []

        switch app.status {
        case .frozen(let since, _):
            let time = timeFormatter.string(from: since)
            let duration = ByteFormatter.formatDuration(context.now.timeIntervalSince(since))
            lines.append(String(localized: "На паузе с \(time) (\(duration))."))
            if let reason = app.frozenReason, !reason.isEmpty {
                lines.append(String(localized: "Причина: \(reason)."))
            }
            if app.reclaimedDRAMBytes >= 5 * 1_048_576 {
                lines.append(String(localized: "macOS уже убрала из оперативной памяти \(ByteFormatter.format(app.reclaimedDRAMBytes))."))
            } else {
                lines.append(String(localized: "Процессор она больше не тратит. Её память macOS освободит, как только та понадобится другим программам."))
            }
            lines.append(String(localized: "Проснётся от клика по окну, переключения на неё или ⌃⌥⌘U."))

        case .active:
            lines.append(String(localized: "Вы сейчас работаете в этой программе."))

        case .protected(let reasons):
            lines.append(String(localized: "Не ставится на паузу:"))
            lines.append(contentsOf: reasons.map { "• " + sentence(for: $0) })

        case .countingDown(let remaining, let total):
            let idle = ByteFormatter.formatDuration(app.idleSeconds)
            lines.append(String(localized: "Неактивна \(idle). Пауза через \(ByteFormatter.formatDuration(remaining)) (таймаут \(ByteFormatter.formatDuration(total)))."))
            lines.append(contentsOf: timeoutFactors(app: app, context: context))

        case .belowThreshold:
            let threshold = Int(context.settings.minMemoryThresholdMB)
            lines.append(String(localized: "Занимает \(ByteFormatter.format(app.footprintBytes)) — меньше порога \(threshold) МБ, поэтому автоматически не замораживается."))

        case .manualOnly:
            if !app.isRegularApp {
                lines.append(String(localized: "Это утилита без иконки в Dock. Такие программы не становятся активными, и переключением их не разбудить, поэтому автоматически они не замораживаются."))
            } else {
                lines.append(String(localized: "Автопауза выключена — только вручную."))
            }

        case .waitingForPressure:
            let idle = ByteFormatter.formatDuration(app.idleSeconds)
            let cpu = Int(app.backgroundCPUPercent.rounded())
            let hog = Int(FreezePolicy.cpuHogThresholdPercent)
            lines.append(String(localized: "Неактивна \(idle), но включён режим «Только при нехватке памяти»: программа ждёт, пока памяти станет мало."))
            lines.append(String(localized: "Фоновая нагрузка CPU — \(cpu)%. Сразу на паузу ставятся программы от \(hog)%."))
        }

        if app.isMemoryGrowing {
            let growth = ByteFormatter.format(UInt64(max(0, app.recentGrowthBytes)))
            lines.append(String(localized: "Память растёт: +\(growth) за последние пару минут."))
        }
        return lines
    }

    public static func sentence(for reason: ProtectionReason) -> String {
        switch reason {
        case .frontmost: return String(localized: "Программа сейчас активна.")
        case .playingAudio: return String(localized: "Играет звук — пауза оборвала бы воспроизведение.")
        case .usingMicrophone: return String(localized: "Использует микрофон — возможно, идёт звонок или запись.")
        case .preventingSleep: return String(localized: "Не даёт Mac уснуть: видео, звонок или загрузка.")
        case .builtInSafelist: return String(localized: "Терминал, IDE или системная утилита — такие не трогаем.")
        case .userWhitelist: return String(localized: "Вы поставили правило «Защита».")
        case .cooldownAfterWake: return String(localized: "Недавно проснулась — даём ей поработать хотя бы полминуты.")
        case .recentlyLaunched: return String(localized: "Только что запущена.")
        case .visibleOnScreen: return String(localized: "Её окно видно на экране.")
        case .clipboardOwner: return String(localized: "Из неё вы последний раз копировали — без неё вставка может зависнуть.")
        }
    }

    private static func timeoutFactors(app: TrackedApp, context: Context) -> [String] {
        var lines: [String] = []
        let s = context.settings
        if app.rule == .fast {
            lines.append(String(localized: "Правило «Быстро»: базовый таймаут \(Int(s.fastModeMinutes)) мин."))
        }
        if s.batterySaverMode && context.powerSource == .battery {
            lines.append(String(localized: "Работа от батареи: таймаут вдвое короче."))
        }
        if s.aggressivePressureMode {
            switch context.pressure {
            case .warning: lines.append(String(localized: "Памяти не хватает: таймаут вдвое короче."))
            case .critical: lines.append(String(localized: "Памяти критически мало: таймаут вчетверо короче."))
            case .normal: break
            }
        }
        return lines
    }
}
