import AppKit
import SwiftUI
import OnboardOverlay

struct SettingsData: Equatable {
    var hearing = LoadState.ready
    var thinking = LoadState.ready
    var speaking = LoadState.ready
    var tokPerSec = 0.0
    var notes = 0
    var indexing = false
    var axTrusted = false
    var eyesGranted = false
    var micGranted = false
    var memoryPath = ""
    var speakAnswers = true
    var failedHotkeys: Set<UInt32> = []
    var voiceReady = true
    var voiceEnrolled = false
    var voiceEnrolling = false
    var voiceProgress = 0.0
    var voiceMessage = ""
    var voiceLock = true
    var alwaysListening = false
    var voiceCanLearn = false
    var voiceLast = ""
}

struct SettingsActions {
    var grantAccessibility: () -> Void = {}
    var grantMicrophone: () -> Void = {}
    var grantEyes: () -> Void = {}
    var openFolder: () -> Void = {}
    var reindex: () -> Void = {}
    var toggleSpeak: () -> Void = {}
    var enrollVoice: () -> Void = {}
    var toggleLock: () -> Void = {}
    var toggleAlways: () -> Void = {}
    var learnVoice: () -> Void = {}
}

struct SettingsView: View {
    let data: SettingsData
    @Binding var owner: String
    var icon: NSImage?
    var preview = false
    var act = SettingsActions()

