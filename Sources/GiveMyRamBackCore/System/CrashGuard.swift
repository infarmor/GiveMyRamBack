import Darwin
import Foundation

// Storage read from a signal handler. It is allocated once and never freed, and is touched in
// `CrashGuard.installCrashHandlers()` so lazy global initialisation never runs inside a handler.
private let crashPIDCapacity = 4096
nonisolated(unsafe) private let crashPIDBuffer = UnsafeMutablePointer<Int32>.allocate(capacity: 4096)
nonisolated(unsafe) private var crashPIDCount: Int = 0
nonisolated(unsafe) private var crashAltStack: UnsafeMutableRawPointer?

/// Makes sure frozen processes are never left in `SIGSTOP` when Give my ram back dies abnormally.
///
/// Two independent layers:
/// 1. In-process fatal-signal handler (SIGSEGV, SIGABRT, Swift traps…) that sends `SIGCONT` to
///    every frozen PID using only async-signal-safe calls, then re-raises the signal.
/// 2. A watchdog child process (`--watchdog <pid>`) that waits for the app to exit for *any*
///    reason — including `SIGKILL` / Force Quit, which no handler can catch — and then resumes
///    everything still listed in `frozen_state.json`.
public enum CrashGuard {
    public static let watchdogArgument = "--watchdog"

    /// Called by `ProcessController` whenever the frozen set changes.
    static func publishFrozenPIDs(_ pids: [Int32]) {
        let n = min(pids.count, crashPIDCapacity)
        crashPIDCount = 0
        for i in 0..<n {
            crashPIDBuffer[i] = pids[i]
        }
        crashPIDCount = n
    }

    public static func installCrashHandlers() {
        // Touch globals so their lazy initialisers have already run.
        _ = crashPIDCount
        _ = crashPIDBuffer
        _ = crashPIDCapacity

        ensureAltStackForCurrentThread()

        let fatalSignals: [Int32] = [SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGFPE, SIGTRAP, SIGSYS]
        for sig in fatalSignals {
            var action = sigaction()
            action.__sigaction_u.__sa_handler = { signal in
                let n = crashPIDCount
                var i = 0
                while i < n {
                    _ = kill(crashPIDBuffer[i], SIGCONT)
                    i += 1
                }
                // SA_RESETHAND restored the default disposition: re-raise for a normal crash report.
                raise(signal)
            }
            sigemptyset(&action.sa_mask)
            action.sa_flags = SA_RESETHAND | SA_ONSTACK
            sigaction(sig, &action, nil)
        }
    }

    /// Alternate signal stacks are per thread. Without one, a stack-overflow SIGSEGV on that
    /// thread can't run the handler, so every thread doing real work (main thread, sampling
    /// task) installs one. Cheap when already installed: a single `sigaltstack` query.
    public static func ensureAltStackForCurrentThread() {
        var current = stack_t()
        guard sigaltstack(nil, &current) == 0 else { return }
        if current.ss_flags & SS_DISABLE == 0 { return }
        let size = 64 * 1024
        guard let mem = malloc(size) else { return }
        var stack = stack_t(ss_sp: mem, ss_size: size, ss_flags: 0)
        if sigaltstack(&stack, nil) != 0 {
            free(mem)
        } else if Thread.isMainThread {
            crashAltStack = mem
        }
    }

    // MARK: - Watchdog

    /// Starts the watchdog child for the current process. Safe to call once per app launch.
    @discardableResult
    public static func spawnWatchdog() -> Process? {
        let executable = Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let process = Process()
        process.executableURL = executable
        process.arguments = [watchdogArgument, String(getpid())]
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
            Log.guardian.info("Watchdog started: pid \(process.processIdentifier, privacy: .public)")
            return process
        } catch {
            Log.guardian.error("Failed to start watchdog: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// If launched as `--watchdog <pid>`, runs the watchdog and never returns.
    public static func runWatchdogIfRequested(arguments: [String] = CommandLine.arguments) {
        guard let idx = arguments.firstIndex(of: watchdogArgument),
              idx + 1 < arguments.count,
              let parentPID = Int32(arguments[idx + 1]),
              parentPID > 1 else {
            return
        }
        runWatchdog(parentPID: parentPID)
    }

    private static func runWatchdog(parentPID: Int32) -> Never {
        // Leave the parent's session/process group: Ctrl+C or closing the terminal must not take
        // the watchdog down together with the app it guards.
        setsid()
        signal(SIGINT, SIG_IGN)
        signal(SIGHUP, SIG_IGN)
        signal(SIGTERM, SIG_IGN)

        Log.guardian.info("Watchdog armed for pid \(parentPID, privacy: .public)")
        waitForExit(of: parentPID)
        Log.guardian.info("Parent \(parentPID, privacy: .public) exited; checking for frozen leftovers")

        let resumed = ProcessController().recoverFromPreviousRun()
        if !resumed.isEmpty {
            FileHandle.standardError.write(
                Data("GiveMyRamBack watchdog: resumed \(resumed.joined(separator: ", "))\n".utf8)
            )
        }
        exit(0)
    }

    static func waitForExit(of pid: Int32) {
        let kq = kqueue()
        guard kq >= 0 else {
            pollForExit(of: pid)
            return
        }
        defer { close(kq) }

        var change = kevent(
            ident: UInt(pid),
            filter: Int16(EVFILT_PROC),
            flags: UInt16(EV_ADD | EV_ONESHOT),
            fflags: NOTE_EXIT,
            data: 0,
            udata: nil
        )
        if kevent(kq, &change, 1, nil, 0, nil) < 0 {
            // ESRCH: the parent is already gone.
            return
        }
        // Registered before this check, so an exit right after registration is still delivered.
        if kill(pid, 0) != 0 && errno == ESRCH {
            return
        }
        var event = kevent()
        while true {
            let n = kevent(kq, nil, 0, &event, 1, nil)
            if n > 0 { return }
            if n < 0 && errno != EINTR { break }
        }
        pollForExit(of: pid)
    }

    private static func pollForExit(of pid: Int32) {
        while !(kill(pid, 0) != 0 && errno == ESRCH) {
            usleep(500_000)
        }
    }
}
