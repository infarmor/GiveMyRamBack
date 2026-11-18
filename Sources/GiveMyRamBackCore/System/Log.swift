import os

/// Unified logging. View live with:
///   log stream --predicate 'subsystem == "dev.givemyramback.app"' --level info
/// or in Console.app filtered by the same subsystem.
public enum Log {
    public static let subsystem = "dev.givemyramback.app"

    /// Freeze / resume decisions and their reasons.
    public static let freeze = Logger(subsystem: subsystem, category: "freeze")
    /// Engine lifecycle, sampling cadence, memory pressure, clipboard and wake detection.
    public static let engine = Logger(subsystem: subsystem, category: "engine")
    /// Low-level signalling and persisted state.
    public static let process = Logger(subsystem: subsystem, category: "process")
    /// Crash handler and watchdog.
    public static let guardian = Logger(subsystem: subsystem, category: "watchdog")
    /// UI helpers: overlays, hotkey, accessibility.
    public static let ui = Logger(subsystem: subsystem, category: "ui")
}