    static let width: CGFloat = 820

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 18) {
                    section("Models") {
                        modelRow("ear", "Hearing", "Argmax WhisperKit", data.hearing)
                        line
                        modelRow("brain", "Thinking", "PrismML Bonsai 2 9B and 2B via LM Studio", data.thinking,
                                 readyText: data.tokPerSec > 0 ? String(format: "%.0f tok/s", data.tokPerSec) : "Ready")
                        line
                        modelRow("speaker.wave.2", "Speaking", "Argmax TTSKit", data.speaking)
                        line
                        modelRow("books.vertical", "Memory", "\(data.notes) \(data.notes == 1 ? "note" : "notes") indexed",
                                 data.indexing ? .loading : .ready, loadingText: "Indexing")
                    }
                    section("Permissions") {
                        permissionRow("accessibility", "Accessibility", "See and operate your apps", data.axTrusted, act.grantAccessibility)
                        line
                        permissionRow("mic", "Microphone", "Hear you while you hold a key", data.micGranted, act.grantMicrophone)
                        line
                        permissionRow("eye", "Screen Recording", "Look at the screen to check its own work", data.eyesGranted, act.grantEyes)
                    }
                }
                .frame(width: 408)
                VStack(alignment: .leading, spacing: 18) {
                    section("Memory folder") {
                        HStack(spacing: 10) {
                            tile("folder")
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Notes Onboard remembers").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.primary)
                                Text(data.memoryPath)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.secondary)
                                    .lineLimit(1).truncationMode(.head)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12).frame(height: 50)
                        HStack(spacing: 8) {
                            Button("Open folder", action: act.openFolder).buttonStyle(SoftButtonStyle())
                            Button(data.indexing ? "Indexing" : "Re-index", action: act.reindex).buttonStyle(SoftButtonStyle())
                                .disabled(data.indexing).opacity(data.indexing ? 0.5 : 1)
                            Spacer(minLength: 0)
                        }
                        .padding(.leading, 50).padding(.bottom, 12)
                    }
                    section("You") {
                        HStack(spacing: 10) {
                            tile("person")
                            Text("Your name").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.primary)
                            Spacer()
                            ownerField
                        }
                        .padding(.horizontal, 12).frame(height: 46)
                        line
                        HStack(spacing: 10) {
                            tile("speaker.wave.2")
                            Text("Speak answers").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.primary)
                            Spacer()
                            MiniToggle(isOn: data.speakAnswers, action: act.toggleSpeak)
                        }
                        .padding(.horizontal, 12).frame(height: 46)
                    }
                    section("Voice lock") {
                        HStack(spacing: 10) {
                            tile("waveform")
                            VStack(alignment: .leading, spacing: 2) {
                                Text(data.voiceEnrolled ? "Onboard knows your voice" : "Teach Onboard your voice").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.primary)
                                Text(data.voiceEnrolling ? data.voiceMessage : data.voiceMessage.isEmpty ? (data.voiceReady ? (data.voiceEnrolled ? "Train again any time. \(data.voiceLast)" : "A one minute guided training. Argmax SpeakerKit, on this Mac.") : "Loading the voice model") : data.voiceMessage)
                                    .font(.system(size: data.voiceEnrolling ? 14 : 12, weight: data.voiceEnrolling ? .semibold : .regular))
                                    .foregroundStyle(data.voiceEnrolling ? Theme.accent : Theme.secondary)
                                    .lineLimit(4).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                                if data.voiceEnrolling { ProgressView(value: data.voiceProgress).tint(Theme.accent).frame(width: 170) }
                            }
                            .layoutPriority(1)
                            Spacer(minLength: 8)
                            if data.voiceCanLearn && !data.voiceEnrolling {
                                Button("That was me") { act.learnVoice() }
                                    .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.primary)
                                    .padding(.horizontal, 10).frame(height: 28)
                                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.10)))
                            }
                            Button(data.voiceEnrolled ? "Retrain" : "Train") { act.enrollVoice() }
                                .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.ink)
                                .padding(.horizontal, 12).frame(height: 28)
                                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.accent))
                                .disabled(!data.voiceReady || data.voiceEnrolling).opacity(!data.voiceReady || data.voiceEnrolling ? 0.5 : 1)
                        }
                        .padding(.horizontal, 12).frame(minHeight: 62)
                        line
                        HStack(spacing: 10) {
                            tile("lock")
                            Text("Only obey my voice").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.primary)
                            Spacer()
                            MiniToggle(isOn: data.voiceLock, action: act.toggleLock)
                        }
                        .padding(.horizontal, 12).frame(height: 46)
                        line
                        HStack(spacing: 10) {
                            tile("ear")
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Always listening").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.primary)
                                Text("Say \"Onboard, ...\" and it gets to work").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                            }
                            Spacer()
                            MiniToggle(isOn: data.alwaysListening, action: act.toggleAlways)
                        }
                        .padding(.horizontal, 12).frame(height: 52)
                    }
                    section("How to use") {
                        ForEach(Array(Hotkeys.all.enumerated()), id: \.offset) { i, spec in
                            if i > 0 { Theme.hairline.frame(height: 1).padding(.leading, 12) }
                            hotkeyRow(spec)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 24).padding(.top, 40).padding(.bottom, 24)
        .frame(width: Self.width)
        .background(Theme.background)
        .environment(\.colorScheme, .dark)
    }

    // MARK: pieces

    private var header: some View {
        HStack(spacing: 14) {
            Group {
                if let icon {
                    Image(nsImage: icon).resizable().interpolation(.high)
                        .scaleEffect(1.22)
                        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Color.white.opacity(0.06))
                        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
                        .overlay(BrandMark(size: 30))
                }
            }
            .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text("Onboard").font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.primary)
                Text("An agent with its own cursor. Everything runs on this Mac.")
                    .font(.system(size: 13)).foregroundStyle(Theme.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(UI.ok).frame(width: 6, height: 6).shadow(color: UI.ok.opacity(0.7), radius: 3)
                Text("On-device  ·  0 B to cloud").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
            }
            .padding(.horizontal, 11).frame(height: 28)
            .background(Capsule().fill(Color.white.opacity(0.05)))
            .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
        }
    }

    private var line: some View { Theme.hairline.frame(height: 1).padding(.leading, 50) }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold)).tracking(0.7)
                .foregroundStyle(Theme.tertiary)
                .padding(.leading, 4)
            VStack(spacing: 0) { content() }
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(UI.card))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
        }
    }

    private func tile(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.accent)
            .frame(width: 28, height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.accent.opacity(0.10)))
    }

    private func twoLine(_ title: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.primary)
            Text(sub).font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1)
        }
    }

    private func modelRow(_ symbol: String, _ title: String, _ sub: String, _ state: LoadState,
                          readyText: String = "Ready", loadingText: String = "Loading") -> some View {
        HStack(spacing: 10) {
            tile(symbol)
            twoLine(title, sub)
            Spacer(minLength: 8)
            switch state {
            case .ready:
                HStack(spacing: 6) {
                    Circle().fill(UI.ok).frame(width: 6, height: 6)
                    Text(readyText).font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.secondary)
                }
            case .loading:
                HStack(spacing: 6) {
                    Spinner(size: 11, animated: !preview)
                    Text(loadingText).font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                }
            case .failed(let why):
                HStack(spacing: 6) {
                    Circle().fill(Theme.warn).frame(width: 6, height: 6)
                    Text(why).font(.system(size: 12)).foregroundStyle(Theme.warn)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 12).frame(height: 50)
    }

    private func permissionRow(_ symbol: String, _ title: String, _ sub: String, _ granted: Bool, _ grant: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            tile(symbol)
            twoLine(title, sub)
            Spacer(minLength: 8)
            if granted {
                HStack(spacing: 5) {
                    CheckDraw(size: 16, animated: !preview)
                    Text("Granted").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
            } else {
                Button("Grant access", action: grant).buttonStyle(SoftButtonStyle(prominent: true))
            }
        }
        .padding(.horizontal, 12).frame(height: 50)
    }

    private var ownerField: some View {
        Group {
            if preview {
                Text(owner).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField("", text: $owner, prompt: Text("Name").foregroundStyle(Theme.tertiary)).textFieldStyle(.plain).tint(Theme.accent)
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(Theme.primary)
        .padding(.horizontal, 9)
        .frame(width: 150, height: 28)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.strongLine, lineWidth: 1))
    }

    private func hotkeyRow(_ spec: HotkeySpec) -> some View {
        let taken = data.failedHotkeys.contains(spec.action.rawValue)
        return HStack(spacing: 10) {
            HStack(spacing: 4) { ForEach(spec.keys, id: \.self) { Keycap($0) } }
                .frame(width: 106, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(spec.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.primary)
                Text(taken ? "This shortcut is taken by another app" : spec.hint)
                    .font(.system(size: 12)).foregroundStyle(taken ? Theme.warn : Theme.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).frame(height: 50)
    }
}

struct SettingsHost: View {
    let model: AppModel
    let icon: NSImage?
    var body: some View {
        @Bindable var m = model
        SettingsView(data: model.settingsData, owner: $m.owner, icon: icon,
                     act: SettingsActions(grantAccessibility: { model.requestAccessibility() },
                                          grantMicrophone: { model.requestMicrophone() },
                                          grantEyes: { model.requestEyes() },
                                          openFolder: { model.openMemoryFolder() },
                                          reindex: { model.reindex() },
                                          toggleSpeak: { model.speakAnswers.toggle() },
                                          enrollVoice: { model.voice.enroll() },
                                          toggleLock: { model.voice.lockEnabled.toggle() },
                                          toggleAlways: { model.voice.alwaysListening.toggle() },
                                          learnVoice: { model.voice.learnLastRejected() }))
    }
}

extension AppModel {
    var settingsData: SettingsData {
        SettingsData(hearing: hearing, thinking: thinking, speaking: speaking, tokPerSec: tokPerSec, notes: notes, indexing: indexing,
                     axTrusted: axTrusted, eyesGranted: eyesGranted, micGranted: micGranted,
                     memoryPath: (memoryFolder.path as NSString).abbreviatingWithTildeInPath,
                     speakAnswers: speakAnswers, failedHotkeys: hotkeyFailures,
                     voiceReady: voice.state == .ready, voiceEnrolled: voice.enrolled, voiceEnrolling: voice.enrolling,
                     voiceProgress: voice.enrollProgress, voiceMessage: voice.enrollMessage,
                     voiceLock: voice.lockEnabled, alwaysListening: voice.alwaysListening,
                     voiceCanLearn: voice.canLearnLast,
                     voiceLast: voice.lastDistance.map { String(format: "Last match %.0f%%.", max(0, min(1, 1 - Double($0))) * 100) } ?? "")
    }
}

@MainActor final class SettingsWindowController {
    private let window: NSWindow

    init(model: AppModel) {
        // Inside the .app bundle this is the real icon; a bare binary falls back to the drawn mark.
        let icon: NSImage? = Bundle.main.bundlePath.hasSuffix(".app") ? NSApp.applicationIconImage : nil
        let host = NSHostingView(rootView: SettingsHost(model: model, icon: icon))
        window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                          styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: true)
        window.title = "Onboard"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(Theme.background)
        window.contentView = host
        window.center()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
