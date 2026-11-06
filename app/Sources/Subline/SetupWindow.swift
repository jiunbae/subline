import AppKit
import SwiftUI
import SublineCore

/// First-run checklist: connect a source (browser extension, or Spotify/Music which need nothing),
/// then play something. Each step turns green on its own and the window closes when done. Also lists
/// the permissions and optional downloads and when each is needed.
@MainActor
final class SetupWindowController: NSObject, NSWindowDelegate {
    private let model: PlayerModel
    private var window: NSWindow?

    init(model: PlayerModel) { self.model = model }

    var isShown: Bool { window?.isVisible ?? false }

    func show() {
        // Re-register every time: picks up a browser installed (or an app moved) since launch.
        NMRegistrar.registerAll()
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
                             styleMask: [.titled, .closable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.delegate = self
            // A hosting *controller* drives the window size from the SwiftUI layout (height follows the checklist).
            let host = NSHostingController(rootView: SetupView(model: model, close: { [weak self] in self?.close() }))
            host.sizingOptions = [.preferredContentSize]
            w.contentViewController = host
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func close() { window?.close() }

    func windowWillClose(_ notification: Notification) {
        // Release the SwiftUI tree; an accessory app has no reason to keep it around.
        window?.contentViewController = nil
        window = nil
    }

    // MARK: Chrome helpers

    static var chromeApp: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") }

    static func openInChrome(_ url: URL) {
        if let app = chromeApp {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    static var storeURL: URL? {
        SublinePaths.storeExtensionID.flatMap { URL(string: "https://chromewebstore.google.com/detail/\($0)") }
    }

    static func loadUnpacked() {
        guard let dir = NMRegistrar.installUnpackedCopy() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([dir])
        if let u = URL(string: "chrome://extensions") { openInChrome(u) }
    }
}

private struct SetupView: View {
    let model: PlayerModel
    let close: () -> Void
    @State private var showDev = false
    @State private var showExtras = SetupView.demo

    /// `--setup-demo`: every step open and the extras expanded (screenshots, layout checks).
    private static let demo = CommandLine.arguments.contains("--setup-demo")
    private var extensionDone: Bool { model.connectionCount > 0 }
    /// Step 1 is done by either path: the browser extension connected, or Spotify/Music is playing.
    private var sourceDone: Bool { !Self.demo && (extensionDone || model.playingFromNativeApp) }
    private var playDone: Bool { model.hasTrack }
    private var hasBrowser: Bool { !Diagnostics.shared.registrations.isEmpty || SetupWindowController.chromeApp != nil }
    private var store: URL? { SetupWindowController.storeURL }
    private static func installed(_ id: String) -> Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Subline").font(.system(size: 20, weight: .bold))
                    Text("Floating artwork and synced lyrics for YouTube, YouTube Music, Spotify and Apple Music.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 8)

            VStack(alignment: .leading, spacing: 14) {
                StepRow(number: 1, title: "Connect where you listen", done: sourceDone, current: !sourceDone) {
                    sourceStep
                }
                StepRow(number: 2, title: "Play something", done: playDone, current: sourceDone && !playDone) {
                    HStack(spacing: 8) {
                        Button("Open YouTube Music") { SetupWindowController.openInChrome(URL(string: "https://music.youtube.com")!) }
                        Button("Open YouTube") { SetupWindowController.openInChrome(URL(string: "https://www.youtube.com")!) }
                        if Self.installed("com.spotify.client") { Button("Open Spotify") { Self.launch("com.spotify.client") } }
                        if Self.installed("com.apple.Music") { Button("Open Music") { Self.launch("com.apple.Music") } }
                    }
                    .controlSize(.small)
                    Text("The overlay appears when playback starts and fades away when you stop.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }

            if !sourceDone || Diagnostics.shared.hasProblem { TroubleshootingView(diagnostics: Diagnostics.shared) }

            DisclosureGroup(isExpanded: Binding(get: { showExtras || model.automationDenied }, set: { showExtras = $0 })) {
                ExtrasView(model: model).padding(.top, 6)
            } label: {
                Label("Permissions & optional downloads", systemImage: "slider.horizontal.3")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            }

            if sourceDone && playDone {
                Label("You're all set.", systemImage: "checkmark.seal.fill")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.green)
            }
            HStack {
                Text("⌃⌥⌘O show/hide  ·  ⌃⌥⌘L click-through  ·  ⌃⌥⌘Space play/pause")
                    .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                Spacer()
                Button(L10n.string(sourceDone && playDone ? "Done" : "Later")) { close() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: sourceDone && playDone) { _, done in
            // Leave it open while the extras are being read.
            if done, !showExtras { DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { if !showExtras { close() } } }
        }
    }

    private static func launch(_ id: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    @ViewBuilder private var sourceStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Label("YouTube and YouTube Music in your browser", systemImage: "globe")
                    .font(.system(size: 12, weight: .semibold))
                extensionStep
            }
            VStack(alignment: .leading, spacing: 4) {
                Label("Spotify or Apple Music", systemImage: "music.note")
                    .font(.system(size: 12, weight: .semibold))
                Text("Nothing to install: just play a song. The first time, macOS asks to let Subline see what's playing; click OK.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var extensionStep: some View {
        if !hasBrowser {
            Text("Needs Google Chrome or another Chromium browser (Arc, Brave, Edge, Vivaldi).").font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            Button("Get Google Chrome") { NSWorkspace.shared.open(URL(string: "https://www.google.com/chrome/")!) }
                .controlSize(.small)
        } else if let store {
            Button("Add to Chrome") { SetupWindowController.openInChrome(store) }
                .buttonStyle(.borderedProminent).controlSize(.small)
            Text("If Chrome shows “New extension added”, click Enable extension.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            DisclosureGroup("Developer install", isExpanded: $showDev) { devInstall }
                .font(.system(size: 11))
        } else {
            devInstall
        }
    }

    @ViewBuilder private var devInstall: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button("Load Unpacked Extension…") { SetupWindowController.loadUnpacked() }
                .buttonStyle(.borderedProminent).controlSize(.small)
            Text("Chrome opens its Extensions page and Finder shows the extension folder. Turn on **Developer mode**, click **Load unpacked**, and choose that folder.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 2)
    }
}

/// What may be asked for or downloaded, when, and what happens without it.
private struct ExtrasView: View {
    let model: PlayerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            item("hand.raised", "Automation (Spotify, Music)",
                 model.automationDenied
                    ? "Declined: Subline still shows the song from Spotify/Music notifications, but without the exact position, artwork from Music, or controls."
                    : "macOS asks once, when Spotify or Music first plays. It lets Subline read the song, position and artwork and send play/pause.",
                 warn: model.automationDenied) {
                Button("Open Automation Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
                }
            }
            item("character.bubble", "Translation languages (optional)",
                 "Only for Second Language › Translate on This Mac (lyrics in another language). YouTube's own auto-translation and romanization need nothing. macOS downloads a language once (a few hundred MB); translation then stays on this Mac.",
                 warn: false) {
                if model.pendingDownload != nil {
                    Button("Download Now…") { model.downloadTranslationLanguages() }
                }
                Button("Language & Region Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension")!)
                }
            }
            item("menubar.rectangle", "Menu bar and notch",
                 "Show the current line next to the menu bar icon or under the notch: menu › Also Show Current Line.",
                 warn: false) { EmptyView() }
            item("network", "Lyrics lookups",
                 "For YouTube Music, Spotify and Music, the app asks lrclib.net (title, artist, album, length) and keeps the result on this Mac. The extension itself sends nothing anywhere.",
                 warn: false) { EmptyView() }
        }
    }

    private func item<B: View>(_ icon: String, _ title: String, _ text: String, warn: Bool, @ViewBuilder buttons: () -> B) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: warn ? "exclamationmark.triangle.fill" : icon)
                .foregroundStyle(warn ? Color.orange : Color.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.string(title)).font(.system(size: 12, weight: .semibold))
                Text(L10n.string(text)).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) { buttons() }.controlSize(.small)
            }
        }
    }
}

