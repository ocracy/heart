import Foundation
import Combine
import Darwin

final class ProcessManager: ObservableObject {
    @Published var statuses: [String: TaskStatus] = [:]
    @Published var outputs: [String: String] = [:]

    private var processes: [String: Process] = [:]
    private var stdinHandles: [String: FileHandle] = [:]
    private var pendingRestart: [String: DevTask] = [:]
    private let outputCap = 500_000

    private static let ansiRegex: NSRegularExpression? = {
        // Strip CSI (ESC[...), OSC (ESC]...BEL), 2-byte ESC sequences (ESC=, ESC>, ESC7, …),
        // and G0/G1 charset selection (ESC( x). Keeps printable text only.
        let pattern = "\u{1B}(?:\\[[0-?]*[ -/]*[@-~]|\\][^\u{07}]*\u{07}|[=>78DEHMNcOPVWXYZ\\\\^_]|[()][0BAUKQ])"
        return try? NSRegularExpression(pattern: pattern)
    }()

    func status(_ taskId: String) -> TaskStatus {
        statuses[taskId] ?? .stopped
    }

    func output(_ taskId: String) -> String {
        outputs[taskId] ?? ""
    }

    func start(_ task: DevTask) {
        if let existing = processes[task.id], existing.isRunning {
            return
        }

        statuses[task.id] = .starting
        appendOutput(task.id, "\n— starting: \(task.command) (cwd: \(task.cwd)) —\n")

        // BSD `script` allocates a PTY but with 0×0 size — TUIs (ngrok, top, htop) detect
        // this and bail. Set a sane window size on the slave before running the command.
        let wrapped = "stty rows 40 cols 160 2>/dev/null; \(task.command)"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        // -l loads .zprofile; -i (interactive) is what makes zsh also source .zshrc.
        // Without -i, GUI-launched apps miss user PATH additions like
        // `export PATH=$HOME/bin:$PATH` typically placed in ~/.zshrc.
        process.arguments = ["-q", "/dev/null", "/bin/zsh", "-l", "-i", "-c", wrapped]
        // `cwd` may contain a leading "~" (saved from the JSON or edit dialog) — expand it
        // so Foundation chdir's correctly, since it doesn't perform shell tilde expansion.
        let expandedCwd = (task.cwd as NSString).expandingTildeInPath
        process.currentDirectoryURL = URL(fileURLWithPath: expandedCwd)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe

        let taskId = task.id
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let text = String(data: data, encoding: .utf8) {
                DispatchQueue.main.async {
                    self?.appendOutput(taskId, text)
                }
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let text = String(data: data, encoding: .utf8) {
                DispatchQueue.main.async {
                    self?.appendOutput(taskId, text)
                }
            }
        }

        process.terminationHandler = { [weak self] proc in
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.processes[taskId] === proc else { return }
                self.handleTermination(taskId: taskId, exitCode: proc.terminationStatus)
                self.processes.removeValue(forKey: taskId)
                self.stdinHandles.removeValue(forKey: taskId)
            }
        }

