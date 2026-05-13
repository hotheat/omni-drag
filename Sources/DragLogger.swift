import Foundation

final class DragLogger {
    var debugMode = false

    private lazy var dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy.MM.dd"
        return formatter
    }()

    private lazy var timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    func log(_ message: @autoclosure () -> String) {
        let rendered = message()
        if debugMode {
            NSLog("%@", rendered)
            return
        }

        let now = Date()
        let logDirectory = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".local/share/omnidrag/log", isDirectory: true)
        let filename = "omnidrag.\(dayFormatter.string(from: now)).log"
        let logURL = logDirectory.appendingPathComponent(filename)
        let line = "\(timestampFormatter.string(from: now)) \(rendered)\n"

        do {
            try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: logURL.path) {
                try line.write(to: logURL, atomically: true, encoding: .utf8)
            } else if let data = line.data(using: .utf8), let handle = try? FileHandle(forWritingTo: logURL) {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            }

            let files = try FileManager.default.contentsOfDirectory(at: logDirectory, includingPropertiesForKeys: nil)
            for file in files where file.lastPathComponent != filename {
                try? FileManager.default.removeItem(at: file)
            }
        } catch {
            NSLog("%@", "Logging failed: \(error.localizedDescription)")
        }
    }
}
