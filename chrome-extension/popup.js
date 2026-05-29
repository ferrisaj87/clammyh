/* Clammy Token popup script */

function fmtRelative(ms) {
  const sec = Math.round((ms - Date.now()) / 1000);
  if (sec <= 0) return 'expired';
  if (sec < 60) return `${sec}s`;
  if (sec < 3600) return `${Math.floor(sec / 60)}m`;
  if (sec < 86400) return `${Math.floor(sec / 3600)}h ${Math.floor((sec % 3600) / 60)}m`;
  const d = Math.floor(sec / 86400);
  const h = Math.floor((sec % 86400) / 3600);
  return `${d}d ${h}h`;
}

function fmtDate(ms) {
  return new Date(ms).toLocaleString(undefined, {
    weekday: 'short', month: 'short', day: 'numeric',
    hour: 'numeric', minute: '2-digit',
  });
}

function expiryFraction(capturedAt, expiresAt) {
  if (!capturedAt || !expiresAt) return 0;
  const total = expiresAt - capturedAt;
  const elapsed = Date.now() - capturedAt;
  return Math.max(0, Math.min(1, 1 - elapsed / total));
}

function barColor(fraction) {
  if (fraction > 0.5) return '#22c55e';
  if (fraction > 0.2) return '#f59e0b';
  return '#ef4444';
}

function render(data) {
  const {
    token, capturedAt, expiresAt, username,
    nativeStatus, nativeError, savedPath,
  } = data;

  const statusCard  = document.getElementById('status-card');
  const noTokenCard = document.getElementById('no-token-card');
  const dot         = document.getElementById('dot');
  const label       = document.getElementById('status-label');
  const meta        = document.getElementById('meta');
  const barWrap     = document.getElementById('bar-wrap');
  const bar         = document.getElementById('expiry-bar');
  const div1        = document.getElementById('div1');
  const pathRow     = document.getElementById('path-row');
  const pathText    = document.getElementById('path-text');
  const nativeBox   = document.getElementById('native-status-box');
  const setupHint   = document.getElementById('setup-hint');
  const copyBtn     = document.getElementById('copy-btn');

  if (!token) {
    noTokenCard.style.display = 'block';
    statusCard.style.display  = 'none';
    setupHint.style.display   = 'block';
    return;
  }

  noTokenCard.style.display = 'none';
  statusCard.style.display  = 'block';
  div1.style.display        = 'block';
  pathRow.style.display     = 'flex';

  const expired = !expiresAt || expiresAt < Date.now();
  const fraction = expiryFraction(capturedAt, expiresAt);

  // Status card state
  const state = expired ? 'warn' : 'ok';
  statusCard.className = `status-card ${state}`;
  dot.className = `dot ${state}`;

  if (expired) {
    label.textContent = 'Token expired';
    meta.innerHTML = `Captured ${capturedAt ? fmtDate(capturedAt) : 'unknown'}.<br>
      Visit <strong>horizonxi.com</strong> to auto-refresh.`;
    barWrap.style.display = 'none';
  } else {
    label.textContent = `Valid${username ? ' — ' + username : ''}`;
    const left = fmtRelative(expiresAt);
    meta.innerHTML = `Expires in <strong>${left}</strong> (${fmtDate(expiresAt)}).`;
    barWrap.style.display = 'block';
    bar.style.width = `${Math.round(fraction * 100)}%`;
    bar.style.background = barColor(fraction);
  }

  // Path / native status
  if (savedPath) {
    pathRow.classList.add('saved');
    pathText.textContent = savedPath;
    pathText.title = savedPath;
  } else if (nativeStatus === 'error') {
    pathRow.classList.remove('saved');
    pathText.textContent = 'Not saved to disk (native host error)';
    setupHint.style.display = 'block';
  } else {
    pathRow.classList.remove('saved');
    pathText.textContent = nativeStatus === 'pending' ? 'Saving…' : 'Path unknown';
  }

  // Native status box
  if (nativeStatus === 'error' && nativeError) {
    nativeBox.style.display = 'block';
    nativeBox.className = 'native-status error';
    nativeBox.textContent = `Host error: ${nativeError}`;
  } else if (nativeStatus === 'saved') {
    nativeBox.style.display = 'block';
    nativeBox.className = 'native-status saved';
    nativeBox.textContent = 'Saved to disk — Clammy will use this automatically.';
  } else {
    nativeBox.style.display = 'none';
  }

  // Copy button
  copyBtn.onclick = () => {
    navigator.clipboard.writeText(token).then(() => {
      const fb = document.getElementById('copy-feedback');
      fb.style.display = 'inline';
      setTimeout(() => { fb.style.display = 'none'; }, 1800);
    });
  };
}

chrome.storage.local.get(
  ['token', 'capturedAt', 'expiresAt', 'username', 'nativeStatus', 'nativeError', 'savedPath'],
  render,
);
