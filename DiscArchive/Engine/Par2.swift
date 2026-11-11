import Foundation

/// Recovery data via `par2` (par2cmdline from Homebrew). Optional: the app works without it.
enum Par2 {
    static let candidates = ["/usr/local/bin/par2", "/opt/homebrew/bin/par2"]

    static func find() -> URL? {
        var paths = candidates
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        paths.append(home + "/.local/bin/par2")
        return paths.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    enum Failure: LocalizedError {
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .failed(let detail): "par2 could not create recovery data. \(detail)"
            }
        }
    }

    /// Creates `<output>/<name>.par2` plus recovery volumes for every file of one game.
    /// `base` is the folder that holds the game folder, so the names stored inside the par2 files
    /// match the disc layout ("Fallout 2/setup_fallout2.exe"). Returns the created files.
    static func create(tool: URL, percent: Int, name: String, base: URL, files: [URL], output: URL,
                       progress: @escaping @Sendable (Double) -> Void) async throws -> [URL] {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let target = output.appendingPathComponent(name + ".par2")
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: output.path)) ?? [])

        let process = Process()
        process.executableURL = tool
        process.arguments = ["create", "-r\(percent)", "-n4", "-B", base.path, target.path] + files.map(\.path)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let log = LogBuffer()

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            log.append(text)
            if let value = lastPercent(in: text) { progress(value / 100) }
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { p in
                    pipe.fileHandleForReading.readabilityHandler = nil
                    if p.terminationStatus == 0 {
                        cont.resume()
                    } else if p.terminationReason == .uncaughtSignal {
                        cont.resume(throwing: CancellationError())
                    } else {
                        cont.resume(throwing: Failure.failed(log.tail()))
                    }
                }
                do { try process.run() } catch { cont.resume(throwing: error) }
            }
        } onCancel: {
            process.terminate()
        }

        let after = Set((try? FileManager.default.contentsOfDirectory(atPath: output.path)) ?? [])
        return after.subtracting(before)
            .filter { $0.hasPrefix(name) && $0.hasSuffix(".par2") }
            .sorted()
            .map { output.appendingPathComponent($0) }
    }

    /// par2 prints "Processing: 12.3%" style updates separated by carriage returns.
    static func lastPercent(in text: String) -> Double? {
        let pattern = try! NSRegularExpression(pattern: #"(\d{1,3}(?:\.\d+)?)%"#)
        let range = NSRange(text.startIndex..., in: text)
        guard let match = pattern.matches(in: text, range: range).last,
              let r = Range(match.range(at: 1), in: text) else { return nil }
        return Double(text[r])
    }
}

/// Keeps the last few kilobytes of a tool's output for error messages.
final class LogBuffer: @unchecked Sendable {
    private var text = ""
    private let lock = NSLock()

    func append(_ s: String) {
        lock.lock(); defer { lock.unlock() }
        text += s
        if text.count > 8000 { text = String(text.suffix(4000)) }
    }

    func tail() -> String {
        lock.lock(); defer { lock.unlock() }
        return text.split(whereSeparator: \.isNewline).suffix(4).joined(separator: " ")
    }
}