private struct StepRow<Content: View>: View {
    let number: Int
    let title: String
    let done: Bool
    let current: Bool
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(done ? Color.green : (current ? Color.accentColor : Color.secondary.opacity(0.25)))
                    .frame(width: 24, height: 24)
                if done {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                } else {
                    Text("\(number)").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                }
            }
            .animation(.easeOut(duration: 0.2), value: done)
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.string(title)).font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(done ? .secondary : .primary)
                if !done { content }
            }
            Spacer(minLength: 0)
        }
    }
}

/// Shown until the extension connects: what the app checked, with Retry and Copy Diagnostics.
private struct TroubleshootingView: View {
    let diagnostics: Diagnostics
    @State private var expanded = false
    @State private var copied = false

    var body: some View {
        DisclosureGroup(isExpanded: Binding(get: { expanded || diagnostics.hasProblem }, set: { expanded = $0 })) {
            VStack(alignment: .leading, spacing: 5) {
                row(diagnostics.helperOK, L10n.string("Connection helper"), diagnostics.helperOK ? nil : diagnostics.helperPath)
                if let socket = diagnostics.socketError {
                    row(false, L10n.string("App connection"), socket)
                }
                if diagnostics.registrations.isEmpty {
                    row(false, L10n.string("No supported browser found"),
                        L10n.string("Install Google Chrome (or Chromium, Brave, Edge, Vivaldi, Arc), then press Retry."))
                }
                ForEach(diagnostics.registrations) { r in
                    row(r.error == nil, L10n.format("Registered with %@", r.browser), r.error)
                }
                Text("If everything is checked but nothing connects: reload the extension on the browser's Extensions page and reload YouTube tabs.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Retry") { NMRegistrar.registerAll() }
                    Button(copied ? "Copied" : "Copy Diagnostics") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(diagnostics.report, forType: .string)
                        copied = true
                    }
                }
                .controlSize(.small)
                .padding(.top, 2)
            }
            .padding(.top, 4)
        } label: {
            Label("Troubleshooting", systemImage: diagnostics.hasProblem ? "exclamationmark.triangle.fill" : "stethoscope")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(diagnostics.hasProblem ? Color.orange : Color.secondary)
        }
    }

    private func row(_ ok: Bool, _ title: String, _ detail: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(ok ? Color.green : Color.red).font(.system(size: 11))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 11.5))
                if let detail { Text(detail).font(.system(size: 10.5)).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true) }
            }
        }
    }
}
