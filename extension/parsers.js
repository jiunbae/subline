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
  function parseJSON3(data, asr = false) {
    if (typeof data === 'string') { try { data = JSON.parse(data); } catch { return []; } }
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
  function parseLRC(text, duration) {
    if (typeof text !== 'string') return [];
    const offset = Number(text.match(/\[offset:([+-]?\d+)\]/i)?.[1] ?? 0) / 1000;
    const cues = [];
    for (const line of text.split(/\r?\n/)) {
      const tags = [...line.matchAll(/\[(\d+):(\d{2})(?:[.:](\d{1,3}))?\]/g)];
      const lyric = clean(line.replace(/\[[^\]]*\]/g, ''));
      for (const tag of tags) {
        if (Number(tag[2]) >= 60) continue;
        const fraction = tag[3] ? Number(tag[3]) / 10 ** tag[3].length : 0;
        cues.push({s: Math.max(0, Number(tag[1]) * 60 + Number(tag[2]) + fraction + offset), text: lyric});
      }
    }
    const result = normalizeCues(cues);
    result.forEach((cue, i) => {
      const end = result[i + 1]?.s ?? duration;
      if (Number.isFinite(end) && end > cue.s) cue.e = end;
    });
    return result;
  }
  function parseTimedLyrics(data) {
    const rows = [];
    let visited = 0;
    function walk(value, depth = 0) {
      if (!value || typeof value !== 'object' || depth > 25 || ++visited > 30000) return;
      if (Array.isArray(value.timedLyricsData)) {
        for (const line of value.timedLyricsData) {
          if (line.cueRange?.startTimeMilliseconds === undefined) continue;
          rows.push({s: Number(line.cueRange.startTimeMilliseconds) / 1000,
            e: Number(line.cueRange.endTimeMilliseconds) / 1000, text: line.lyricLine});
        }
        return;
      }
      for (const child of Object.values(value)) walk(child, depth + 1);
    }
    walk(data);
    return normalizeCues(rows);
  }
  globalThis.NPParsers = Object.freeze({normalizeCues, parseJSON3, parseLRC, parseTimedLyrics});
})();
