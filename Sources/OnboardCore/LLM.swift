import Foundation

/// PrismML Bonsai through a local OpenAI-compatible server (LM Studio). Constrained JSON per call.
public final class Bonsai: @unchecked Sendable {
    public var base: String
    public var big: String      // planner
    public var small: String    // quick answers, routing
    public var extra: [String: Any] = [:]   // per-runtime fields (for example to switch thinking off)
    public private(set) var localBytes = 0
    public private(set) var lastTokPerSec = 0.0
    let session: URLSession

    /// Bonsai 2 thinks by default (thousands of tokens). An empty think block as an assistant prefill switches it off.
    public var noThink = true
    public init(base: String = "http://127.0.0.1:1234/v1", big: String = "bonsai2-9b", small: String = "bonsai2-2b") {
        self.base = base; self.big = big; self.small = small
        let c = URLSessionConfiguration.ephemeral; c.timeoutIntervalForRequest = 40
        session = URLSession(configuration: c)
    }

    public struct Reply: @unchecked Sendable { public let json: [String: Any]; public let secs: Double; public let tokens: Int; public var promptTokens = 0 }

    /// `schemaJSON` is a raw JSON schema string: property order is kept, and the model writes fields in that order
    /// (a Swift dictionary would shuffle them, and a small model reasons much better when "plan" comes first).
    public func json(system: String, user: String, schemaJSON: String, maxTokens: Int = 160, small useSmall: Bool = false, temperature: Double = 0.2, image: Data? = nil) async throws -> Reply {
        try await json(system: system, user: user, schema: ["__raw__": schemaJSON], maxTokens: maxTokens, small: useSmall, temperature: temperature, image: image)
    }

    public func json(system: String, user: String, schema: [String: Any], maxTokens: Int = 160, small useSmall: Bool = false, temperature: Double = 0.2, image: Data? = nil) async throws -> Reply {
        // A picture goes to Bonsai 2 9B, the one with the vision tower.
        let userContent: Any = image.map { [["type": "text", "text": user], ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + $0.base64EncodedString()]]] as [[String: Any]] } ?? user
        let raw = schema["__raw__"] as? String
        var body: [String: Any] = [
            "model": useSmall && image == nil ? small : big,
            "messages": [["role": "system", "content": system], ["role": "user", "content": userContent]] + (noThink ? [["role": "assistant", "content": "<think>\n\n</think>\n\n"]] : []),
            "max_tokens": maxTokens, "temperature": temperature,
            "response_format": ["type": "json_schema", "json_schema": ["name": "out", "strict": true, "schema": raw == nil ? schema : ["__SCHEMA__": 1]]],
        ]
        for (k, v) in extra { body[k] = v }
        var req = URLRequest(url: URL(string: base + "/chat/completions")!)
        req.httpMethod = "POST"; req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var data = try JSONSerialization.data(withJSONObject: body)
        if let raw, let str = String(data: data, encoding: .utf8) {
            data = Data(str.replacingOccurrences(of: "{\"__SCHEMA__\":1}", with: raw).utf8)
        }
        req.httpBody = data
        localBytes += req.httpBody?.count ?? 0
        let t0 = now()
        let (d, resp) = try await session.data(for: req)
        let dt = now() - t0
        if let h = resp as? HTTPURLResponse, h.statusCode != 200 { throw OnboardError("Bonsai HTTP \(h.statusCode): \(String(data: d, encoding: .utf8)?.prefix(240) ?? "")") }
        let j = try JSONSerialization.jsonObject(with: d) as? [String: Any]
        let content = (((j?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String) ?? "{}"
        let toks = ((j?["usage"] as? [String: Any])?["completion_tokens"] as? Int) ?? 0
        if toks > 8, dt > 0 { lastTokPerSec = Double(toks) / dt }
        let ptoks = ((j?["usage"] as? [String: Any])?["prompt_tokens"] as? Int) ?? 0
        return Reply(json: (try? JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any]) ?? [:], secs: dt, tokens: toks, promptTokens: ptoks)
    }

    public func models() async throws -> [String] {
        let (d, _) = try await session.data(from: URL(string: base + "/models")!)
        let j = try JSONSerialization.jsonObject(with: d) as? [String: Any]
        return ((j?["data"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
    }

    /// Tokens per second from a short free generation (also warms the model).
    public func speed(small useSmall: Bool = false) async -> Double? {
        let body: [String: Any] = ["model": useSmall ? small : big, "messages": [["role": "user", "content": "Count from 1 to 40, separated by spaces."]] + (noThink ? [["role": "assistant", "content": "<think>\n\n</think>\n\n"]] : []), "max_tokens": 48, "temperature": 0]
        var req = URLRequest(url: URL(string: base + "/chat/completions")!)
        req.httpMethod = "POST"; req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body.merging(extra) { a, _ in a })
        let t = now()
        guard let (d, _) = try? await session.data(for: req), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let n = (j["usage"] as? [String: Any])?["completion_tokens"] as? Int, n > 8 else { return nil }
        return Double(n) / (now() - t)
    }
}
