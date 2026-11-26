import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { once } from 'node:events';
import { copyFile, mkdir, readFile, stat, writeFile } from 'node:fs/promises';
import { delimiter, join, resolve } from 'node:path';
import { createInterface } from 'node:readline';
import { DatabaseSync } from 'node:sqlite';
import { setTimeout as delay } from 'node:timers/promises';

const [phase, installPath, qaPath] = process.argv.slice(2);
assert(process.platform === 'win32' && process.env.GITHUB_ACTIONS === 'true');
const install = resolve(installPath), qa = resolve(qaPath);
const data = join(process.env.APPDATA, 'vn.msxgroup.phongdung');
const worker = join(install, 'worker'), proof = join(qa, 'minh-chung');
const ffmpeg = join(install, 'ffmpeg.exe'), ffprobe = join(install, 'ffprobe.exe');
const names = ['Mẫu cài đặt', 'Mẫu phỏng vấn', 'Mẫu du lịch', 'Mẫu điểm tin', 'Mẫu hướng dẫn',
  'Mẫu nhạc và hình', 'Mẫu mất tệp nguồn', 'Mẫu podcast', 'Mẫu màn hình', 'Mẫu lưu trữ'];
const selected = ['p1', 'p2', 'p4'];
const ffOptions = { encoding: 'utf8', windowsHide: true, timeout: 30_000 };

async function taoKho() {
  const clip = join(qa, 'nguon-tong-hop.mp4');
  execFileSync(ffmpeg, ['-v', 'error', '-f', 'lavfi', '-i', 'testsrc2=s=360x640:r=30:d=4',
    '-f', 'lavfi', '-i', 'sine=f=440:r=48000:d=4', '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-c:a', 'aac', clip], ffOptions);
  const env = Object.fromEntries(Object.entries(process.env).filter(([key]) => !key.startsWith('DUNG_') && key.toUpperCase() !== 'PATH'));
  const child = spawn(join(install, 'node.exe'), [join(worker, 'dung-app.mjs')], {
    cwd: worker, stdio: ['pipe', 'pipe', 'inherit'], windowsHide: true, env: {
      ...env, PATH: [install, join(process.env.SystemRoot, 'System32'), process.env.SystemRoot].join(delimiter),
      DUNG_DATA: data, DUNG_FFMPEG: ffmpeg, DUNG_FFPROBE: ffprobe, DUNG_CHEP_LOI: 'may', DUNG_FONTS: join(worker, 'fonts'),
    },
  });
  const exited = once(child, 'exit');
  const output = createInterface({ input: child.stdout });
  try {
    const boot = await Promise.race([
      once(output, 'line').then(([line]) => JSON.parse(line)),
      exited.then(([code]) => { throw new Error('Phần dựng thoát sớm: ' + code); }),
      delay(45_000, null, { ref: false }),
    ]);
    assert(boot?.port, 'Phần dựng chưa tạo kho');
  } finally {
    output.close();
    child.stdin.end();
    if (!await Promise.race([exited.then(() => true), delay(8000, false, { ref: false })])) child.kill();
    await exited;
  }
  const plan = JSON.parse(await readFile(join(qa, 'danh-sach-lam-viec-plan.json'), 'utf8'));
  // shortcut: dữ liệu kiểm thử bám schema của đúng bộ cài QA, cập nhật khi đổi schema.
  const db = new DatabaseSync(join(data, 'phong-dung.db'));
  try {
    db.prepare('INSERT INTO folders (id, name, created_at) VALUES (?, ?, ?)').run('nhom-a', 'Tuần này', 1);
    db.prepare('INSERT INTO folders (id, name, created_at) VALUES (?, ?, ?)').run('nhom-b', 'Tiếp theo', 2);
    const project = db.prepare(`INSERT INTO projects
      (id, name, status, head, tip, clips_json, created_at, updated_at, folder_id, luu_tru)
      VALUES (?, ?, 'san-sang', 0, 0, ?, ?, ?, ?, ?)`);
    const version = db.prepare('INSERT INTO versions (project_id, n, uid, plan_json, label, created_at) VALUES (?, 0, ?, ?, ?, ?)');
    for (const [i, name] of names.entries()) {
      const id = 'p' + i, time = Date.now() + names.length - i;
      const source = i === 6 ? join(qa, 'thieu-nguon.mp4') : clip;
      Object.assign(plan.sources[0], { original: source, path: source });
      project.run(id, name, JSON.stringify([source]), time, time, i === 1 || i === 2 ? 'nhom-a' : i === 4 ? 'nhom-b' : null, i === 9 ? 1 : null);
      version.run(id, randomUUID(), JSON.stringify(plan), 'Bản dựng kiểm thử', time);
    }
    assert.equal(db.prepare('SELECT count(*) AS n FROM versions').get().n, names.length);
  } finally { db.close(); }
  console.log('Đã tạo kho riêng với ' + names.length + ' video tổng hợp.');
}