        do {
            try process.run()
            processes[task.id] = process
            stdinHandles[task.id] = stdinPipe.fileHandleForWriting
            if process.isRunning {
                // Stay in .starting; readiness check transitions to .running once the
                // service is actually up (port-bound, or grace period elapsed).
                scheduleReadinessCheck(for: task)
            } else {
                handleTermination(taskId: task.id, exitCode: process.terminationStatus)
                processes.removeValue(forKey: task.id)
                stdinHandles.removeValue(forKey: task.id)
            }
        } catch {
            appendOutput(task.id, "\n[error] failed to spawn: \(error.localizedDescription)\n")
            statuses[task.id] = .crashed(exitCode: -1)
        }
    }

    // MARK: - readiness

    private func scheduleReadinessCheck(for task: DevTask) {
        let started = Date()
        let portTimeout: TimeInterval = 30
        let noPortGrace: TimeInterval = 1.5
        let pollInterval: TimeInterval = 0.3
        let taskId = task.id

        func tick() {
            // Bail if process died — terminationHandler already (or will soon) set the status.
            guard let proc = self.processes[taskId], proc.isRunning else { return }
            // Bail if user already asked to stop or status moved past .starting for any reason.
            guard self.statuses[taskId] == .starting else { return }

            if let port = task.port {
                if Self.isPortBound(port) {
                    self.statuses[taskId] = .running
                    self.appendOutput(taskId, "[ready] listening on :\(port)\n")
                    return
                }
                if Date().timeIntervalSince(started) > portTimeout {
                    self.statuses[taskId] = .running
                    self.appendOutput(taskId, "[ready] timeout waiting for :\(port) — marking running\n")
                    return
                }
            } else {
                if Date().timeIntervalSince(started) >= noPortGrace {
                    self.statuses[taskId] = .running
                    return
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) { tick() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) { tick() }
    }

    private static func isPortBound(_ port: Int) -> Bool {
        let sock = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { Darwin.close(sock) }

        var tv = timeval(tv_sec: 0, tv_usec: 100_000)
        _ = setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)

        let result = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sptr in
                Darwin.connect(sock, sptr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    private func handleTermination(taskId: String, exitCode: Int32) {
        if exitCode == 0 {
            statuses[taskId] = .stopped
        } else {
            statuses[taskId] = .crashed(exitCode: exitCode)
        }
        appendOutput(taskId, "\n— exited (code \(exitCode)) —\n")

        if let pending = pendingRestart.removeValue(forKey: taskId) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.start(pending)
            }
        }
    }

    /// Graceful stop: SIGINT (like Ctrl+C) → 3s SIGTERM → 3s SIGKILL.
    func stop(_ task: DevTask) {
        guard let process = processes[task.id], process.isRunning else { return }
        statuses[task.id] = .stopping
        let pid = process.processIdentifier

        // Send Ctrl+C byte to PTY (script forwards to child via TTY line discipline)
        if let stdin = stdinHandles[task.id] {
            try? stdin.write(contentsOf: Data([0x03]))
        }
        process.interrupt()

        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, let proc = self.processes[task.id], proc.isRunning else { return }
            proc.terminate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, let proc = self.processes[task.id], proc.isRunning else { return }
                kill(pid, SIGKILL)
            }
        }
    }

    func restart(_ task: DevTask) {
        if let process = processes[task.id], process.isRunning {
            pendingRestart[task.id] = task
            stop(task)
        } else {
            start(task)
        }
    }

    func toggle(_ task: DevTask) {
        if processes[task.id]?.isRunning == true {
            stop(task)
        } else {
            start(task)
        }
    }

    func startAll(_ tasks: [DevTask]) {
        for task in tasks { start(task) }
    }

    func stopAll(_ tasks: [DevTask]) {
        for task in tasks { stop(task) }
    }

    func clearOutput(_ taskId: String) {
        outputs[taskId] = ""
    }

    /// Forward bytes (typed in the embedded terminal) to the running process's stdin.
    func sendInput(_ taskId: String, data: Data) {
        guard let stdin = stdinHandles[taskId] else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            try? stdin.write(contentsOf: data)
        }
    }

    /// Kills any process listening on the given TCP port (best-effort, runs `lsof | xargs kill -9`).
    func killPort(_ port: Int, for taskId: String? = nil) {
        let pipe = Pipe()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", "PIDS=$(lsof -ti tcp:\(port) 2>/dev/null); if [ -n \"$PIDS\" ]; then echo \"Killing on :\(port): $PIDS\"; echo $PIDS | xargs kill -9; else echo \"No process on :\(port)\"; fi"]
        proc.standardOutput = pipe
        proc.standardError = pipe

        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            if let taskId {
                appendOutput(taskId, "\n[kill-port \(port)] \(output)")
            }
        } catch {
            if let taskId {
                appendOutput(taskId, "\n[kill-port \(port)] error: \(error.localizedDescription)\n")
            }
        }
    }

    func terminateAllSync() {
        for (_, process) in processes where process.isRunning {
            let pid = process.processIdentifier
            process.terminate()
            let deadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                kill(pid, SIGKILL)
            }
        }
    }

    private func appendOutput(_ taskId: String, _ text: String) {
        let cleaned = stripAnsi(text)
        var current = outputs[taskId] ?? ""
        current.append(cleaned)
        if current.count > outputCap {
            let overflow = current.count - outputCap
            current.removeFirst(overflow)
        }
        outputs[taskId] = current
    }

    private func stripAnsi(_ s: String) -> String {
        guard let regex = Self.ansiRegex else { return s }
        let range = NSRange(s.startIndex..., in: s)
        return regex.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: "")
    }
}
