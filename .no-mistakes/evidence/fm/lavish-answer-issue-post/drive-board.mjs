// Drives the real Lavish board in headless Chrome over the DevTools protocol,
// the way the captain would: pick a radio on each named card, queue each
// answer, then press the Lavish send control.
// Usage: node drive-board.mjs <session-url> <screenshot.png> <card=value>... [--inspect]
import { spawn } from 'node:child_process';
import { writeFileSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const [url, shot, ...rest] = process.argv.slice(2);
const inspect = rest.includes('--inspect');
const picks = rest.filter((a) => a.includes('=')).map((a) => a.split('='));
const port = 47392;
const profile = mkdtempSync(join(tmpdir(), 'fm-lab-chrome.'));
const chrome = spawn('google-chrome', [
  '--headless=new', '--no-sandbox', '--disable-gpu', '--window-size=1400,1000',
  `--remote-debugging-port=${port}`, `--user-data-dir=${profile}`, 'about:blank',
], { stdio: 'ignore' });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

let ws, seq = 0;
const waiting = new Map();
const contexts = [];
function send(method, params = {}, sessionId) {
  const id = ++seq;
  ws.send(JSON.stringify({ id, method, params, sessionId }));
  return new Promise((res, rej) => waiting.set(id, { res, rej }));
}
async function evalIn(ctx, expression) {
  const r = await send('Runtime.evaluate', { expression, contextId: ctx.id, returnByValue: true, awaitPromise: true }, ctx.sessionId);
  if (r.exceptionDetails) throw new Error(JSON.stringify(r.exceptionDetails));
  return r.result.value;
}

try {
  let page;
  for (let i = 0; i < 50 && !page; i++) {
    try { page = (await (await fetch(`http://127.0.0.1:${port}/json/list`)).json()).find((t) => t.type === 'page'); } catch { await sleep(200); }
  }
  ws = new WebSocket(page.webSocketDebuggerUrl);
  await new Promise((r) => ws.addEventListener('open', r));
  ws.addEventListener('message', (ev) => {
    const m = JSON.parse(ev.data);
    if (m.id && waiting.has(m.id)) {
      const w = waiting.get(m.id); waiting.delete(m.id);
      m.error ? w.rej(new Error(JSON.stringify(m.error))) : w.res(m.result);
    } else if (m.method === 'Runtime.executionContextCreated') {
      contexts.push({ ...m.params.context, sessionId: m.sessionId });
    } else if (m.method === 'Target.attachedToTarget') {
      // The artifact is a sandboxed frame, which Chrome runs as its own target.
      send('Runtime.enable', {}, m.params.sessionId).catch(() => {});
    }
  });
  const sessionId = undefined;
  await send('Page.enable');
  await send('Runtime.enable');
  await send('Target.setAutoAttach', { autoAttach: true, waitForDebuggerOnStart: false, flatten: true });
  await send('Page.navigate', { url });
  await sleep(5000);

  // The artifact frame is the context that holds the card forms.
  let board;
  if (inspect) for (const ctx of contexts) { try { console.log('ctx', ctx.id, await evalIn(ctx, `location.href + ' forms=' + document.querySelectorAll('form').length + ' lavish=' + typeof window.lavish + ' body=' + (document.body ? document.body.innerText.slice(0,80) : 'none')`)); } catch (e) { console.log('ctx', ctx.id, 'gone'); } }
  for (const ctx of contexts) {
    try { if (await evalIn(ctx, `!!document.querySelector('form[data-lavish-question]') && !!window.lavish`)) board = ctx; } catch {}
  }
  const top = contexts.findLast((c) => c.auxData?.isDefault && c.origin.startsWith('http') && !c.sessionId) ;
  if (inspect) {
    console.log('contexts:', contexts.map((c) => `${c.origin} ${c.name} default=${c.auxData?.isDefault}`));
    console.log('board context found:', !!board);
    console.log(await evalIn(top, `[...document.querySelectorAll('button')].map(b => (b.innerText||b.getAttribute('aria-label')||'').trim() + (b.disabled?' [disabled]':'')).join(' | ')`));
  }
  if (!board) throw new Error('the board artifact frame did not load');
  for (const [card, value] of picks) {
    const ok = await evalIn(board, `(() => {
      const f = document.querySelector('form[data-lavish-question="${card}"]');
      const r = f && f.querySelector('input[value="${value}"]');
      if (!r) return false;
      r.click(); f.querySelector('button[type=submit]').click(); return true; })()`);
    console.log(`queued ${card}=${value}: ${ok}`);
    if (!ok) throw new Error(`card ${card} has no option ${value}`);
  }
  await sleep(1000);
  if (picks.length) {
    const sent = await evalIn(top, `(() => {
      const b = [...document.querySelectorAll('button')].find(b => /^send( to agent)?$/i.test((b.innerText||'').trim()) && !b.disabled);
      if (!b) return 'no enabled send button: ' + [...document.querySelectorAll('button')].map(b => (b.innerText||'').trim()).join(' | ');
      b.click(); return 'clicked: ' + b.innerText.trim(); })()`);
    console.log('send control:', sent);
    if (!sent.startsWith('clicked')) throw new Error(sent);
    await sleep(2500);
  }
  const png = await send('Page.captureScreenshot', { format: 'png' }, sessionId);
  writeFileSync(shot, Buffer.from(png.data, 'base64'));
  console.log('screenshot:', shot);
} finally {
  try { ws?.close(); } catch {}
  chrome.kill('SIGKILL');
}
