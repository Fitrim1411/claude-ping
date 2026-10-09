// ==UserScript==
// @name         Claude Ping
// @namespace    claude-ping
// @version      1.0.0
// @description  Tells Hammerspoon when Claude finishes answering in a claude.ai tab you are not looking at.
// @match        https://claude.ai/*
// @grant        GM.xmlHttpRequest
// @grant        GM_xmlhttpRequest
// @connect      127.0.0.1
// @run-at       document-idle
// @noframes
// ==/UserScript==

(() => {
  'use strict';

  const PORT = 47823;
  const DONE_DELAY = 1500;  // wait so short pauses between Claude's steps don't count as "done"
  const MARK = '✅ ';

  // Signs that Claude is answering. Several options, in case the claude.ai UI changes.
  const BUSY_SELECTORS = [
    '[data-is-streaming="true"]',
    'button[aria-label="Stop response"]',
    'button[aria-label="Stop Response"]',
    'button[aria-label="Stop generating"]',
    'button[aria-label="Hentikan respons"]',
  ];

  const ua = navigator.userAgent;
  const browser = /Chrome\//.test(ua) ? 'chrome' : (/Safari\//.test(ua) ? 'safari' : 'other');

  const gmRequest =
    (typeof GM !== 'undefined' && GM && typeof GM.xmlHttpRequest === 'function') ? GM.xmlHttpRequest.bind(GM)
    : (typeof GM_xmlhttpRequest === 'function') ? GM_xmlhttpRequest
    : null;

  const cleanTitle = () => document.title.replace(MARK, '').trim();
  const pageUrl = () => location.origin + location.pathname;

  function send(event) {
    if (!gmRequest) return;
    try {
      const r = gmRequest({
        method: 'POST',
        url: `http://127.0.0.1:${PORT}/browser`,
        headers: { 'Content-Type': 'application/json', 'X-Claude-Ping': '1' },
        data: JSON.stringify({ event, url: pageUrl(), title: cleanTitle(), browser }),
        timeout: 3000,
        onerror() {}, ontimeout() {},
      });
      if (r && typeof r.catch === 'function') r.catch(() => {});
    } catch (_) { /* Hammerspoon not running → stay quiet */ }
  }

  function isBusy() {
    return BUSY_SELECTORS.some((sel) => {
      try { return !!document.querySelector(sel); } catch (_) { return false; }
    });
  }

  const looking = () => document.visibilityState === 'visible' && document.hasFocus();

  let busy = false;
  let doneTimer = null;
  let scheduled = false;
  let unseen = false;
  let unseenUrl = '';

  function setMark(on) {
    const t = cleanTitle();
    const want = on ? MARK + t : t;
    if (document.title !== want) document.title = want;
  }

  function onDone() {
    if (looking()) return;          // you are looking at this tab → no marker needed
    unseen = true;
    unseenUrl = pageUrl();
    setMark(true);
    send('done');
  }

  function onSeen() {
    if (!unseen) return;
    unseen = false;
    setMark(false);
    send('seen');
  }

  function check() {
    scheduled = false;
    if (unseen && pageUrl() !== unseenUrl) onSeen();       // switched conversation in this tab
    if (unseen && !document.title.startsWith(MARK)) setMark(true);

    if (isBusy()) {
      busy = true;
      if (doneTimer) { clearTimeout(doneTimer); doneTimer = null; }
    } else if (busy && !doneTimer) {
      doneTimer = setTimeout(() => {
        doneTimer = null;
        if (isBusy()) return;
        busy = false;
        onDone();
      }, DONE_DELAY);
    }
  }

  // At most one light check per 400 ms, no matter how many page changes happen.
  function schedule() {
    if (scheduled) return;
    scheduled = true;
    setTimeout(check, 400);
  }

  new MutationObserver(schedule).observe(document.documentElement, {
    childList: true, subtree: true, attributes: true,
    attributeFilter: ['data-is-streaming', 'aria-label'],
  });
  document.addEventListener('visibilitychange', () => { if (looking()) onSeen(); });
  window.addEventListener('focus', () => { if (looking()) onSeen(); });
  schedule();
})();
