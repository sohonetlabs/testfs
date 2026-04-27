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

    static func run(_ path: String, _ args: [String]) -> Result {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let outPipe = Pipe(), errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
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
        proc.waitUntilExit()
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
