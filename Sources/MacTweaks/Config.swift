import AppKit

/// Settings from ~/.config/mactweaks/config.yaml, addressed by dotted path (`dock_window_list.font_size`).
/// Supports the YAML subset a flat config needs: nested `key: value` maps, optional quotes, `#` comments.
@MainActor
enum Config {
    static let url = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/mactweaks/config.yaml")

    private static var values: [String: String] = [:]
    private static var loadedModificationDate: Date?
    private static var lastCheck = Date.distantPast

    private static let defaultContents = """
        # MacTweaks configuration. Changes apply the next time a feature uses them; no restart needed.

        dock_window_list:
          font_size: 13
          # The list fits its window titles between these widths (points); set both equal for a fixed width.
          min_width: 160
          # max_width defaults to 360 at font size 13 and scales with the font.
          # max_width: 360

        # Per device type: natural, classic, or system (leave as set in System Settings).
        scroll_direction:
          trackpad: natural
          mouse: classic

        """

    static func double(_ key: String) -> Double? {
        string(key).flatMap(Double.init)
    }

    static func string(_ key: String) -> String? {
        reloadIfChanged()
        return values[key]
    }

    /// Opens the file in its default editor, creating it with defaults first if needed.
    static func openInEditor() {
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? defaultContents.write(to: url, atomically: true, encoding: .utf8)
        }
        if NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open([url], withApplicationAt: URL(filePath: "/System/Applications/TextEdit.app"),
                                    configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// Cheap enough to call per scroll event: the file is checked at most once a second,
    /// and only parsed when its modification date changes.
    private static func reloadIfChanged() {
        guard Date().timeIntervalSince(lastCheck) >= 1 else { return }
        lastCheck = Date()
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        guard modified != loadedModificationDate else { return }
        loadedModificationDate = modified
        values = (try? String(contentsOf: url, encoding: .utf8)).map(parse) ?? [:]
    }

    static func parse(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        var parents: [(indent: Int, key: String)] = []
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.prefix { $0 != "#" }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let indent = line.prefix { $0 == " " }.count
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard !key.isEmpty else { continue }

            while let last = parents.last, last.indent >= indent { parents.removeLast() }
            if value.isEmpty {
                parents.append((indent, key))
            } else {
                values[(parents.map(\.key) + [key]).joined(separator: ".")] = value
            }
        }
        return values
    }
}
