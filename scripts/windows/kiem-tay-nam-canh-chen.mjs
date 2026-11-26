import assert from 'node:assert/strict';
import { writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { setTimeout as wait } from 'node:timers/promises';

assert(process.platform === 'win32' && process.env.GITHUB_ACTIONS === 'true');
const [port, proof] = process.argv.slice(2);
const targets = await fetch('http://127.0.0.1:' + port + '/json/list', { signal: AbortSignal.timeout(10000) }).then(r => r.json());
const target = targets.find(x => x.type === 'page' && /tauri/.test(x.url));
assert(target, targets.map(x => [x.type, x.url]));
const socket = new WebSocket(target.webSocketDebuggerUrl);
await new Promise((ok, fail) => {
  socket.addEventListener('open', ok, { once: true });
  socket.addEventListener('error', fail, { once: true });
});
let serial = 0;
const replies = new Map();
socket.addEventListener('message', ({ data }) => {
  const msg = JSON.parse(data);
  const reply = replies.get(msg.id);
  if (reply) {
    replies.delete(msg.id);
    reply(msg);
  }
});
async function send(method, params = {}) {
  const id = ++serial;
  const reply = new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      replies.delete(id);
      reject(new Error('WebView2 hết thời gian cho ' + method));
    }, 10000);
    replies.set(id, payload => {
      clearTimeout(timer);
      if (payload.error) reject(new Error(JSON.stringify(payload.error)));
      else resolve(payload.result);
    });
  });
  socket.send(JSON.stringify({ id, method, params }));
  return reply;
}
async function read(expression) {
  const result = await send('Runtime.evaluate', { expression, returnByValue: true });
  if (result.exceptionDetails) throw new Error(JSON.stringify(result.exceptionDetails));
  return result.result.value;
}
const boxOf = expression => read('JSON.stringify((() => {const el = ' + expression + '; if (!el) return null; const {x,y,width,height}=el.getBoundingClientRect(); return {x,y,width,height};})())').then(JSON.parse);
const rect = selector => boxOf('document.querySelector(' + JSON.stringify(selector) + ')');
const caption = name => boxOf('[...document.querySelectorAll("button")].find(e=>e.textContent.trim()===' + JSON.stringify(name) + ' && e.getClientRects().length)');
const clip = '.d-clip.ins[data-k="insert"]';
async function mouse(type, x, y, pressed = false) {
  const dragging = pressed || type === 'mousePressed';
  const button = type === 'mouseMoved' && !pressed ? 'none' : 'left';
  await send('Input.dispatchMouseEvent', { type, x, y, button, buttons: dragging ? 1 : 0, clickCount: type === 'mouseMoved' ? 0 : 1 });
}
async function drag(box, dx, dy) {
  assert(box && box.width && box.height, 'Không thấy tay nắm trên màn thử');
  const x = box.x + box.width / 2, y = box.y + box.height / 2;
  await mouse('mouseMoved', x, y);
  await mouse('mousePressed', x, y);
  for (let i = 1; i <= 8; i++) {
    await mouse('mouseMoved', x + dx * i / 8, y + dy * i / 8, true);
    await wait(30);
  }
  await mouse('mouseReleased', x + dx, y + dy);
  await wait(1000);
}
async function screenshot(name) {
  const shot = await send('Page.captureScreenshot', { format: 'png' });
  await writeFile(join(proof, name + '.png'), Buffer.from(shot.data, 'base64'));
}
try {
  const start = await rect(clip);
  assert(start?.width > 45, start);
  const step = Math.min(28, Math.floor(start.width / 6));
  const initialHandles = await read('document.querySelectorAll(".d-pip-size").length');
  await screenshot('canh-day-khung');
  await drag(await rect(clip + ' .d-handle.r'), step, 0);
  const grow = await rect(clip);
  await screenshot('keo-dai-ben-phai');
  await drag(await rect(clip + ' .d-handle.r'), -step, 0);
  const shrink = await rect(clip);
  await screenshot('thu-ngan-ben-phai');

  const toggle = await caption('Khung nhỏ');
  assert(toggle, 'Không thấy tuỳ chọn Khung nhỏ.');
  await drag(toggle, 0, 0);
  const corners = await read('document.querySelectorAll(".d-pip-size").length');
  const before = await rect('.d-pip');
  assert(before, 'Chưa hiện khung nhỏ sau khi chọn.');
  const handle = await rect('.d-pip-size');
  await drag(handle, -15, 0);
  const after = await rect('.d-pip');
  await screenshot('tay-nam-khung-nho');
  const result = {
    source: process.env.VEO_QA_SOURCE, input: 'Chuột trong WebView2 của app đã cài',
    timeline: { start, grow, shrink, rightExtends: grow.width > start.width + 3, rightShortens: shrink.width < grow.width - 3 },
    shape: { initialHandles, handlesInSmallBox: corners, before, after },
  };
  await writeFile(join(proof, 'tai-hien-canh-chen.json'), JSON.stringify(result, null, 2) + '\n');
  console.log(JSON.stringify(result));
} catch (error) {
  await screenshot('loi-thao-tac').catch(() => {});
  throw error;
} finally {
  socket.close();
}
