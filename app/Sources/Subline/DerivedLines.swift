import Foundation
import NaturalLanguage
import SublineCore
#if canImport(Translation)
import Translation
#endif

/// Second lines made on this Mac from the main text: romanization, or Apple's on-device translation
/// into the user's language. They're shown exactly like a second YouTube caption track (slot 2).
enum DerivedLines {
    static let romajiID = "@romaji"
    static let translateID = "@translate"
    static func isDerived(_ id: String?) -> Bool { id?.hasPrefix("@") == true }

    /// The user's languages in order, e.g. ["en", "ko"] (system-wide list, not the app's UI override).
    static var userLanguages: [String] {
        let list = (UserDefaults(suiteName: ".GlobalPreferences")?.array(forKey: "AppleLanguages") as? [String]) ?? Locale.preferredLanguages
        var seen = Set<String>()
        return list.compactMap { Locale(identifier: $0).language.languageCode?.identifier }.filter { seen.insert($0).inserted }
    }
    /// Translate into the first of the user's languages that isn't the text's own.
    static func targetCode(for source: String?) -> String {
        userLanguages.first { $0 != source } ?? userLanguages.first ?? "en"
    }
    static func name(_ code: String) -> String { L10n.locale.localizedString(forLanguageCode: code) ?? code }
    /// Menu label: the user's languages other than the first, when there are several.
    static var targetName: String {
        let langs = userLanguages
        return langs.count > 1 ? langs.map(name).joined(separator: " / ") : name(langs.first ?? "en")
    }

    static var translationSupported: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    /// Language of the whole text (the cue set's tag, else detected from the lines).
    static func language(of cues: [Cue], hint: String?) -> String? {
        if let hint, !hint.isEmpty { return Locale(identifier: hint).language.languageCode?.identifier ?? hint }
        let r = NLLanguageRecognizer()
        r.processString(String(cues.lazy.map(\.text).joined(separator: "\n").prefix(4000)))
        return r.dominantLanguage?.rawValue
    }

    /// Whether romanization would add anything (some line in a script we romanize).
    static func canRomanize(_ cues: [Cue]) -> Bool {
        cues.prefix(80).contains { Romanizer.script(of: $0.text) != nil }
    }

    /// One cue per main cue, same times, in the same order; "" where a line has nothing to add. The
    /// rows stay aligned with the main text, so the second line can follow it by position (untimed
    /// lyrics have no times to match on).
    static func romanized(_ cues: [Cue], lang: String?) -> [Cue] {
        let japanese = lang == "ja"
        var memo: [String: String?] = [:]
        return cues.map { c in
            let r = memo[c.text] ?? { let v = Romanizer.romanize(c.text, japanese: japanese); memo[c.text] = v; return v }()
            return Cue(s: c.s, e: c.e, text: r ?? "")
        }
    }

    /// Whether a derived set has anything to show.
    static func hasText(_ cues: [Cue]) -> Bool { cues.contains { !$0.text.isEmpty } }

    enum Translation: Sendable {
        case cues([Cue])
        /// The language pair works but isn't downloaded yet (source, target codes).
        case needsDownload(String, String)
        case unavailable
        case sameLanguage
    }

    static func translated(_ cues: [Cue], source: String?) async -> Translation {
        #if canImport(Translation)
        guard #available(macOS 26.0, *) else { return .unavailable }
        guard let source else { return .unavailable }
        let target = targetCode(for: source)
        if source == target { return .sameLanguage }
        let src = Locale.Language(identifier: source), dst = Locale.Language(identifier: target)
        switch await LanguageAvailability().status(from: src, to: dst) {
        case .installed: break
        case .supported:
            return .needsDownload(source, target)
        default: return .unavailable
        }
        let unique = Array(Set(cues.map(\.text).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }))
        guard !unique.isEmpty else { return .cues([]) }
        let session = TranslationSession(installedSource: src, target: dst)
        var map: [String: String] = [:]
        // Batches keep memory and latency bounded for long auto-generated captions.
        for chunk in stride(from: 0, to: unique.count, by: 200).map({ Array(unique[$0..<min($0 + 200, unique.count)]) }) {
            let requests = chunk.enumerated().map { TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset)) }
            guard let responses = try? await session.translations(from: requests) else { return .unavailable }
            for r in responses { if let i = r.clientIdentifier.flatMap(Int.init), i < chunk.count { map[chunk[i]] = r.targetText } }
            if Task.isCancelled { return .unavailable }
        }
        return .cues(cues.map { c in Cue(s: c.s, e: c.e, text: map[c.text] ?? "") })
        #else
        return .unavailable
        #endif
    }
}

#if canImport(Translation)
import SwiftUI
import AppKit

/// Asks macOS to download a translation language (the system shows its own download sheet).
@MainActor
enum TranslationDownloader {
    private static var window: NSWindow?

    static func show(source: String, target: String, done: @escaping () -> Void) {
        guard #available(macOS 15.0, *) else { return }
        window?.close()
        let view = DownloadView(source: source, target: target) {
            window?.close(); window = nil; done()
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 120), styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = L10n.string("Translation Languages")
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: view)
        w.center()
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        window = w
    }

    @available(macOS 15.0, *)
    private struct DownloadView: View {
        let source: String, target: String
        let finished: () -> Void
        @State private var config: TranslationSession.Configuration?
        var body: some View {
            VStack(spacing: 10) {
                Text(L10n.format("Preparing %@ → %@ translation…", DerivedLines.name(source), DerivedLines.name(target)))
                    .font(.headline)
                Text(L10n.string("macOS downloads the languages once; translation then runs on this Mac."))
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(20).frame(width: 360)
            .onAppear { config = .init(source: Locale.Language(identifier: source), target: Locale.Language(identifier: target)) }
            .translationTask(config) { session in
                try? await session.prepareTranslation()
                await MainActor.run { finished() }
            }
        }
    }
}
#endif
