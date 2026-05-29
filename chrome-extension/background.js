/**
 * Clammy HorizonXI Token — background service worker
 *
 * Watches every request to api.horizonxi.com.
 * When it sees an Authorization: Bearer header, decodes the JWT expiry,
 * saves to chrome.storage.local (for the popup), and forwards to the
 * native messaging host which writes horizon_bearer.txt to disk.
 */

const HOST_NAME = 'com.clammyhorizon.tokenhost';

// ── JWT helpers ──────────────────────────────────────────────────────────────

function decodeJwtPayload(token) {
  try {
    const b64 = token.split('.')[1].replace(/-/g, '+').replace(/_/g, '/');
    return JSON.parse(atob(b64));
  } catch {
    return null;
  }
}

function jwtExpiresAt(token) {
  const p = decodeJwtPayload(token);
  return p && p.exp ? p.exp * 1000 : null;
}

function isTokenExpired(token) {
  const exp = jwtExpiresAt(token);
  return exp === null || exp < Date.now();
}

// ── Icon: draw coloured badge via OffscreenCanvas ────────────────────────────

function makeIconData(size, color) {
  const canvas = new OffscreenCanvas(size, size);
  const ctx = canvas.getContext('2d');

  // Background circle
  ctx.fillStyle = color;
  ctx.beginPath();
  ctx.arc(size / 2, size / 2, size / 2, 0, Math.PI * 2);
  ctx.fill();

  // "C" letter
  ctx.fillStyle = '#ffffff';
  ctx.font = `bold ${Math.round(size * 0.62)}px sans-serif`;
  ctx.textAlign = 'center';
  ctx.textBaseline = 'middle';
  ctx.fillText('C', size / 2 + size * 0.03, size / 2 + size * 0.04);

  return ctx.getImageData(0, 0, size, size);
}

function setIcon(state) {
  // green = token captured and valid
  // amber = no token or expired
  // red   = native host error
  const color = state === 'ok' ? '#22c55e' : state === 'error' ? '#ef4444' : '#f59e0b';
  try {
    chrome.action.setIcon({
      imageData: {
        16: makeIconData(16, color),
        48: makeIconData(48, color),
      },
    });
  } catch {
    /* OffscreenCanvas may not be available in older Chrome */
  }
}

// ── Receive token from content script ────────────────────────────────────────
// Content script wraps fetch/XHR in the page and messages us the token.
// This is more reliable than webRequest for CORS Authorization headers.
chrome.runtime.onMessage.addListener((msg, _sender, _sendResponse) => {
  if (!msg || msg.type !== 'CLAMMY_TOKEN' || !msg.token) return;
  const token = String(msg.token).trim();
  if (token === lastSentToken && !isTokenExpired(token)) return;
  lastSentToken = token;
  onTokenCaptured(token, 'content-script');
});

// ── Token capture ─────────────────────────────────────────────────────────────

let lastSentToken = null;

chrome.webRequest.onBeforeSendHeaders.addListener(
  (details) => {
    const headers = details.requestHeaders || [];
    for (const h of headers) {
      if (h.name.toLowerCase() !== 'authorization') continue;
      const val = (h.value || '').trim();
      const m = val.match(/^Bearer\s+(.+)$/i);
      if (!m) continue;
      const token = m[1].trim();
      if (token.length < 30) continue;
      // Skip if same token we already handled (debounce)
      if (token === lastSentToken && !isTokenExpired(token)) continue;
      lastSentToken = token;
      onTokenCaptured(token, details.url);
      break;
    }
  },
  { urls: ['*://api.horizonxi.com/*'] },
  ['requestHeaders', 'extraHeaders'],
);

async function onTokenCaptured(token, fromUrl) {
  const expiresAt = jwtExpiresAt(token);
  const payload = decodeJwtPayload(token);

  await chrome.storage.local.set({
    token,
    capturedAt: Date.now(),
    expiresAt,
    username: payload?.username || null,
    fromUrl: fromUrl || null,
    nativeStatus: 'pending',
    nativeError: null,
    savedPath: null,
  });

  setIcon('ok');
  sendToNativeHost(token);
}

// ── Native messaging ──────────────────────────────────────────────────────────

function sendToNativeHost(token) {
  let port;
  try {
    port = chrome.runtime.connectNative(HOST_NAME);
  } catch (e) {
    chrome.storage.local.set({ nativeStatus: 'error', nativeError: e.message });
    setIcon('error');
    return;
  }

  const timeout = setTimeout(() => {
    try { port.disconnect(); } catch { /* ignore */ }
    chrome.storage.local.set({ nativeStatus: 'error', nativeError: 'Native host timed out (5 s).' });
    setIcon('error');
  }, 5000);

  port.onMessage.addListener((response) => {
    clearTimeout(timeout);
    if (response && response.success) {
      chrome.storage.local.set({ nativeStatus: 'saved', savedPath: response.path });
    } else {
      chrome.storage.local.set({
        nativeStatus: 'error',
        nativeError: (response && response.error) || 'Unknown native host error.',
      });
      setIcon('error');
    }
    try { port.disconnect(); } catch { /* ignore */ }
  });

  port.onDisconnect.addListener(() => {
    clearTimeout(timeout);
    const err = chrome.runtime.lastError?.message;
    if (err) {
      chrome.storage.local.set({ nativeStatus: 'error', nativeError: err });
      setIcon('error');
    }
  });

  port.postMessage({ token });
}

// ── Startup: restore icon state from storage ─────────────────────────────────

chrome.runtime.onStartup.addListener(async () => {
  const { token, nativeStatus } = await chrome.storage.local.get(['token', 'nativeStatus']);
  if (token && !isTokenExpired(token)) {
    setIcon(nativeStatus === 'error' ? 'error' : 'ok');
  } else {
    setIcon('warn');
  }
});

chrome.runtime.onInstalled.addListener(() => setIcon('warn'));
