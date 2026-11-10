// Film staging code: made-up songs for the landing film. Never runs in the live app.
import AppKit
import SublineCore
import SwiftUI

/// The film's songs. Titles, artists, lyrics and artwork are invented for the film; the lyrics go
/// through the same parser, timeline and romanizer as a real LRCLIB answer.
@MainActor
struct LandingSong {
    let title: String
    let artist: String
    let artwork: NSImage?
    let accent: Color
    let main: CueTimeline
    let secondary: CueTimeline?

    init(title: String, artist: String, artwork: NSImage?, accent: Color, lrc: String, romanize: String? = nil) {
        self.title = title; self.artist = artist; self.artwork = artwork; self.accent = accent
        let cues = Lyrics.parseLRC(lrc, duration: 200)
        main = CueTimeline(cues: cues, synced: true)
        if let lang = romanize, DerivedLines.canRomanize(cues) {
            secondary = CueTimeline(cues: DerivedLines.romanized(cues, lang: lang), synced: true)
        } else {
            secondary = nil
        }
    }

    /// The model as the overlay would see it at media time `t`.
    func stage(_ model: PlayerModel, at t: Double) {
        model.stageFilm(title: title, artist: artist, artwork: artwork, accent: accent,
                        main: main, secondary: secondary, at: t)
    }

    static let sunset = LandingSong(
        title: "Sunset Drive", artist: "Lumen Coast", artwork: PlayerModel.sampleArtwork,
        accent: Color(red: 0.55, green: 0.25, blue: 0.65),
        lrc: """
        [ti:Sunset Drive]
        [ar:Lumen Coast]
        [00:00.00]City lights are fading slow
        [00:03.20]Hold the moment, let it glow
        [00:06.40]Every word is on its way
        [00:09.60]Sing it back another day
        [00:12.80]Nothing left but you and me
        [00:16.00]Floating where the light is free
        [00:19.20]Turn it up and let it play
        """)

    static let dawn = LandingSong(
        title: "Asa no Uta", artist: "Lumen Coast", artwork: dawnArtwork,
        accent: Color(red: 0.18, green: 0.42, blue: 0.62),
        lrc: """
        [00:00.00]夜明けまで 歌い続けよう
        [00:04.00]消えない光を 抱きしめて
        [00:08.00]明日の空へ
        """,
        romanize: "ja")

    /// Original abstract cover for the second song (never a real one).
    static let dawnArtwork: NSImage? = {
        let art = ZStack {
            LinearGradient(colors: [Color(red: 0.40, green: 0.82, blue: 0.95), Color(red: 0.16, green: 0.24, blue: 0.55)],
                           startPoint: .top, endPoint: .bottom)
            Circle().fill(Color(red: 1.0, green: 0.95, blue: 0.80)).frame(width: 120).offset(x: -60, y: -70)
            Capsule().fill(Color(red: 0.10, green: 0.14, blue: 0.36)).frame(width: 520, height: 200).offset(y: 170)
            Capsule().fill(Color(red: 0.20, green: 0.30, blue: 0.62)).frame(width: 420, height: 160).offset(x: 120, y: 150)
        }
        .frame(width: 400, height: 400)
        .clipped()
        let r = ImageRenderer(content: art)
        r.scale = 1
        return r.nsImage
    }()
}
