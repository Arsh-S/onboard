import AppKit
import ScreenCaptureKit
import Vision

/// Onboard's eyes: a picture of the app's window, for the cases the accessibility tree cannot cover.
/// Text is read from the picture with Apple's on-device recognizer; Bonsai 2 looks at the same picture to check work.
public enum Eyes {
    public struct Line: Sendable { public let text: String; public let frame: CGRect }   // frame in global screen points

    public static var permitted: Bool { CGPreflightScreenCaptureAccess() }
    @discardableResult public static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    /// A picture of one app's window (works while other windows cover it). Falls back to that area of the display.
    public static func capture(pid: pid_t, windowFrame: CGRect, maxSide: CGFloat = 1600) async -> CGImage? {
        guard permitted, windowFrame.width > 40, windowFrame.height > 40,
              let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) else { return nil }
        let scale = min(2, maxSide / max(windowFrame.width, windowFrame.height))
        let cfg = SCStreamConfiguration()
        cfg.width = Int(windowFrame.width * scale); cfg.height = Int(windowFrame.height * scale)
        cfg.showsCursor = false
        let mine = content.windows.filter { $0.owningApplication?.processID == pid && $0.windowLayer == 0 }
        if let w = mine.min(by: { dist($0.frame, windowFrame) < dist($1.frame, windowFrame) }), dist(w.frame, windowFrame) < 40 {
            return try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: w), configuration: cfg)
        }
        guard let display = content.displays.first(where: { $0.frame.intersects(windowFrame) }) ?? content.displays.first else { return nil }
        let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        cfg.sourceRect = windowFrame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        return try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingApplications: own, exceptingWindows: []), configuration: cfg)
    }

    /// The text recognizer takes seconds on its first use: pay that at launch, not during a task.
    public static func warm() {
        DispatchQueue.global(qos: .utility).async {
            guard let ctx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue), let img = ctx.makeImage() else { return }
            _ = readText(img, windowFrame: CGRect(x: 0, y: 0, width: 64, height: 64))
        }
    }

    static func dist(_ a: CGRect, _ b: CGRect) -> CGFloat { abs(a.minX - b.minX) + abs(a.minY - b.minY) + abs(a.width - b.width) + abs(a.height - b.height) }

    /// Every piece of text in the picture with where it is on screen.
    public static func readText(_ image: CGImage, windowFrame: CGRect, max: Int = 60) -> [Line] {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate; req.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([req])
        var out: [Line] = []
        for o in req.results ?? [] {
            guard let c = o.topCandidates(1).first, c.confidence > 0.4 else { continue }
            let t = c.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.count > 1 || t.first?.isNumber == true else { continue }
            let b = o.boundingBox   // normalized, origin bottom-left
            out.append(Line(text: t, frame: CGRect(x: windowFrame.minX + b.minX * windowFrame.width, y: windowFrame.minY + (1 - b.maxY) * windowFrame.height,
                                                   width: b.width * windowFrame.width, height: b.height * windowFrame.height)))
        }
        out.sort { abs($0.frame.minY - $1.frame.minY) > 6 ? $0.frame.minY < $1.frame.minY : $0.frame.minX < $1.frame.minX }
        return Array(out.prefix(max))
    }

    /// JPEG for the model, scaled so the long side is at most `maxSide` pixels.
    public static func jpeg(_ image: CGImage, maxSide: CGFloat = 1024, quality: CGFloat = 0.6) -> Data? {
        let s = min(1, maxSide / CGFloat(max(image.width, image.height)))
        let w = Int(CGFloat(image.width) * s), h = Int(CGFloat(image.height) * s)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let scaled = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: scaled).representation(using: .jpeg, properties: [.compressionFactor: quality])
    }
}

public extension ScreenSnapshot {
    /// The same snapshot plus text read from a picture of the window, as elements that can be clicked where they are.
    func adding(seen lines: [Eyes.Line]) -> ScreenSnapshot {
        let known = Set(elements.map { $0.label.lowercased() })
        var els = elements; var id = (elements.map(\.id).max() ?? 0) + 1
        for l in lines where !known.contains(l.text.lowercased()) {
            els.append(UIElement(id: id, role: "seen", label: l.text, value: "", frame: l.frame)); id += 1
        }
        // Pieces on the same line belong together (a table row): give them to the model as one readable line too.
        var rows: [[Eyes.Line]] = []
        for l in lines {
            if let last = rows.last?.last, abs(last.frame.midY - l.frame.midY) < 7 { rows[rows.count - 1].append(l) } else { rows.append([l]) }
        }
        for r in rows where r.count > 1 {
            let u = r.dropFirst().reduce(r[0].frame) { $0.union($1.frame) }
            els.append(UIElement(id: 0, role: "text", label: r.sorted { $0.frame.minX < $1.frame.minX }.map(\.text).joined(separator: " | "), value: "", frame: u))
        }
        let s = ScreenSnapshot(app: app, pid: pid, window: window, windowFrame: windowFrame, elements: els, menus: menus, refs: refs, menuRefs: menuRefs, secs: secs)
        s.menuTitleFrames = menuTitleFrames; s.seen = true
        return s
    }
}