function snapshot() {
  const db = new DatabaseSync(join(data, 'phong-dung.db'), { readOnly: true });
  try {
    return db.prepare(`SELECT p.id, p.head, p.folder_id, p.job_json, v.plan_json FROM projects p
      JOIN versions v ON v.project_id=p.id AND v.n=p.head ORDER BY p.id`).all().map((p) => ({
      id: p.id, head: p.head, folder: p.folder_id, items: JSON.parse(p.plan_json).items.length,
      job: p.job_json ? JSON.parse(p.job_json) : undefined,
    }));
  } finally { db.close(); }
}

async function minhChung() {
  const projects = snapshot();
  assert.equal(projects.length, names.length);
  const rendered = projects.filter((p) => p.job?.kind === 'xuat');
  assert.deepEqual(rendered.map((p) => p.id), selected);
  assert.equal(new Set(rendered.map((p) => p.folder)).size, 2);
  for (const p of rendered) {
    assert.equal(p.job.state, 'xong', p.id);
    const file = p.job.files.find((f) => f.endsWith('.mp4'));
    assert(file && (await stat(file)).size > 0);
    const { streams } = JSON.parse(execFileSync(ffprobe, ['-v', 'error', '-of', 'json',
      '-show_entries', 'stream=codec_name,width,height,nb_frames', file], ffOptions));
    assert.deepEqual(streams.map((stream) => stream.codec_name).sort(), ['aac', 'h264']);
    assert.equal(Number(streams.find((stream) => stream.codec_name === 'h264').nb_frames), 120);
    await copyFile(file, join(proof, p.id + '.mp4'));
    p.streams = streams;
    delete p.job;
  }
  const ui = JSON.parse(await readFile(join(proof, 'giao-dien.json'), 'utf8'));
  assert.equal(ui.restoredSelection, 3);
  assert.equal(ui.revisions.split.items, 2);
  assert.equal(ui.revisions.undo.items, 1);
  assert.equal(ui.revisions.redo.items, 2);
  await writeFile(join(proof, 'ket-qua.json'), JSON.stringify({
    version: '0.3.24', commit: 'c885057', os: process.env.VEO_QA_OS, workerSha256: process.env.VEO_QA_WORKER_SHA,
    projects: projects.length, selectedFolders: 2, ui, rendered,
  }, null, 2) + '\n');
  console.log('Đã giữ danh sách và xuất đúng 3/10 video từ hai thư mục trong WebView2.');
}

if (phase === 'tao-kho') await taoKho();
else if (phase === 'doc-kho') {
  const id = process.argv[5];
  const rows = snapshot().filter((p) => !id || p.id === id);
  console.log(JSON.stringify(id ? rows[0] : rows));
} else if (phase === 'minh-chung') await minhChung();
else throw new Error('Thiếu giai đoạn kiểm.');
