import Foundation
import SpeakerKit

/// Persisted enrollment: running-mean centroid per person (sum + count so adaptation survives relaunch).
public struct EnrolledPerson: Codable, Sendable, Identifiable, Hashable {
    public var id: String { name }
    public var name: String
    public var sum: [Float]
    public var count: Float
    public var enrolledAt: Date
    public var centroid: [Float] { sum.map { $0 / count } }
}

/// Validated recipe: tile each clip to 30 s, diarize alone with numberOfSpeakers = 1, take the centroid,
/// compare by cosine distance in raw 256-d space. Show a name only if d1 < 0.60 and the margin to the
/// runner-up is > 0.10. Adapt the matched centroid (running mean, enrollment weight 3) when d1 < 0.45.
public final class SpeakerIdentifier: @unchecked Sendable {
    public static let embTile: Float = 30
    public static let showT: Float = 0.60, showMargin: Float = 0.10, adaptT: Float = 0.45, enrollWeight: Float = 3

    public let sk: SpeakerKit
    public private(set) var people: [EnrolledPerson]
    public let storeURL: URL?
    private let oneSpk = PyannoteDiarizationOptions(numberOfSpeakers: 1, centroidSource: .finalAssignment)
    private let lock = NSLock()
    /// Last enrollment clip, used to warm the CoreML pipeline (silence yields no centroid).
    public var warmAudio: [Float]?

    public struct Verdict: Sendable {
        public let name: String?
        public let nearest: String
        public let d1: Float
        public let margin: Float
        public let adapted: Bool
        public init(name: String?, nearest: String, d1: Float, margin: Float, adapted: Bool) {
            self.name = name; self.nearest = nearest; self.d1 = d1; self.margin = margin; self.adapted = adapted
        }
    }

    public var names: [String] { people.map { $0.name } }

    public init(sk: SpeakerKit, storeURL: URL? = nil) {
        self.sk = sk
        self.storeURL = storeURL
        self.people = []
        if let u = storeURL, let d = try? Data(contentsOf: u), let p = try? JSONDecoder().decode([EnrolledPerson].self, from: d) {
            people = p
        }
    }

