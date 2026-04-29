//
//  ShellRunner.swift
//  TestFS
//
//  Subprocess bridge with concurrent pipe drain. Concurrent drain
//  matters because hdiutil/mount can emit many KB of output, and
//  serial reads risk deadlocking on a full kernel pipe buffer
//  before the child has finished writing.
//

import Foundation

enum ShellRunner {
    struct Result {
        let exit: Int32
        let stdout: String
        let stderr: String
    }

    private static let drainQueue = DispatchQueue(
        label: "shellrunner.drain", attributes: .concurrent)

    /// Default ceiling for any single subprocess. A wait longer than
    /// this means the system process is wedged and the caller should
    /// fail loud rather than block its actor.
    static let defaultTimeout: TimeInterval = 30.0

    static func run(
        _ path: String,
        _ args: [String],
        timeout: TimeInterval = defaultTimeout
    ) -> Result {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let outPipe = Pipe(), errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        let exitSem = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in exitSem.signal() }
        do { try proc.run() } catch {
            return Result(exit: -1, stdout: "", stderr: error.localizedDescription)
        }
        let group = DispatchGroup()
        var outData = Data(), errData = Data()
        group.enter()
        drainQueue.async {
            outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        drainQueue.async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        if exitSem.wait(timeout: .now() + timeout) == .timedOut {
            // SIGTERM first; if the child traps it (or is stuck in
            // uninterruptible I/O), the pipes stay open and the drain
            // reads block forever — defeating the timeout. Escalate
            // to SIGKILL after 2s, then bound the drain wait so
            // group.wait can't itself hang.
            proc.terminate()
            if exitSem.wait(timeout: .now() + 2.0) == .timedOut {
                kill(proc.processIdentifier, SIGKILL)
                _ = exitSem.wait(timeout: .now() + 1.0)
            }
            _ = group.wait(timeout: .now() + 1.0)
            return Result(
                exit: -1,
                stdout: String(data: outData, encoding: .utf8) ?? "",
                stderr: "ShellRunner: \(path) timed out after \(timeout)s"
            )
        }
        group.wait()
        return Result(
            exit: proc.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }
}

extension String {
    /// "/dev/disk5" -> "disk5". URL handles trailing slashes and any
    /// path-like input cleanly; non-path strings round-trip unchanged.
    static func bsdName(fromDevNode devNode: String) -> String {
        URL(fileURLWithPath: devNode).lastPathComponent
    }
}
