/**
 * Clammy — content script injected into horizonxi.com pages.
 * Wraps window.fetch and XMLHttpRequest to intercept Authorization headers
 * going to api.horizonxi.com, then forwards the token to the background SW.
 * This is more reliable than webRequest.onBeforeSendHeaders for CORS requests.
 */

(function () {
  'use strict';

  const API_HOST = 'api.horizonxi.com';

  function isApiUrl(url) {
    try { return new URL(url).hostname === API_HOST; } catch { return false; }
  }

  function extractBearer(headers) {
    if (!headers) return null;
    let val = null;
    if (typeof headers.get === 'function') {
      val = headers.get('authorization') || headers.get('Authorization');
    } else if (typeof headers === 'object') {
      for (const k of Object.keys(headers)) {
        if (k.toLowerCase() === 'authorization') { val = headers[k]; break; }
      }
    }
    if (!val) return null;
    const m = val.match(/^Bearer\s+(.+)$/i);
    return m ? m[1].trim() : null;
  }

  function sendToken(token) {
    if (!token || token.length < 30) return;
    chrome.runtime.sendMessage({ type: 'CLAMMY_TOKEN', token });
  }

  // ── Wrap fetch ──────────────────────────────────────────────────────────────
  const _fetch = window.fetch.bind(window);
  window.fetch = function (input, init) {
    try {
      const url = typeof input === 'string' ? input
        : input instanceof Request ? input.url
        : String(input);
      if (isApiUrl(url)) {
        const token = extractBearer((init && init.headers) ||
                                    (input instanceof Request ? input.headers : null));
        if (token) sendToken(token);
      }
    } catch { /* never block the real request */ }
    return _fetch(input, init);
  };

  // ── Wrap XMLHttpRequest ─────────────────────────────────────────────────────
  const _open = XMLHttpRequest.prototype.open;
  const _setRequestHeader = XMLHttpRequest.prototype.setRequestHeader;

  XMLHttpRequest.prototype.open = function (method, url) {
    this._clammyUrl = url;
    return _open.apply(this, arguments);
  };

  XMLHttpRequest.prototype.setRequestHeader = function (name, value) {
    if (this._clammyUrl && isApiUrl(this._clammyUrl) &&
        name.toLowerCase() === 'authorization') {
      const m = String(value).match(/^Bearer\s+(.+)$/i);
      if (m) sendToken(m[1].trim());
    }
    return _setRequestHeader.apply(this, arguments);
  };

})();
