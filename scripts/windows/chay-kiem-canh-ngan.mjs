import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import { once } from 'node:events';
import { mkdir } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { createInterface } from 'node:readline';
import { setTimeout as delay } from 'node:timers/promises';

assert(process.platform === 'win32' && process.env.GITHUB_ACTIONS === 'true');
const [install, qa] = process.argv.slice(2).map((p) => resolve(p));
const worker = join(install, 'worker');
const emptyMusic = join(qa, 'nhac-trong');
await mkdir(emptyMusic);
const env = Object.fromEntries(Object.entries(process.env).filter(([k]) => !k.startsWith('DUNG_')));
Object.assign(env, {
  DUNG_DATA: join(qa, 'Kho thử'), DUNG_KHO_NHAC: emptyMusic,
  DUNG_FFMPEG: join(install, 'ffmpeg.exe'), DUNG_FFPROBE: join(install, 'ffprobe.exe'),
  DUNG_FONTS: join(worker, 'fonts'), DUNG_MAU_VIDEO_DIR: join(worker, 'mau-video'),
  DUNG_WHISPER_MODEL: join(qa, 'khong-chep-loi'), DUNG_PORT: '0',
});
const child = spawn(join(install, 'node.exe'), [join(worker, 'dung-app.mjs')], {
  cwd: worker, env, windowsHide: true, stdio: ['pipe', 'pipe', 'inherit'],
});
const exited = once(child, 'exit');
const lines = createInterface({ input: child.stdout });
try {
  const boot = await Promise.race([
    once(lines, 'line').then(([line]) => JSON.parse(line)),
    exited.then(([code]) => { throw Error('Phần dựng thoát sớm ' + code); }),
    delay(40_000, null, { ref: false }),
  ]);
  assert(boot?.port && boot.token);
  execFileSync(process.env.VEO_QA_PYTHON, [
    join(qa, 'kiem-canh-ngan.py'), env.DUNG_FFMPEG, env.DUNG_FFPROBE, join(qa, 'minh-chung'),
  ], { windowsHide: true, timeout: 180_000, input: JSON.stringify(boot), stdio: ['pipe', 'inherit', 'inherit'] });
} finally {
  lines.close();
  child.stdin.end();
  if (!await Promise.race([exited.then(() => true), delay(8000, false, { ref: false })])) child.kill();
  await exited;
}
