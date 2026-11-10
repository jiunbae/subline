(() => {
  'use strict';
  const text = selector => document.querySelector(selector)?.textContent?.trim() || '';
  const safeURL = value => { try { const u = new URL(value); return u.protocol === 'https:' ? u.href : ''; } catch { return ''; } };
  function artwork(raw, id, music) {
    const images = [];
    for (const item of raw ?? []) {
      const url = safeURL(item.url);
      if (!url) continue;
      if (music && new URL(url).hostname === 'lh3.googleusercontent.com') {
        images.push({url: url.replace(/=w\d+[^?]*/, '=w1200-h1200-l90-rj'), w: 1200, h: 1200});
      }
      images.push({url, w: Number(item.width || item.w) || 0, h: Number(item.height || item.h) || 0});
    }
    if (!music && /^[\w-]{11}$/.test(id)) {
      for (const [name, w, h] of [['maxresdefault',1280,720], ['sddefault',640,480], ['hqdefault',480,360]]) {
        images.push({url: `https://i.ytimg.com/vi/${id}/${name}.jpg`, w, h});
      }
    }
    return [...new Map(images.sort((a,b) => b.w * b.h - a.w * a.h).map(i => [i.url, i])).values()].slice(0, 12);
  }
  function readYT(main, video) {
    const id = new URL(location.href).searchParams.get('v') || '';
    if (!id || location.pathname !== '/watch') return null;
    const data = main?.videoId === id ? main.data : {};
    return {site: 'yt', videoId: id,
      title: data?.title || text('ytd-watch-metadata h1 yt-formatted-string') || text('h1.title'),
      artist: data?.artist || text('ytd-watch-metadata #owner #channel-name'),
      duration: Number.isFinite(video?.duration) ? video.duration : Number(data?.duration) || 0,
      artwork: artwork(data?.thumbnails, id, false),
      isAd: !!document.querySelector('#movie_player.ad-showing, #movie_player.ad-interrupting')};
  }
  function songLength() {
    const max = Number(document.querySelector('ytmusic-player-bar #progress-bar')?.getAttribute('aria-valuemax'));
    return Number.isFinite(max) && max > 0 ? max : 0;
  }
  function readYTM(main, video) {
    const id = new URL(location.href).searchParams.get('v') || main?.videoId || '';
    if (!id) return null;
    const bar = document.querySelector('ytmusic-player-bar');
    const byline = bar?.querySelector('.byline');
    const links = [...(byline?.querySelectorAll('a') || [])];
    const image = bar?.querySelector('img.image, .thumbnail-image-wrapper img, img');
    const data = main?.videoId === id ? main.data : {};
    const raw = [...(data?.thumbnails || [])];
    if (image?.src) raw.push({url: image.src, width: image.naturalWidth, height: image.naturalHeight});
    return {site: 'ytm', videoId: id,
      title: bar?.querySelector('.title')?.textContent?.trim() || data?.title || '',
      artist: links[0]?.textContent?.trim() || data?.artist || byline?.textContent?.split('•')[0]?.trim() || '',
      album: links.find(a => /browse\/MPRE/.test(a.href))?.textContent?.trim() || links[1]?.textContent?.trim() || '',
      // The song's own length (player data, else the progress bar), not the media element's: queued
      // songs can share one media stream whose duration spans several of them.
      duration: Number(data?.duration) || songLength() || (Number.isFinite(video?.duration) ? video.duration : 0),
      artwork: artwork(raw, id, true),
      isAd: !!document.querySelector('#movie_player.ad-showing, #movie_player.ad-interrupting')};
  }
  function skip(music, previous) {
    const selector = music ? (previous ? 'ytmusic-player-bar .previous-button' : 'ytmusic-player-bar .next-button') :
      (previous ? '.ytp-prev-button' : '.ytp-next-button');
    const button = document.querySelector(selector);
    if (button && !button.disabled && button.getAttribute('aria-disabled') !== 'true') button.click();
  }
  globalThis.NPAdapters = {readYT, readYTM, skip};
})();