    /// Enroll from a directory of `<Name>_enroll.wav` files (the spike / eval layout).
    public func enroll(fromDirectory dir: URL) async throws {
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix("_enroll.wav") }.sorted()
        guard !files.isEmpty else { throw OnboardError("no <Name>_enroll.wav in \(dir.path)") }
        for f in files {
            let name = String(f.dropLast("_enroll.wav".count))
            let audio = try loadAudio16k(dir.appendingPathComponent(f))
            try await enroll(name: name, audio: audio)
        }
    }

    /// Enroll (or re-enroll) one person from about 10 s of their speech.
    @discardableResult
    /// Add one more sample of a person's voice to their profile (creates the profile on the first sample).
    /// Short clips are tiled like at recognition time, so a one-word sample is embedded the same way it will be matched.
    public func addSample(name: String, audio: [Float], weight: Float = 1) async throws {
        let c = try await Self.embed(sk: sk, tileAudio(audio, to: Self.embTile), options: oneSpk)
        lock.withLock {
            if let i = people.firstIndex(where: { $0.name == name }) {
                for j in 0..<min(c.count, people[i].sum.count) { people[i].sum[j] += c[j] * weight }
                people[i].count += weight
            } else {
                people.append(EnrolledPerson(name: name, sum: c.map { $0 * weight }, count: weight, enrolledAt: Date()))
            }
        }
        try save()
    }

    public func enroll(name: String, audio: [Float]) async throws -> EnrolledPerson {
        let c = try await Self.embed(sk: sk, audio, options: oneSpk)
        let p = EnrolledPerson(name: name, sum: c.map { $0 * Self.enrollWeight }, count: Self.enrollWeight, enrolledAt: Date())
        store(p)
        try save()
        if let u = storeURL { try? writeWav16k(audio, to: u.deletingLastPathComponent().appendingPathComponent("\(name)_enroll.wav")) }
        warmAudio = audio
        return p
    }

    private func store(_ p: EnrolledPerson) {
        lock.withLock { people.removeAll { $0.name == p.name }; people.append(p); people.sort { $0.name < $1.name } }
    }

    private func match(_ v: [Float]) -> Verdict {
        lock.withLock {
            let dd = people.map { cosineDistance(v, $0.centroid) }
            let o = dd.enumerated().sorted { $0.element < $1.element }
            let d1 = o[0].element, m = o.count > 1 ? o[1].element - d1 : 1
            let show = d1 < Self.showT && m > Self.showMargin
            var adapted = false
            if show && d1 < Self.adaptT {
                let i = o[0].offset
                people[i].count += 1
                for j in 0..<v.count { people[i].sum[j] += v[j] }
                adapted = true
            }
            return Verdict(name: show ? people[o[0].offset].name : nil, nearest: people[o[0].offset].name, d1: d1, margin: m, adapted: adapted)
        }
    }

    public func remove(name: String) throws {
        lock.lock(); people.removeAll { $0.name == name }; lock.unlock()
        try save()
    }

    public func save() throws {
        guard let u = storeURL else { return }
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(people).write(to: u, options: .atomic)
    }

    public static func embed(sk: SpeakerKit, _ audio: [Float], options: PyannoteDiarizationOptions) async throws -> [Float] {
        let r = try await sk.diarize(audioArray: tileAudio(audio, to: embTile), options: options)
        guard let c = r.speakerCentroidEmbeddings.values.first else { throw OnboardError("SpeakerKit returned no centroid") }
        return c
    }

    public func embed(_ audio: [Float]) async throws -> [Float] { try await Self.embed(sk: sk, audio, options: oneSpk) }

    /// First CoreML call is slow; run one embedding on real speech at startup.
    public func warm() async {
        var a = warmAudio
        if a == nil, let u = storeURL, let first = people.first {
            a = try? loadAudio16k(u.deletingLastPathComponent().appendingPathComponent("\(first.name)_enroll.wav"))
        }
        if let a { _ = try? await embed(a) }
    }

    /// Distances from an enrolled person's centroid to every other person (for the enrollment screen).
    public func separation(of name: String) -> [(String, Float)] {
        guard let p = people.first(where: { $0.name == name }) else { return [] }
        return people.filter { $0.name != name }.map { ($0.name, cosineDistance(p.centroid, $0.centroid)) }
    }

    /// Unknown verdict when nobody is enrolled or the clip has no usable speech (SpeakerKit finds no speaker).
    public static let unknown = Verdict(name: nil, nearest: "", d1: 1, margin: 0, adapted: false)

    public func identify(_ audio: [Float]) async throws -> Verdict {
        guard !people.isEmpty else { return Self.unknown }
        let r = try await sk.diarize(audioArray: tileAudio(audio, to: Self.embTile), options: oneSpk)
        guard let v = r.speakerCentroidEmbeddings.values.first else { return Self.unknown }
        return match(v)
    }

    // MARK: Turn splitting (fast back-and-forth inside one VAD utterance)

    /// One speaker turn inside an utterance, in seconds relative to the utterance start.
    public struct Turn: Sendable {
        public var start: Float
        public var end: Float
        public var verdict: Verdict
        public var duration: Float { end - start }
        public init(start: Float, end: Float, verdict: Verdict) { self.start = start; self.end = end; self.verdict = verdict }
    }

    public static let minTurn: Float = 0.45      // shorter diarizer segments are merged into a neighbour
    public static let joinGap: Float = 0.35      // same-speaker segments closer than this are one turn
    public static let splitFrom: Float = 1.6     // utterances shorter than this are never split

    /// Split an utterance at speaker changes. Runs the diarizer with a free speaker count on the tiled clip,
    /// keeps the segments that fall in the first tile, then names each turn with the validated one-speaker
    /// recipe. Adjacent turns that resolve to the same person are merged, so a single speaker that the
    /// clusterer over-split still comes back as one turn.
    public func identifyTurns(_ audio: [Float]) async throws -> [Turn] {
        let len = Float(audio.count) / Float(SR)
        guard !people.isEmpty, len >= Self.splitFrom else {
            return [Turn(start: 0, end: len, verdict: try await identify(audio))]
        }
        let free = PyannoteDiarizationOptions(numberOfSpeakers: nil, centroidSource: .finalAssignment)
        // The segmenter pass and the dip probe (needed only when the segmenter finds one speaker) run together,
        // so a long utterance costs about one embedder round trip either way.
        async let probeTask: [Turn]? = len >= Self.probeFrom ? probeDips(audio, offset: 0) : nil
        let r = try await sk.diarize(audioArray: tileAudio(audio, to: Self.embTile), options: free)
        // Segments of the first tile only, as (speakerId, start, end), clipped to the clip length.
        var segs: [(id: Int, s: Float, e: Float)] = []
        for g in r.segments where g.startTime < len {
            guard let id = g.speaker.speakerId else { continue }
            segs.append((id, max(0, g.startTime), min(len, g.endTime)))
        }
        segs.sort { $0.s < $1.s }
        // Join same-speaker segments separated by a short gap.
        var joined: [(id: Int, s: Float, e: Float)] = []
        for g in segs {
            if let last = joined.last, last.id == g.id, g.s - last.e <= Self.joinGap { joined[joined.count - 1].e = max(last.e, g.e) }
            else { joined.append(g) }
        }
        // Absorb fragments shorter than minTurn into the longer neighbour.
        var i = 0
        while joined.count > 1, i < joined.count {
            if joined[i].e - joined[i].s < Self.minTurn {
                let prev = i > 0 ? joined[i - 1].e - joined[i - 1].s : -1
                let next = i + 1 < joined.count ? joined[i + 1].e - joined[i + 1].s : -1
                if prev >= next, i > 0 { joined[i - 1].e = joined[i].e; joined.remove(at: i); continue }
                if i + 1 < joined.count { joined[i + 1].s = joined[i].s; joined.remove(at: i); continue }
            }
            i += 1
        }
        if joined.count > 1 { _ = try? await probeTask }
        guard joined.count > 1 else {
            // One diarizer segment. The segmenter misses a change when the hand-over gap is under about 0.2 s,
            // so probe the deepest energy dips: if the two sides resolve to different people, cut there.
            if let cut = try await probeTask { return cut }
            // One speaker in the clip: the free pass already has its centroid, no second embedder call needed.
            if let id = joined.first?.id, let c = r.speakerCentroidEmbeddings[id] { return [Turn(start: 0, end: len, verdict: match(c))] }
            return [Turn(start: 0, end: len, verdict: try await identify(audio))]
        }
        // Make the turns contiguous: each boundary sits halfway through the gap between neighbours.
        var bounds: [(Float, Float)] = []
        for (k, g) in joined.enumerated() {
            let s: Float = k == 0 ? 0 : (joined[k - 1].e + g.s) / 2
            let e: Float = k == joined.count - 1 ? len : (g.e + joined[k + 1].s) / 2
            bounds.append((s, e))
        }
        var turns: [Turn] = []
        for (s, e) in bounds {
            let a = Array(audio[Int(s * Float(SR))..<Int(e * Float(SR))])
            turns.append(Turn(start: s, end: e, verdict: try await identify(a)))
        }
        return Self.mergeSameSpeaker(turns)
    }

    /// Merge neighbours that resolved to the same person (clusterer over-split one voice), and absorb turns
    /// the embedder could not place at all (no centroid) into the previous turn rather than showing "unknown".
    nonisolated public static func mergeSameSpeaker(_ turns: [Turn]) -> [Turn] {
        var merged: [Turn] = []
        for t in turns {
            if let last = merged.last, (last.verdict.name != nil && last.verdict.name == t.verdict.name) || t.verdict.nearest.isEmpty {
                merged[merged.count - 1].end = t.end
                if t.verdict.d1 < last.verdict.d1 { merged[merged.count - 1].verdict = t.verdict }
            } else if let last = merged.last, last.verdict.nearest.isEmpty {
                merged[merged.count - 1] = Turn(start: last.start, end: t.end, verdict: t.verdict)
            } else { merged.append(t) }
        }
        return merged
    }

    public static let probeFrom: Float = 2.5      // probe energy dips in single-segment clips at least this long
    public static let probeEdge: Float = 0.7      // a cut needs this much audio on both sides
    public static let probeMax = 2                // deepest dips tried per clip

    /// Candidate hand-over points: midpoints of the longest quiet runs (50 ms hop) away from the edges.
    nonisolated public static func dipCandidates(_ audio: [Float], maxCount: Int = probeMax) -> [Float] {
        let hop = SR / 20
        var rms: [Float] = []
        var i = 0
        while i + hop <= audio.count {
            var e: Float = 0
            for x in audio[i..<i + hop] { e += x * x }
            rms.append((e / Float(hop)).squareRoot()); i += hop
        }
        guard rms.count > 10 else { return [] }
        let sorted = rms.sorted(); let median = sorted[sorted.count / 2]
        let quiet = max(0.003, 0.3 * median)
        var runs: [(start: Int, len: Int)] = []
        var k = 0
        while k < rms.count {
            if rms[k] < quiet {
                let s = k; while k < rms.count, rms[k] < quiet { k += 1 }
                runs.append((s, k - s))
            } else { k += 1 }
        }
        let len = Float(audio.count) / Float(SR)
        var mids: [(t: Float, len: Int)] = []
        for r in runs where r.len >= 2 {
            let t: Float = (Float(r.start) + Float(r.len) / 2) * 0.05
            if t >= probeEdge, len - t >= probeEdge { mids.append((t, r.len)) }
        }
        mids.sort { $0.len > $1.len }
        let best: [Float] = mids.prefix(maxCount).map { $0.t }
        return best.sorted()
    }

    public static let probeD1: Float = 0.50, probeMargin: Float = 0.15   // both sides must be this sure before a cut is accepted

    /// Cut at the deepest dip when the two sides resolve to different people, then look again inside each side.
    /// Verdicts from the probe are reused as the turns' verdicts, so a found cut costs no extra embedder calls.
    private func probeDips(_ audio: [Float], offset: Float) async throws -> [Turn]? {
        let len = Float(audio.count) / Float(SR)
        guard len >= Self.probeFrom, let c = Self.dipCandidates(audio, maxCount: 1).first else { return nil }
        let n = Float(SR)
        let left = Array(audio[0..<Int(c * n)]), right = Array(audio[Int(c * n)..<audio.count])
        async let lt = identify(left)
        async let rt = identify(right)
        let (lv, rv) = try await (lt, rt)
        func sure(_ v: Verdict) -> Bool { v.name != nil && v.d1 < Self.probeD1 && v.margin > Self.probeMargin }
        guard sure(lv), sure(rv), lv.name != rv.name else { return nil }
        async let lTurns: [Turn]? = probeDips(left, offset: offset)
        async let rTurns: [Turn]? = probeDips(right, offset: offset + c)
        let l = try await lTurns ?? [Turn(start: offset, end: offset + c, verdict: lv)]
        let r = try await rTurns ?? [Turn(start: offset + c, end: offset + len, verdict: rv)]
        return Self.mergeSameSpeaker(l + r)
    }
}
