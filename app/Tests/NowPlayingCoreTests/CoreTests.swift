import Testing
import Foundation
@testable import NowPlayingCore

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
