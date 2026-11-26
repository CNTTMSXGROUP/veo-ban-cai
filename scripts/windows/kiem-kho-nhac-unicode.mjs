import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import { once } from 'node:events';
import { copyFile, mkdir, stat, writeFile } from 'node:fs/promises';
import { basename, delimiter, join, resolve } from 'node:path';
import { createInterface } from 'node:readline';
import { DatabaseSync } from 'node:sqlite';
import { setTimeout as delay } from 'node:timers/promises';

assert(process.platform === 'win32' && process.env.GITHUB_ACTIONS === 'true');
const [installPath, qaPath] = process.argv.slice(2);
const install = resolve(installPath), qa = resolve(qaPath);
const worker = join(install, 'worker'), data = join(qa, 'kho');
const root = join(data, 'tai-nguyen'), name = 'kho-nhac-co-san.tar';
const archive = join(root, name), done = join(root, 'kho-nhac-xong');
const exists = (path) => stat(path).then(() => true, (e) => { if (e.code === 'ENOENT') return false; throw e; });
const runtime = join(install, 'node.exe');
const path = [install, join(process.env.SystemRoot, 'System32'), process.env.SystemRoot].join(delimiter);
const env = Object.fromEntries(Object.entries(process.env).filter(([key]) => !key.startsWith('DUNG_') && key.toUpperCase() !== 'PATH'));

async function run(entry, check) {
  const child = spawn(runtime, [entry], {
    cwd: worker, stdio: ['pipe', 'pipe', 'inherit'], windowsHide: true, env: {
      ...env, PATH: path, DUNG_DATA: data, DUNG_FFMPEG: join(install, 'ffmpeg.exe'),
      DUNG_FFPROBE: join(install, 'ffprobe.exe'), DUNG_WHISPER_MODEL: join(qa, 'khong-dung-chep-loi'),
    },
  });
  const exited = once(child, 'exit'), output = createInterface({ input: child.stdout });
  try {
    const boot = await Promise.race([
      once(output, 'line').then(([line]) => JSON.parse(line)),
      exited.then(([code]) => { throw new Error('Phần dựng thoát sớm: ' + code); }),
      delay(30_000, null, { ref: false }),
    ]);
    assert(boot?.port && boot.token, 'Phần dựng chưa mở');
    for (let end = Date.now() + 200_000; Date.now() < end;) {
      const r = await fetch('http://127.0.0.1:' + boot.port + '/api/state', {
        headers: { 'x-dung-token': boot.token }, signal: AbortSignal.timeout(10_000),
      });
      assert.equal(r.status, 200);
      const passed = await check(await r.json());
      if (passed) return passed;
      await delay(450);
    }
    throw new Error('Quá giờ kiểm ' + basename(entry));
  } finally {
    output.close();
    child.stdin.end();
    if (!await Promise.race([exited.then(() => true), delay(8000, false, { ref: false })])) child.kill();
    await exited;
  }
}

await mkdir(root, { recursive: true });
await copyFile(join(qa, name), archive);
const start = await stat(archive);
const before = await run(join(worker, 'dung-app.mjs'), async (state) => {
  const error = state.taiNguyen?.loi;
  if (!error) return null;
  assert.match(error, /unreadable filename/i);
  assert(!await exists(done));
  return { failed: true, unreadableFilename: true, archiveBytes: (await stat(archive)).size };
});
assert.equal(before.archiveBytes, start.size);
console.log('Đã tái hiện lỗi tên tệp trên phần dựng cũ.');

const patched = join(worker, 'Veo-Worker-QA-59ea9a4.mjs');
await copyFile(join(qa, basename(patched)), patched);
await run(patched, async (state) => {
  assert(!state.taiNguyen?.loi, state.taiNguyen?.loi);
  return await exists(done) && !await exists(archive) && !await exists(join(root, 'kho-tam'));
});
const db = new DatabaseSync(join(data, 'phong-dung.db'), { readOnly: true });
let songs;
try {
  songs = db.prepare("SELECT name,file FROM songs WHERE origin LIKE 'kho:%'").all();
} finally { db.close(); }
const unicode = songs.filter((s) => /[^\x00-\x7F]/.test(s.name));
assert(unicode.length > 0);
for (const { file } of songs) assert((await stat(file)).size > 0);
execFileSync(join(install, 'ffmpeg.exe'), ['-v', 'error', '-i', unicode[0].file, '-t', '1', '-f', 'null', '-'], {
  windowsHide: true, timeout: 20_000,
});
await run(patched, async (state) => state.taiNguyen === null && await exists(done) && !await exists(archive));
const proof = { platform: process.platform, source: '59ea9a4ae0379bedaa41f05265e90ce432289701',
  workerSha256: process.env.VEO_QA_WORKER_SHA, windowsVersion: process.env.VEO_QA_OS,
  before, after: { songs: songs.length, unicode: unicode.length, decodedAudio: true, usedCachedArchive: true, reopened: true } };
console.log(JSON.stringify(proof));
await writeFile(join(qa, 'ket-qua-kho-nhac.json'), JSON.stringify(proof, null, 2) + '\n');
