/* Shared classic script: usable in MAIN, isolated, service worker and Node tests. */
(() => {
  'use strict';
  const clean = value => String(value ?? '').replace(/\u200b/g, '').trim();
  function normalizeCues(input, asr = false) {
    const cues = (Array.isArray(input) ? input : []).filter(c => c && typeof c === 'object' && Number.isFinite(c.s) && c.s >= 0 && clean(c.text))
      .map(c => ({s: c.s, ...(Number.isFinite(c.e) && c.e > c.s ? {e: c.e} : {}), text: clean(c.text)}))
      .sort((a, b) => a.s - b.s);
    const out = [];
    for (const cue of cues) {
      const prev = out.at(-1);
      if (prev && prev.text === cue.text && (prev.e ?? prev.s) >= cue.s - 0.05) {
        if (cue.e) prev.e = Math.max(prev.e ?? prev.s, cue.e);
        continue;
      }
      // ASR sends cumulative rolling windows. Keep a completed line once,
      // and remove the repeated suffix/prefix from the following window.
      if (asr && prev && (prev.e ?? prev.s) >= cue.s - 0.1) {
        if (cue.text.startsWith(prev.text)) {
          prev.text = cue.text;
          if (cue.e) prev.e = Math.max(prev.e ?? prev.s, cue.e);
          continue;
        }
        const a = prev.text.split(/\s+/), b = cue.text.split(/\s+/);
        for (let n = Math.min(a.length, b.length); n > 0; n--) {
          if (a.slice(-n).join(' ') === b.slice(0, n).join(' ')) {
            cue.text = b.slice(n).join(' ');
            break;
          }
        }
        if (!cue.text) continue;
      }
      if (prev && prev.e > cue.s) prev.e = cue.s;
      out.push(cue);
    }
    return out.filter(c => c.e === undefined || c.e > c.s).slice(0, 20000);
  }
  // Auto-generated (ASR) json3 carries one timestamp per word, laid out by YouTube in rolling
  // windows that cut sentences anywhere. Rebuild lines from the word stream instead: break at
  // sentence punctuation, at pauses, or when a line gets long.
  const CJK = /[\u3040-\u30ff\u3400-\u9fff\uac00-\ud7af]/;
  function groupASRWords(events) {
    const words = [], seen = new Set();
    for (const event of events) {
      if (!event || !Array.isArray(event.segs) || !Number.isFinite(event.tStartMs)) continue;
      const end = Number.isFinite(event.dDurationMs) ? (event.tStartMs + event.dDurationMs) / 1000 : undefined;
      let t = event.tStartMs / 1000;
      for (const seg of event.segs) {
        const text = typeof seg?.utf8 === 'string' ? seg.utf8.replace(/\u200b/g, '') : '';
        // A segment without its own offset belongs to the previous word's time (never back to the event start).
        if (seg?.tOffsetMs !== undefined && Number.isFinite(Number(seg.tOffsetMs))) t = (event.tStartMs + Number(seg.tOffsetMs)) / 1000;
        if (!text.trim()) continue;                                   // blank/newline appends only
        const key = `${t.toFixed(3)}|${text.trim()}`;
        if (seen.has(key)) continue;                                  // the same timed word repeated by an overlapping window
        seen.add(key);
        words.push({t, text, end});
      }
    }
    words.sort((a, b) => a.t - b.t);
    const lines = [];
    let cur = null;
    const flush = () => { if (cur && cur.text.trim()) lines.push(cur); cur = null; };
    for (const w of words) {
      if (cur) {                                                    // a pause ends the line,
        const t = cur.text.trim(), short = t.length < (CJK.test(t) ? 8 : 16); // unless it's still a fragment
        const gap = w.t - cur.last;
        if (gap > 4 || (gap > 1.2 && !short)) flush();
      }
      if (!cur) cur = {s: w.t, text: '', last: w.t, end: w.end};
      cur.text += w.text; cur.last = w.t; cur.end = w.end;
      const t = cur.text.trim(), max = CJK.test(t) ? 26 : 48;
      if (/[.?!。？！…]["'”’)\]]?$/.test(t) || t.length >= max) flush();
    }
    flush();
    // Start times must strictly advance (the app shows the last cue started); fold equal starts together.
    for (let i = lines.length - 1; i > 0; i--) {
      if (lines[i].s <= lines[i - 1].s + 0.05) {
        lines[i - 1].text += (CJK.test(lines[i].text.trim()[0] || '') ? '' : ' ') + lines[i].text.trim();
        lines[i - 1].last = Math.max(lines[i - 1].last, lines[i].last);
        lines[i - 1].end = lines[i].end ?? lines[i - 1].end;
        lines.splice(i, 1);
      }
    }
    return lines.map((l, i) => {
      const next = lines[i + 1]?.s ?? Infinity;
      const e = Math.min(next, Math.max(l.last + 0.9, l.s + 0.6), l.end ?? Infinity);
      return {s: l.s, ...(e > l.s ? {e} : {}), text: l.text.trim().replace(/\s+/g, ' ')};
    });
  }
  function parseJSON3(data, asr = false) {
    if (typeof data === 'string') { try { data = JSON.parse(data); } catch { return []; } }
    const events = Array.isArray(data?.events) ? data.events : [];
    if (asr && events.some(e => Array.isArray(e?.segs) && e.segs.some(s => Number.isFinite(Number(s?.tOffsetMs)) && s?.tOffsetMs !== undefined))) {
      return normalizeCues(groupASRWords(events));
    }
    const rows = [];
    for (const event of Array.isArray(data?.events) ? data.events : []) {
      if (!event || typeof event !== 'object') continue;
      if (!Array.isArray(event.segs) || !Number.isFinite(event.tStartMs)) continue;
      const text = event.segs.map(s => typeof s?.utf8 === 'string' ? s.utf8 : '').join('');
      if (event.aAppend && rows.length) {
        const last = rows.at(-1);
        last.text += text;
        if (event.dDurationMs > 0) last.e = (event.tStartMs + event.dDurationMs) / 1000;
      } else rows.push({s: event.tStartMs / 1000,
        ...(event.dDurationMs > 0 ? {e: (event.tStartMs + event.dDurationMs) / 1000} : {}), text});
    }
    return normalizeCues(rows, asr);
  }
  globalThis.NPParsers = Object.freeze({normalizeCues, parseJSON3});
})();
