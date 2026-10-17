import ExpansionLensKit
import Foundation

/// Runs script snippets and returns what they print (shell) or return (AppleScript, JavaScript).
///
/// AppleScript and JavaScript go through `osascript` (JavaScript as JavaScript for
/// Automation), and shell scripts through `/bin/sh` or their own `#!` line. Each runs as its
/// own process, so the timeout in Settings can stop one that hangs.
enum ScriptRunner {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func runner(timeout: TimeInterval) -> ScriptRunning {
        { type, source in try run(type, source: source, timeout: timeout) }
    }

    static func run(_ type: ContentType, source: String, timeout: TimeInterval) throws -> String {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("expansionlens-script-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        let executable: String
        var arguments: [String]
        switch type {
        case .appleScript:
            try source.write(to: temp, atomically: true, encoding: .utf8)
            executable = "/usr/bin/osascript"
            arguments = [temp.path]
        case .javaScript:
            try source.write(to: temp, atomically: true, encoding: .utf8)
            executable = "/usr/bin/osascript"
            arguments = ["-l", "JavaScript", temp.path]
        case .shellScript:
            try source.write(to: temp, atomically: true, encoding: .utf8)
            if source.hasPrefix("#!") {
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: temp.path)
                executable = temp.path
                arguments = []
            } else {
                executable = "/bin/sh"
                arguments = [temp.path]
            }
        default:
            return source
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        // Read while it runs, so a big output can't fill the pipe and stall it.
        var output = Data(), errors = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { output = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global().async { errors = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        let deadline = Date().addingTimeInterval(max(timeout, 0.5))
        while process.isRunning, Date() < deadline { usleep(10_000) }
        if process.isRunning {
            process.terminate()
            group.wait()
            throw Failure(message: "The script didn't finish within \(Int(timeout)) seconds.")
        }
        group.wait()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(message: message.isEmpty ? "The script failed (exit status \(process.terminationStatus))." : message)
        }
        var text = String(decoding: output, as: UTF8.self)
        // Scripts end their output with a newline; the snippet shouldn't.
        if text.hasSuffix("\n") { text.removeLast() }
        return text
    }
}
