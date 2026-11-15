import AppKit
import Foundation

/// File work done directly (listing and moving), not by clicking through Finder: exact, fast, and easy to verify.
public enum Files {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let known = ["downloads": "Downloads", "desktop": "Desktop", "documents": "Documents", "pictures": "Pictures", "movies": "Movies", "music": "Music", "home": ""]

    /// "Downloads", "the desktop", "~/Documents/OnboardDemo", "/tmp/x", or a name inside `base`.
    public static func folder(_ raw: String, inside base: URL? = nil) -> URL {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        for lead in ["the ", "my "] where s.lowercased().hasPrefix(lead) { s = String(s.dropFirst(lead.count)) }
        if s.lowercased().hasSuffix(" folder") { s = String(s.dropLast(7)) }
        if s.hasPrefix("/") { return URL(fileURLWithPath: s) }
        if s.hasPrefix("~") { return URL(fileURLWithPath: (s as NSString).expandingTildeInPath) }
        if let k = known[s.lowercased()] { return k.isEmpty ? home : home.appendingPathComponent(k) }
        if let base { return base.appendingPathComponent(s) }
        return home.appendingPathComponent(s)
    }

    /// Visible files in a folder whose name or extension matches `filter` ("pdf", "pdfs", "invoice", "" for all).
    public static func list(_ dir: URL, filter: String) -> [URL] {
        var f = filter.lowercased().trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "*.", with: "").replacingOccurrences(of: ".", with: "")
        for w in ["every ", "all ", "the ", " files", " file"] { f = f.replacingOccurrences(of: w, with: "") }
        if f == "all" || f == "everything" || f == "files" { f = "" }
        let kinds: [String: Set<String>] = ["image": ["png", "jpg", "jpeg", "heic", "gif", "webp"], "picture": ["png", "jpg", "jpeg", "heic", "gif", "webp"], "screenshot": ["png"],
                                            "video": ["mp4", "mov", "mkv"], "document": ["pdf", "doc", "docx", "txt", "md", "pages"], "spreadsheet": ["csv", "xlsx", "numbers"]]
        let single = f.hasSuffix("s") && f.count > 3 ? String(f.dropLast()) : f
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])) ?? []
        return items.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }.filter { u in
            if f.isEmpty { return true }
            let ext = u.pathExtension.lowercased(), name = u.lastPathComponent.lowercased()
            if let set = kinds[single] { return set.contains(ext) }
            return ext == f || ext == single || name.contains(f) || name.contains(single)
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Move files, creating the destination. Never overwrites: a file whose name is taken is left where it is.
    public static func move(_ files: [URL], to dest: URL) -> (moved: Int, skipped: [String]) {
        try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        var moved = 0; var skipped: [String] = []
        for f in files {
            let target = dest.appendingPathComponent(f.lastPathComponent)
            if FileManager.default.fileExists(atPath: target.path) { skipped.append(f.lastPathComponent); continue }
            do { try FileManager.default.moveItem(at: f, to: target); moved += 1 } catch { skipped.append(f.lastPathComponent) }
        }
        return (moved, skipped)
    }

    public static func short(_ u: URL) -> String { (u.path as NSString).abbreviatingWithTildeInPath }
}
