import Testing
import Foundation
@testable import SublineCore

@Suite struct FramingTests {
    @Test func roundTripAcrossChunks() throws {
        let a = Data(#"{"v":1,"type":"hello"}"#.utf8)
        let b = Data(#"{"v":1,"type":"gone","tabId":3}"#.utf8)
        let stream = Framing.encode(a) + Framing.encode(b)
        var dec = Framing.Decoder()
        var out: [Data] = []
        for byte in stream { // worst case: one byte at a time
            dec.append(Data([byte]))
            while let f = try dec.next() { out.append(f) }
        }
        #expect(out == [a, b])
    }

    @Test func littleEndianHeader() {
        let f = Framing.encode(Data(repeating: 0x41, count: 258))
        #expect(Array(f.prefix(4)) == [2, 1, 0, 0])
    }

    @Test func rejectsOversizedFrame() {
        var dec = Framing.Decoder(maxFrame: 10)
        dec.append(Framing.encode(Data(repeating: 0, count: 11)))
        #expect(throws: Framing.DecodeError.frameTooLarge(11)) { try dec.next() }
    }
}

@Suite struct MessageTests {
    @Test func parsesTrack() throws {
        let json = #"{"v":1,"type":"track","tabId":7,"seq":2,"site":"ytm","videoId":"abc","title":"T","artist":"A","duration":180.5,"artwork":[{"url":"https://lh3.googleusercontent.com/x=w1200-h1200","w":1200,"h":1200}],"isAd":false}"#
        guard case let .track(tab, seq, info) = try Incoming.parse(Data(json.utf8)) else { Issue.record(); return }
        #expect(tab == 7 && seq == 2)
        #expect(info.artwork.first?.w == 1200)
        #expect(info.duration == 180.5)
    }

    @Test func unknownTypeIsTolerated() throws {
        #expect(try Incoming.parse(Data(#"{"v":1,"type":"frame","tabId":1}"#.utf8)) == .unknown("frame"))
    }

    @Test func rejectsFutureVersion() {
        #expect(throws: (any Error).self) { try Incoming.parse(Data(#"{"v":2,"type":"hello"}"#.utf8)) }
    }

    @Test func outgoingCmdJSON() throws {
        let obj = try JSONSerialization.jsonObject(with: Outgoing.cmd(tab: 4, action: "seek", t: 12).json()) as! [String: Any]
        #expect(obj["type"] as? String == "cmd")
        #expect(obj["tabId"] as? Int == 4)
        #expect(obj["t"] as? Double == 12)
        #expect(obj["v"] as? Int == 1)
    }
}

@Suite struct TimelineTests {
    @Test func clockInterpolates() {
        let c = PlaybackClock(t: 10, rate: 1.5, paused: false, buffering: false, anchor: 100, duration: 12)
        #expect(c.position(at: 101) == 11.5)
        #expect(c.position(at: 200) == 12) // clamped to duration
        #expect(c.wallTime(forMedia: 11.5) == 101)
        #expect(c.wallTime(forMedia: 12.5) == nil) // beyond duration: never schedule
        let p = PlaybackClock(t: 10, rate: 1, paused: true, buffering: false, anchor: 100)
        #expect(p.position(at: 150) == 10)
        #expect(p.wallTime(forMedia: 11) == nil)
    }

    @Test func captionsWithEndTimes() {
        let tl = CueTimeline(cues: [Cue(s: 5, e: 7, text: "b"), Cue(s: 1, e: 3, text: "a")], synced: true)
        #expect(tl.activeIndex(at: 0.5) == nil)
        #expect(tl.activeIndex(at: 1) == 0)
        #expect(tl.activeIndex(at: 3.5) == nil) // gap
        #expect(tl.activeIndex(at: 6) == 1)
        #expect(tl.nextBoundary(after: 0) == 1)
        #expect(tl.nextBoundary(after: 2) == 3)
        #expect(tl.nextBoundary(after: 4) == 5)
        #expect(tl.nextBoundary(after: 8) == nil)
    }

    @Test func upcomingLinePreview() {
        let tl = CueTimeline(cues: [Cue(s: 1, e: 3, text: "a"), Cue(s: 5, e: 7, text: "b")], synced: true)
        #expect(tl.upcomingIndex(at: 0) == 0)   // before the first line
        #expect(tl.upcomingIndex(at: 2) == 1)   // during a
        #expect(tl.upcomingIndex(at: 4) == 1)   // in the gap
        #expect(tl.upcomingIndex(at: 6) == nil) // last line
        #expect(CueTimeline(cues: tl.cues, synced: false).upcomingIndex(at: 0) == nil)
    }

    @Test func lyricsWithoutEndStayUntilNext() {
        let tl = CueTimeline(cues: [Cue(s: 1, text: "a"), Cue(s: 4, text: "b")], synced: true)
        #expect(tl.activeIndex(at: 3.9) == 0)
        #expect(tl.activeIndex(at: 100) == 1)
        #expect(tl.nextBoundary(after: 2) == 4)
    }

    @Test func unsyncedNeverActive() {
        let tl = CueTimeline(cues: [Cue(s: 0, text: "a")], synced: false)
        #expect(tl.activeIndex(at: 1) == nil)
        #expect(tl.nextBoundary(after: 0) == nil)
    }
}

@Suite struct SessionStoreTests {
    func track(_ id: String) -> TrackInfo {
        TrackInfo(site: "yt", videoId: id, title: id, artist: "x", album: nil, duration: 100, artwork: [], isAd: false)
    }
    func clock(_ id: String, paused: Bool) -> ClockInfo {
        ClockInfo(videoId: id, t: 1, rate: 1, paused: paused, buffering: false)
    }

    @Test func dropsStaleSeq() {
        var s = SessionStore()
        s.apply(.track(tab: 1, seq: 5, track("a")), conn: 1, now: 0)
        let changed = s.apply(.track(tab: 1, seq: 4, track("b")), conn: 1, now: 1)
        #expect(!changed)
        #expect(s.active?.track?.videoId == "a")
        // After hello, seq restarts.
        s.apply(.hello(ext: nil), conn: 1, now: 2)
        let restarted = s.apply(.track(tab: 1, seq: 1, track("c")), conn: 1, now: 3)
        #expect(restarted)
    }

    @Test func followsMostRecentlyStartedTab() {
        var s = SessionStore()
        s.apply(.track(tab: 1, seq: 1, track("a")), conn: 1, now: 0)
        s.apply(.clock(tab: 1, seq: 2, clock("a", paused: false)), conn: 1, now: 1)
        s.apply(.track(tab: 2, seq: 3, track("b")), conn: 1, now: 2)
        s.apply(.clock(tab: 2, seq: 4, clock("b", paused: false)), conn: 1, now: 3)
        #expect(s.activeKey == TabKey(conn: 1, tab: 2))
        // Periodic tick from tab 1 must not steal focus.
        s.apply(.clock(tab: 1, seq: 5, clock("a", paused: false)), conn: 1, now: 4)
        #expect(s.activeKey == TabKey(conn: 1, tab: 2))
        // Pausing tab 2 hands focus back to the still-playing tab 1.
        s.apply(.clock(tab: 2, seq: 6, clock("b", paused: true)), conn: 1, now: 5)
        #expect(s.activeKey == TabKey(conn: 1, tab: 1))
        s.pinned = TabKey(conn: 1, tab: 2)
        #expect(s.activeKey == TabKey(conn: 1, tab: 2))
    }

    @Test func newVideoClearsCues() {
        var s = SessionStore()
        s.apply(.track(tab: 1, seq: 1, track("a")), conn: 1, now: 0)
        s.apply(.cues(tab: 1, seq: 2, CueSet(videoId: "a", source: "yt-captions", lang: "en", kind: "manual", synced: true,
                                              cues: [Cue(s: 0, e: 1, text: "hi")])), conn: 1, now: 0)
        #expect(s.active?.timeline.cues.count == 1)
        s.apply(.track(tab: 1, seq: 3, track("b")), conn: 1, now: 1)
        #expect(s.active?.timeline.cues.isEmpty == true)
        #expect(s.active?.cueSet == nil)
    }

    @Test func newVideoDropsStaleClockAndForeignMessages() {
        var s = SessionStore()
        s.apply(.track(tab: 1, seq: 1, track("a")), conn: 1, now: 0)
        s.apply(.clock(tab: 1, seq: 2, ClockInfo(videoId: "a", t: 40, rate: 1, paused: false, buffering: false)), conn: 1, now: 0)
        s.apply(.track(tab: 1, seq: 3, track("b")), conn: 1, now: 1)
        #expect(s.active?.clock == nil)
        #expect(s.active?.isPlaying == false)
        // Late messages for the previous video are ignored even with a newer seq.
        s.apply(.liveCaption(tab: 1, seq: 4, LiveCaption(videoId: "a", text: "STALE A")), conn: 1, now: 2)
        s.apply(.clock(tab: 1, seq: 5, ClockInfo(videoId: "a", t: 41, rate: 1, paused: false, buffering: false)), conn: 1, now: 2)
        #expect(s.active?.liveCaption == nil)
        #expect(s.active?.clock == nil)
        s.apply(.clock(tab: 1, seq: 6, ClockInfo(videoId: "b", t: 0, rate: 1, paused: false, buffering: false)), conn: 1, now: 3)
        #expect(s.active?.clock?.t == 0)
    }

    @Test func disconnectRemovesTabs() {
        var s = SessionStore()
        s.apply(.track(tab: 1, seq: 1, track("a")), conn: 1, now: 0)
        s.apply(.track(tab: 1, seq: 1, track("b")), conn: 2, now: 0)
        s.removeConnection(1)
        #expect(s.tabs.count == 1)
        #expect(s.active?.track?.videoId == "b")
    }
}

@Suite struct PathsTests {
    @Test func storeExtensionIDValidation() {
        #expect(SublinePaths.validExtensionID("npkfiaebcfackgbinodgjobdlmeceaij") == "npkfiaebcfackgbinodgjobdlmeceaij")
        #expect(SublinePaths.validExtensionID("") == nil)
        #expect(SublinePaths.validExtensionID(nil) == nil)
        #expect(SublinePaths.validExtensionID("npkfiaebcfackgbinodgjobdlmeceaiz") == nil) // z is outside a–p
        #expect(SublinePaths.validExtensionID("npkfiaebcfackgbinodgjobdlmecea") == nil)   // too short
        #expect(SublinePaths.allowedExtensionIDs == [SublinePaths.extensionID]) // no store ID in the test bundle
    }
}

@Suite struct CaptionTrackTests {
    let tracks = [CaptionTrack(id: "en", lang: "en", name: "English"),
                  CaptionTrack(id: "en:asr", lang: "en", name: "English (auto-generated)", kind: "asr"),
                  CaptionTrack(id: "ko:asr", lang: "ko", name: "Korean (auto-generated)", kind: "asr"),
                  CaptionTrack(id: "pt-BR", lang: "pt-BR", name: "Portuguese (Brazil)")]

    @Test func bestTrackForPreference() {
        #expect(CaptionTrack.best(for: "en:asr", in: tracks)?.id == "en:asr")   // exact
        #expect(CaptionTrack.best(for: "ko", in: tracks)?.id == "ko:asr")       // only auto exists
        #expect(CaptionTrack.best(for: "en-GB", in: tracks)?.id == "en")        // base language, manual first
        #expect(CaptionTrack.best(for: "pt", in: tracks)?.id == "pt-BR")
        #expect(CaptionTrack.best(for: "ja", in: tracks) == nil)
        #expect(CaptionTrack.best(for: nil, in: tracks) == nil)
    }

    @Test func parseAndStoreTrackList() throws {
        let json = #"{"v":1,"type":"captionTracks","tabId":3,"seq":5,"videoId":"abc","tracks":[{"id":"en","lang":"en","name":"English"},{"id":"ko:asr","lang":"ko","name":"Korean","kind":"asr"}]}"#
        let msg = try Incoming.parse(Data(json.utf8))
        guard case let .captionTracks(tab, _, list) = msg else { Issue.record("wrong case"); return }
        #expect(tab == 3 && list.tracks.count == 2 && list.tracks[1].isAuto)

        var store = SessionStore()
        let track = TrackInfo(site: "yt", videoId: "abc", title: "t", artist: "a", album: nil, duration: 100, artwork: [], isAd: false)
        store.apply(.track(tab: 3, seq: 1, track), conn: 1, now: 0)
        store.apply(msg, conn: 1, now: 0)
        let key = TabKey(conn: 1, tab: 3)
        #expect(store.tabs[key]?.captionTracksKnown == true)
        #expect(store.tabs[key]?.captionTracks.map(\.id) == ["en", "ko:asr"])
        // A different video clears the list.
        var other = track; other.videoId = "xyz"
        store.apply(.track(tab: 3, seq: 6, other), conn: 1, now: 0)
        #expect(store.tabs[key]?.captionTracks.isEmpty == true)
        #expect(store.tabs[key]?.captionTracksKnown == false)
    }

    @Test func cueSetTrackIDAndSelectJSON() throws {
        let asr = CueSet(videoId: "v", source: "yt-captions", lang: "en", kind: "asr", synced: true, cues: [])
        let lyrics = CueSet(videoId: "v", source: "lrclib", lang: nil, kind: "lyrics", synced: true, cues: [])
        #expect(asr.trackID == "en:asr")
        #expect(lyrics.trackID == nil)
        let obj = try JSONSerialization.jsonObject(with: Outgoing.selectCaptions(tab: 4, trackID: "ko").json()) as? [String: Any]
        #expect(obj?["type"] as? String == "selectCaptions")
        #expect(obj?["trackId"] as? String == "ko")
        #expect(obj?["tabId"] as? Int == 4)
    }
}

@Suite struct SecondaryCaptionTests {
    @Test func secondarySlotIsStoredApartAndClearedByNewVideo() {
        var store = SessionStore()
        let track = TrackInfo(site: "yt", videoId: "abc", title: "t", artist: "a", album: nil, duration: 100, artwork: [], isAd: false)
        store.apply(.hello(ext: "0.2.0"), conn: 1, now: 0)
        store.apply(.track(tab: 3, seq: 1, track), conn: 1, now: 0)
        store.apply(.cues(tab: 3, seq: 2, CueSet(videoId: "abc", source: "yt-captions", lang: "en", kind: "manual", synced: true,
                                                 cues: [Cue(s: 1, e: 2, text: "Hello")])), conn: 1, now: 0)
        store.apply(.cues(tab: 3, seq: 3, CueSet(videoId: "abc", source: "yt-captions", lang: "ko", kind: "manual", synced: true,
                                                 cues: [Cue(s: 1, e: 2, text: "안녕")], slot: 2)), conn: 1, now: 0)
        let k = TabKey(conn: 1, tab: 3)
        #expect(store.tabs[k]?.cueSet?.lang == "en")
        #expect(store.tabs[k]?.secondaryCueSet?.lang == "ko")
        #expect(store.tabs[k]?.secondaryTimeline.activeIndex(at: 1.5) == 0)
        #expect(store.extensionVersions[1] == "0.2.0")
        // Empty secondary set turns it off.
        store.apply(.cues(tab: 3, seq: 4, CueSet(videoId: "abc", source: "yt-captions", lang: "", kind: "manual", synced: true,
                                                 cues: [], slot: 2)), conn: 1, now: 0)
        #expect(store.tabs[k]?.secondaryCueSet == nil)
        #expect(store.tabs[k]?.cueSet?.lang == "en")
        var other = track; other.videoId = "xyz"
        store.apply(.cues(tab: 3, seq: 5, CueSet(videoId: "abc", source: "yt-captions", lang: "ko", kind: "manual", synced: true,
                                                 cues: [Cue(s: 1, text: "x")], slot: 2)), conn: 1, now: 0)
        store.apply(.track(tab: 3, seq: 6, other), conn: 1, now: 0)
        #expect(store.tabs[k]?.secondaryCueSet == nil)
        store.removeConnection(1)
        #expect(store.extensionVersions[1] == nil)
    }

    @Test func selectSecondaryJSONCarriesSlot() throws {
        let obj = try JSONSerialization.jsonObject(with: Outgoing.selectCaptions(tab: 4, trackID: "", slot: 2).json()) as? [String: Any]
        #expect(obj?["slot"] as? Int == 2)
        #expect(obj?["trackId"] as? String == "")
    }
}

@Suite struct TranslationTests {
    let tracks = [CaptionTrack(id: "en", lang: "en", name: "English"),
                  CaptionTrack(id: "ko:asr", lang: "ko", name: "Korean (auto-generated)", kind: "asr"),
                  CaptionTrack(id: "x-ko", lang: "ko", name: "Korean", kind: "translation"),
                  CaptionTrack(id: "x-ja", lang: "ja", name: "Japanese", kind: "translation")]

    @Test func translationsOnlyByExactIdAndNativeWins() {
        #expect(CaptionTrack.best(for: "ko", in: tracks)?.id == "ko:asr")   // native auto beats translation
        #expect(CaptionTrack.best(for: "x-ja", in: tracks)?.id == "x-ja")   // exact translation
        #expect(CaptionTrack.best(for: "x-ko", in: tracks)?.id == "x-ko")
        #expect(CaptionTrack.best(for: "x-en", in: tracks)?.id == "en")     // native track satisfies a wanted translation
        #expect(CaptionTrack.best(for: "ja", in: tracks) == nil)            // no native Japanese: not silently translated
    }

    @Test func explicitTrackIdWinsForCueSets() throws {
        let json = #"{"v":1,"type":"cues","tabId":1,"seq":2,"videoId":"v","source":"yt-captions","lang":"ko","kind":"manual","synced":true,"slot":2,"trackId":"x-ko","cues":[{"s":1,"text":"안녕"}]}"#
        guard case let .cues(_, _, set) = try Incoming.parse(Data(json.utf8)) else { Issue.record("wrong case"); return }
        #expect(set.trackID == "x-ko" && set.isSecondary)
        let list = #"{"v":1,"type":"captionTracks","tabId":1,"videoId":"v","tracks":[],"translations":[{"id":"x-ko","lang":"ko","name":"Korean","kind":"translation"}]}"#
        guard case let .captionTracks(_, _, l) = try Incoming.parse(Data(list.utf8)) else { Issue.record("wrong case"); return }
        #expect(l.translations?.first?.isTranslation == true)
    }
}

@Suite struct LockTests {
    @Test func lockReportsContentionAndFilesystemFailureDifferently() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("np-lock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("app.lock").path
        // Held by another descriptor → contention.
        let other = open(path, O_RDWR | O_CREAT, 0o600); defer { close(other) }
        #expect(flock(other, LOCK_EX | LOCK_NB) == 0)
        #expect(SublinePaths.acquireInstanceLock(at: path) == .heldByAnotherInstance)
        // Unreadable lock file → a real failure with the OS reason.
        let blocked = dir.appendingPathComponent("blocked.lock").path
        FileManager.default.createFile(atPath: blocked, contents: nil, attributes: [.posixPermissions: 0])
        if case let .failed(reason) = SublinePaths.acquireInstanceLock(at: blocked) {
            #expect(reason.contains("Permission denied"))
        } else { Issue.record("expected failure") }
    }
}

@Suite struct LyricsTests {
    @Test func lrcMultipleTimestampsFractionsMetadataCRLFAndFinalDuration() {
        let cues = Lyrics.parseLRC("[ar:Artist]\r\n[00:01.25][00:03.500]Hi\r\n[00:05]Bye", duration: 8)
        #expect(cues == [Cue(s: 1.25, e: 3.5, text: "Hi"), Cue(s: 3.5, e: 5, text: "Hi"), Cue(s: 5, e: 8, text: "Bye")])
    }

    @Test func lrcOffsetClampsAndIgnoresMalformed() {
        let cues = Lyrics.parseLRC("[offset:+500]\n[00:00.20]First\n[00:70]bad\n[00:02:5]Second", duration: 5)
        #expect(cues == [Cue(s: 0, e: 2, text: "First"), Cue(s: 2, e: 5, text: "Second")])
        #expect(Lyrics.parseLRC("[offset:-250]\n[00:01.00]Late", duration: nil).first?.s == 1.25)
        #expect(Lyrics.parseLRC("plain lyrics without timestamps", duration: nil).isEmpty)
    }

    @Test func queryCleansLocalizedAndDecorativeSuffixes() {
        let q = LyricsQuery(title: "Song (Official Audio)", artist: "The Band(더 밴드) - Topic", album: nil, duration: 110)
        #expect(q.attempts.count == 2)
        #expect(q.attempts[1].title == "Song" && q.attempts[1].artist == "The Band")
        #expect(q.cacheKey == LyricsQuery(title: "song (official audio)", artist: "THE BAND(더 밴드) - topic", album: "x", duration: 110.4).cacheKey)
    }

    @Test func candidatesNeedIdentityAndSyncedTextAndRankExactTitleFirst() {
        func r(_ id: Int, _ t: String, _ a: String, _ d: Double, synced: String? = "[00:01]x", instrumental: Bool? = nil) -> LRCLIBRecord {
            LRCLIBRecord(id: id, trackName: t, artistName: a, albumName: nil, duration: d, instrumental: instrumental, syncedLyrics: synced)
        }
        let q = LyricsQuery(title: "Song (Official Video)", artist: "The Band", album: nil, duration: 180)
        let ranked = Lyrics.rankCandidates([
            r(1, "Song (Live)", "Band", 186),
            r(2, "Song", "The Band", 181, instrumental: true),
            r(3, "Song", "Other", 182),
            r(4, "Song", "The Band", 181),
            r(5, "Song", "The Band", 183, synced: nil),
            r(6, "Completely Different", "The Band", 180),
        ], for: q)
        #expect(ranked.map(\.id) == [4, 1])
        // Auto pick: within ±3 s only, so the live version is offered but not shown by itself.
        #expect(Lyrics.autoPick(exact: nil, ranked: ranked, for: q)?.id == 4)
        #expect(Lyrics.autoPick(exact: nil, ranked: [ranked[1]], for: q) == nil)
    }

    @Test func appFoundLyricsSurvivePagePlaceholders() throws {
        var store = SessionStore()
        let track = TrackInfo(site: "ytm", videoId: "v", title: "T", artist: "A", album: nil, duration: 100, artwork: [], isAd: nil)
        store.apply(.track(tab: 1, seq: 1, track), conn: 1, now: 0)
        let lrc = CueSet(videoId: "v", source: "lrclib", lang: nil, kind: "lyrics", synced: true, cues: [Cue(s: 1, text: "hello")])
        store.apply(.cues(tab: 1, seq: nil, lrc), conn: 1, now: 1)
        let placeholder = CueSet(videoId: "v", source: "ytm-lyrics", lang: nil, kind: "lyrics", synced: true, cues: [])
        store.apply(.cues(tab: 1, seq: 2, placeholder), conn: 1, now: 2)
        #expect(store.active?.cueSet?.source == "lrclib")
        // The app itself can clear them ("No Lyrics").
        store.apply(.cues(tab: 1, seq: nil, CueSet(videoId: "v", source: "lrclib", lang: nil, kind: "lyrics", synced: true, cues: [])), conn: 1, now: 3)
        #expect(store.active?.cueSet?.cues.isEmpty == true)
    }
}

@Suite struct RomanizerTests {
    @Test func koreanRevisedRomanizationWithLinking() {
        #expect(Romanizer.romanize("사랑해") == "saranghae")
        #expect(Romanizer.romanize("한국어") == "hangugeo")
        #expect(Romanizer.romanize("좋아요") == "joayo")
        #expect(Romanizer.romanize("싫어 않아") == "sireo ana")
        #expect(Romanizer.romanize("별로, 신라!") == "byeollo, silla!")
        #expect(Romanizer.romanize("밤하늘의 별") == "bamhaneurui byeol", "got \(Romanizer.romanize("밤하늘의 별") ?? "nil")")
    }

    @Test func detectsScriptsAndSkipsLatin() {
        #expect(Romanizer.romanize("Hello world") == nil)
        #expect(Romanizer.script(of: "君の名は") == .japanese)
        // Small っ cut off at a token end doubles the next consonant (not "uta~tsu te").
        #expect(Romanizer.romanize("歌って") == "utatte")
        #expect(Romanizer.romanize("夜明けまで 歌っていよう") == "yoake made utatte iyou")
        #expect(Romanizer.romanize("行った") == "itta")
        #expect(Romanizer.romanize("きっと") == "kitto")
        #expect(Romanizer.script(of: "你好") == .chinese)
        #expect(Romanizer.script(of: "東京", japanese: true) == .japanese)
    }

    @Test func japaneseAndChineseBecomeLatin() throws {
        let ja = try #require(Romanizer.romanize("ありがとう"))
        #expect(ja.lowercased().hasPrefix("arigat"))
        let zh = try #require(Romanizer.romanize("你好"))
        #expect(zh.contains("nǐ") && zh.contains("hǎo"))
    }
}

@Suite struct DerivedSecondaryTests {
    @Test func pageClearDoesNotRemoveDerivedLineButAppClearDoes() {
        var store = SessionStore()
        store.apply(.track(tab: 1, seq: 1, TrackInfo(site: "yt", videoId: "v", title: "T", artist: "A", album: nil, duration: 9, artwork: [], isAd: nil)), conn: 1, now: 0)
        var derived = CueSet(videoId: "v", source: "romanized", lang: nil, kind: "manual", synced: true, cues: [Cue(s: 1, text: "saranghae")], slot: 2)
        derived.trackId = "@romaji"
        store.apply(.cues(tab: 1, seq: nil, derived), conn: 1, now: 1)
        store.apply(.cues(tab: 1, seq: 2, CueSet(videoId: "v", source: "yt-captions", lang: nil, kind: "manual", synced: true, cues: [], slot: 2)), conn: 1, now: 2)
        #expect(store.active?.secondaryCueSet?.trackID == "@romaji")
        store.apply(.cues(tab: 1, seq: nil, CueSet(videoId: "v", source: "derived", lang: nil, kind: "manual", synced: true, cues: [], slot: 2)), conn: 1, now: 3)
        #expect(store.active?.secondaryCueSet == nil)
    }
}

@Suite struct LyricsEstimateTests {
    let song = ["Verse one a", "Verse one b", "", "Chorus a", "Chorus b", "", "Verse two a", "Verse two b"]

    @Test func stanzasFollowBlankLinesAndSpanTheSong() throws {
        let e = try #require(LyricsEstimate(lines: song, duration: 200))
        #expect(e.stanzas == [0..<2, 3..<5, 6..<8])
        #expect(e.starts.first == 16) // 8% intro
        #expect(e.stanza(at: 5) == nil)
        #expect(e.stanza(at: 20) == 0)
        #expect(e.stanza(at: 100) == 1)
        #expect(e.stanza(at: 199) == 2)
        #expect(e.nextBoundary(after: 20) == e.starts[1])
        #expect(e.nextBoundary(after: 199) == nil)
    }

    @Test func longerLinesTakeLonger() throws {
        let e = try #require(LyricsEstimate(lines: ["short", "", String(repeating: "long words here ", count: 4), "", "short"], duration: 100))
        #expect(e.starts[2] - e.starts[1] > e.starts[1] - e.starts[0])
    }

    @Test func aLongBlockIsCutIntoChunksWithoutAOneLineTail() throws {
        let e = try #require(LyricsEstimate(lines: (1...9).map { "line \($0)" }, duration: 180))
        #expect(e.stanzas == [0..<4, 4..<9])
    }

    @Test func nothingToPlace() {
        #expect(LyricsEstimate(lines: song, duration: 10) == nil)
        #expect(LyricsEstimate(lines: ["one", "two"], duration: 200) == nil)
    }
}
