#!/usr/bin/env python3
"""Feeds synthetic playback to NowPlaying.app through np-host (as the extension would).

usage: feed.py MODE SECONDS [--host PATH]
modes:
  lyrics   200 synced lines, one every 3 s (lyric pace)
  fast     1500 auto-generated caption lines, one every 1.3 s (fast speech)
  nocues   playing, no text
  none     YouTube video that has no captions
  loading  captions offered but not loaded yet
  gap      instrumental gap before the first line (♪ + next line)
  dual     main + secondary caption tracks
  paused   lyric-pace track, paused
"""
import argparse, json, os, struct, subprocess, time

ap = argparse.ArgumentParser()
ap.add_argument("mode"); ap.add_argument("seconds", type=float)
ap.add_argument("--host", default=os.path.expanduser("~/Applications/NowPlaying.app/Contents/Helpers/np-host"))
a = ap.parse_args()
p = subprocess.Popen([a.host], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL)
seq = 0
def send(o):
    global seq; seq += 1; o.update(v=1, tabId=9, seq=seq)
    b = json.dumps(o).encode(); p.stdin.write(struct.pack("<I", len(b)) + b); p.stdin.flush()

VID = "aqz-KE-bpKQ"  # Big Buck Bunny (CC-BY Blender Foundation)
send({"type": "track", "site": "yt" if a.mode != "lyrics" else "ytm", "videoId": VID,
      "title": "Big Buck Bunny 60fps 4K - Official Blender Foundation Short Film", "artist": "Blender", "duration": 3000,
      "artwork": [{"url": f"https://i.ytimg.com/vi/{VID}/hqdefault.jpg", "w": 480, "h": 360}], "isAd": False})
tracks = [{"id": "en", "lang": "en", "name": "English"}, {"id": "ko", "lang": "ko", "name": "Korean"}]
def cues(n, every, text, kind="manual", lang="en", slot=None, start=0.0, end=True):
    o = {"type": "cues", "videoId": VID, "source": "yt-captions", "lang": lang, "kind": kind, "synced": True,
         "cues": [{"s": start + i * every, **({"e": start + i * every + every * 0.92} if end else {}), "text": text(i)} for i in range(n)]}
    if slot: o["slot"] = slot
    send(o)
m = a.mode
if m == "lyrics": cues(200, 3.0, lambda i: f"Line number {i} of the lyric", end=False)
elif m == "fast": cues(1500, 1.3, lambda i: f"{i}번째 해설 자막입니다 일단 라인에 궁 쓰고 지어보나요", kind="asr", lang="ko")
elif m == "none": send({"type": "captionTracks", "videoId": VID, "tracks": []})
elif m == "loading": send({"type": "captionTracks", "videoId": VID, "tracks": tracks})
elif m == "gap":
    send({"type": "captionTracks", "videoId": VID, "tracks": tracks})
    cues(2, 4.0, lambda i: ["The forest wakes up slowly", "and so does he"][i], start=30)
elif m == "dual":
    send({"type": "captionTracks", "videoId": VID, "tracks": tracks})
    en = ["The forest wakes up slowly", "A rabbit stretches in the sun", "Butterflies drift past the meadow", "Something is about to happen"]
    ko = ["숲이 천천히 깨어나요", "토끼가 햇살 아래 기지개를 켜요", "나비들이 들판을 스쳐 날아가요", "무언가 일어나려 해요"]
    cues(4, 3.0, lambda i: en[i], start=4); cues(4, 3.0, lambda i: ko[i], lang="ko", slot=2, start=4)
elif m == "paused": cues(200, 3.0, lambda i: f"Line number {i} of the lyric", end=False)
t0 = time.time(); offset = 5.0 if m == "gap" else 0.0
while time.time() - t0 < a.seconds:
    send({"type": "clock", "videoId": VID, "t": offset + time.time() - t0, "rate": 1, "paused": m == "paused", "buffering": False})
    time.sleep(1)
