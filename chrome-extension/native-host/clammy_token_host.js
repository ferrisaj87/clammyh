#!/usr/bin/env node
/**
 * Clammy HorizonXI — native messaging host
 *
 * Chrome sends: { token: "eyJ..." }
 * We write the token to horizon_bearer.txt, then reply: { success: true, path: "..." }
 *
 * Native messaging wire format: 4-byte LE uint32 length + UTF-8 JSON body.
 */

'use strict';

const fs   = require('fs');
const path = require('path');
const os   = require('os');

// ── Locate bearer file ────────────────────────────────────────────────────────

function findBearerPath() {
  const appdata = process.env.APPDATA || path.join(os.homedir(), 'AppData', 'Roaming');

  // Primary: Game\config\addons\ClammyHorizon\data\horizon_bearer.txt
  const horizonCandidate = path.join(
    appdata,
    'HorizonXI-Launcher', 'HorizonXI', 'Game',
    'config', 'addons', 'ClammyHorizon', 'data',
    'horizon_bearer.txt',
  );
  if (fs.existsSync(path.dirname(horizonCandidate))) {
    return horizonCandidate;
  }

  // Also create the data dir if it doesn't exist yet (first capture)
  const dataDir = path.dirname(horizonCandidate);
  try { fs.mkdirSync(dataDir, { recursive: true }); return horizonCandidate; } catch { /* fall through */ }

  // Fallback: %APPDATA%\ClammyHorizon\horizon_bearer.txt
  return path.join(appdata, 'ClammyHorizon', 'horizon_bearer.txt');
}

// ── Native messaging I/O ──────────────────────────────────────────────────────

function readMessage() {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let totalLen = 0;
    let msgLen   = null;

    function tryParse() {
      const buf = Buffer.concat(chunks);
      if (msgLen === null) {
        if (buf.length < 4) return;
        msgLen = buf.readUInt32LE(0);
      }
      if (buf.length < 4 + msgLen) return;
      const json = buf.slice(4, 4 + msgLen).toString('utf8');
      try { resolve(JSON.parse(json)); } catch (e) { reject(e); }
    }

    process.stdin.on('data', (chunk) => {
      chunks.push(chunk);
      totalLen += chunk.length;
      tryParse();
    });
    process.stdin.on('error', reject);
    process.stdin.on('end', () => reject(new Error('stdin closed before message')));
  });
}

function writeMessage(obj) {
  const body   = Buffer.from(JSON.stringify(obj), 'utf8');
  const header = Buffer.alloc(4);
  header.writeUInt32LE(body.length, 0);
  process.stdout.write(Buffer.concat([header, body]));
}

// ── Main ──────────────────────────────────────────────────────────────────────

async function main() {
  let msg;
  try {
    msg = await readMessage();
  } catch (e) {
    writeMessage({ success: false, error: `Could not read message: ${e.message}` });
    process.exit(1);
  }

  if (!msg || typeof msg.token !== 'string' || msg.token.length < 30) {
    writeMessage({ success: false, error: 'Missing or invalid token in message.' });
    process.exit(1);
  }

  const token     = msg.token.trim();
  const bearerPath = findBearerPath();
  const dir        = path.dirname(bearerPath);

  try {
    if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(bearerPath, token, 'utf8');
    writeMessage({ success: true, path: bearerPath });
    process.exit(0);
  } catch (e) {
    writeMessage({ success: false, error: `Could not write ${bearerPath}: ${e.message}` });
    process.exit(1);
  }
}

main();
