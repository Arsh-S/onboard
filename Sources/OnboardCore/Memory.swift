import Foundation

/// Local second brain: markdown and text files chunked, embedded with Nomic (LM Studio, on this Mac),
/// searched by cosine similarity blended with keyword overlap. Nothing leaves the machine.
public final class MemoryIndex: @unchecked Sendable {
    public struct Chunk: Codable, Sendable {
        public let source: String      // file path
        public let title: String
        public let text: String
        public let modified: Date
        public var vector: [Float]
    }
    public struct Hit: Sendable { public let chunk: Chunk; public let score: Float }

    public var base = "http://127.0.0.1:1234/v1"
    public var embedModel = "text-embedding-nomic-embed-text-v1.5"
    public private(set) var chunks: [Chunk] = []
    public var folders: [URL]
    let store: URL
    let lock = NSLock()

    public init(folders: [URL], store: URL) {
        self.folders = folders; self.store = store
        if let d = try? Data(contentsOf: store), let c = try? JSONDecoder().decode([Chunk].self, from: d) { chunks = c }
    }

    public var count: Int { lock.lock(); defer { lock.unlock() }; return chunks.count }
    public var fileCount: Int { lock.lock(); defer { lock.unlock() }; return Set(chunks.map(\.source)).count }

    // MARK: indexing

    static let exts: Set<String> = ["md", "txt", "markdown"]

    /// Re-index new or changed files; drops chunks of deleted files.
    public func refresh() async {
        var files: [(URL, Date)] = []
        for f in folders {
            guard let en = FileManager.default.enumerator(at: f, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { continue }
            for case let u as URL in en where Self.exts.contains(u.pathExtension.lowercased()) {
                let m = (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                files.append((u, m))
            }
        }
        lock.lock()
        let known = Dictionary(chunks.map { ($0.source, $0.modified) }, uniquingKeysWith: { a, _ in a })
        let present = Set(files.map { $0.0.path })
        chunks.removeAll { !present.contains($0.source) }
        lock.unlock()
        let changed = files.filter { known[$0.0.path] == nil || known[$0.0.path]! < $0.1 }
        for (u, m) in changed {
            guard let text = try? String(contentsOf: u, encoding: .utf8) else { continue }
            let pieces = Self.split(text, title: u.deletingPathExtension().lastPathComponent)
            var new: [Chunk] = []
            for p in pieces { new.append(Chunk(source: u.path, title: p.title, text: p.text, modified: m, vector: [])) }
            if let vecs = try? await embed(new.map { "search_document: \($0.title). \($0.text)" }) {
                for i in new.indices where i < vecs.count { new[i].vector = vecs[i] }
            }
            lock.lock(); chunks.removeAll { $0.source == u.path }; chunks += new; lock.unlock()
        }
        save()
    }

    func save() {
        lock.lock(); let c = chunks; lock.unlock()
        try? FileManager.default.createDirectory(at: store.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(c) { try? d.write(to: store) }
    }

    /// Paragraph chunks of about 700 characters, each carrying the nearest heading as its title.
    static func split(_ text: String, title: String) -> [(title: String, text: String)] {
        var out: [(String, String)] = []
        var heading = title, buf = ""
        func flush() { let t = buf.trimmingCharacters(in: .whitespacesAndNewlines); if t.count > 20 { out.append((heading, t)) }; buf = "" }
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("#") { flush(); heading = title + ": " + line.trimmingCharacters(in: CharacterSet(charactersIn: "# ")); continue }
            if line.hasPrefix("---") && buf.isEmpty { continue }
            buf += line + "\n"
            if buf.count > 700 { flush() }
        }
        flush()
        return out
    }

    // MARK: search

    func embed(_ texts: [String]) async throws -> [[Float]] {
        var out: [[Float]] = []
        for batch in stride(from: 0, to: texts.count, by: 32).map({ Array(texts[$0..<min($0 + 32, texts.count)]) }) {
            var req = URLRequest(url: URL(string: base + "/embeddings")!)
            req.httpMethod = "POST"; req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: ["model": embedModel, "input": batch])
            req.timeoutInterval = 30
            let (d, _) = try await URLSession.shared.data(for: req)
            let j = try JSONSerialization.jsonObject(with: d) as? [String: Any]
            let data = (j?["data"] as? [[String: Any]]) ?? []
            out += data.map { ($0["embedding"] as? [Double] ?? []).map(Float.init) }
        }
        return out
    }

    static func words(_ s: String) -> Set<String> {
        Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 2 && !stop.contains($0) })
    }
    static let stop: Set<String> = ["the", "and", "for", "with", "that", "this", "what", "from", "about", "did", "was", "are", "you", "your", "his", "her", "say", "said", "when", "who", "how"]

    public func search(_ query: String, k: Int = 4) async -> [Hit] {
        lock.lock(); let all = chunks; lock.unlock()
        guard !all.isEmpty else { return [] }
        let q = (try? await embed(["search_query: " + query]))?.first ?? []
        let qw = Self.words(query)
        let scored = all.map { c -> Hit in
            var cos: Float = 0
            if !q.isEmpty && c.vector.count == q.count {
                var dot: Float = 0, na: Float = 0, nb: Float = 0
                for i in 0..<q.count { dot += q[i] * c.vector[i]; na += q[i] * q[i]; nb += c.vector[i] * c.vector[i] }
                cos = dot / (na.squareRoot() * nb.squareRoot() + 1e-9)
            }
            let cw = Self.words(c.title + " " + c.text)
            let kw = qw.isEmpty ? 0 : Float(qw.intersection(cw).count) / Float(qw.count)
            return Hit(chunk: c, score: cos * 0.75 + kw * 0.35)
        }
        return Array(scored.sorted { $0.score > $1.score }.prefix(k))
    }

    /// Save a fact the user asked to remember (a dated line in remembered.md, then indexed).
    public func remember(_ text: String) async {
        guard let dir = folders.first else { return }
        let f = dir.appendingPathComponent("remembered.md")
        let line = "- \(Date().formatted(date: .abbreviated, time: .shortened)): \(text)\n"
        if let h = try? FileHandle(forWritingTo: f) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? ("# Things I asked Onboard to remember\n\n" + line).write(to: f, atomically: true, encoding: .utf8) }
        await refresh()
    }
}
