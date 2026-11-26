import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { once } from 'node:events';
import { copyFile, mkdir, readFile, stat, writeFile } from 'node:fs/promises';
import { delimiter, join, resolve } from 'node:path';
import { createInterface } from 'node:readline';
import { DatabaseSync } from 'node:sqlite';
import { setTimeout as delay } from 'node:timers/promises';
import { chromium } from 'playwright-core';

const [phase, installPath, qaPath] = process.argv.slice(2);
assert(process.platform === 'win32' && process.env.GITHUB_ACTIONS === 'true');
const install = resolve(installPath), qa = resolve(qaPath);
const data = join(process.env.APPDATA, 'vn.msxgroup.phongdung');
const worker = join(install, 'worker'), proof = join(qa, 'minh-chung');
const ffmpeg = join(install, 'ffmpeg.exe'), ffprobe = join(install, 'ffprobe.exe');
const names = ['Mẫu cài đặt', 'Mẫu phỏng vấn', 'Mẫu du lịch', 'Mẫu điểm tin', 'Mẫu hướng dẫn',
  'Mẫu nhạc và hình', 'Mẫu mất tệp nguồn', 'Mẫu podcast', 'Mẫu màn hình', 'Mẫu lưu trữ'];
const selected = [1, 2, 4];
const ffOptions = { encoding: 'utf8', windowsHide: true, timeout: 30_000 };

async function until(check, message, ms = 30_000) {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    const value = await check();
    if (value) return value;
    await delay(250);
  }
  throw new Error(message);
}

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
  await writeFile(join(data, 'dang-nhap.json'), JSON.stringify({
    refresh: 'veo-qa-khong-phai-token', id: '00000000-0000-4000-8000-000000000026',
    email: 'veo-qa@example.invalid', ten: 'Kho thử Windows',
  }));
}

async function xemVaXuat() {
  await mkdir(proof, { recursive: true });
  const browser = await chromium.connectOverCDP('http://127.0.0.1:49416', { timeout: 20_000 });
  const context = browser.contexts()[0];
  assert(context, 'Thiếu ngữ cảnh WebView2');
  await context.route('**/*', (route) => {
    const { protocol, hostname } = new URL(route.request().url());
    return /^https?:$/.test(protocol) && hostname !== '127.0.0.1' && hostname !== 'localhost' && !hostname.endsWith('.localhost')
      ? route.abort() : route.continue();
  });
  const page = await until(() => context.pages().find((p) => p.url().includes('tauri.localhost')), 'Chưa thấy trang Tauri');
  page.setDefaultTimeout(15_000);
  const errors = [];
  page.on('pageerror', (error) => errors.push(error.message));
  const filter = (name) => page.getByRole('group', { name: 'Lọc trạng thái video' }).getByRole('button', { name, exact: true });
  const button = (name, root = page) => root.getByRole('button', { name, exact: true });
  const row = (i) => button('Xem ' + names[i]);
  const search = page.getByRole('textbox', { name: 'Tìm video', exact: true });
  const list = page.locator('.d-qlist');
  try {
    await row(0).or(button('Dùng ngay')).first().waitFor({ timeout: 45_000 });
    if (await button('Dùng ngay').isVisible()) await button('Dùng ngay').click();
    const boot = await page.evaluate(() => window.__TAURI_INTERNALS__.invoke('dung_boot'));
    assert(Number.isInteger(boot.port) && typeof boot.token === 'string');
    const read = async (path) => {
      const result = await fetch('http://127.0.0.1:' + boot.port + '/api/' + path, {
        headers: { 'x-dung-token': boot.token }, signal: AbortSignal.timeout(15_000),
      });
      assert.equal(result.status, 200, path);
      return result.json();
    };
    assert.equal((await read('state')).projects.length, names.length);
    await row(0).click();
    const viewports = [];
    for (const [width, height] of [[1100, 700], [1440, 900]]) {
      await page.setViewportSize({ width, height });
      await page.waitForFunction(() => document.querySelector('.d-result video.on')?.readyState >= 2);
      const geometry = await page.evaluate(() => ({
        width: innerWidth, height: innerHeight, overflow: document.documentElement.scrollWidth - innerWidth,
        previewHeight: Math.round(document.querySelector('.d-result .d-phone').getBoundingClientRect().height),
      }));
      assert.equal(geometry.width, width);
      assert.equal(geometry.height, height);
      assert.equal(geometry.overflow, 0);
      assert(geometry.previewHeight >= 350, JSON.stringify(geometry));
      await page.screenshot({ path: join(proof, 'veo-' + width + 'x' + height + '.png') });
      viewports.push(geometry);
    }
    await page.setViewportSize({ width: 1100, height: 620 });
    await filter('Lỗi').focus();
    await filter('Lỗi').press('Enter');
    await row(6).waitFor();
    assert.equal(await row(1).count(), 0);
    await filter('Sẵn sàng xuất').click();
    await search.fill('mẫu');
    await button('Chọn nhiều').click();
    for (const i of selected) await page.getByRole('checkbox', { name: 'Chọn ' + names[i], exact: true }).check();
    await row(4).click();
    const heading = page.locator('.d-result').getByRole('heading', { name: names[4], exact: true });
    await heading.waitFor();
    const scroll = await list.evaluate((el) => {
      el.scrollTop = el.scrollHeight;
      return el.scrollTop;
    });
    assert(scroll > 0, 'Danh sách phải cuộn để kiểm giữ vị trí.');
    await button('Sửa tay', page.locator('.d-auto .d-ws')).click();
    await page.locator('.d-app .d-stage').waitFor();
    await page.locator('.d-app [data-w="w0001"]').dblclick();
    const edit = page.getByRole('textbox', { name: 'Sửa chữ', exact: true });
    await edit.fill('Chọn');
    await edit.press('Enter');
    const firstWord = async () => (await read('projects/p4')).plan.words[0].text;
    await until(async () => await firstWord() === 'Chọn', 'Chưa lưu chữ vừa sửa');
    await page.keyboard.press('Control+z');
    await until(async () => await firstWord() === 'Làm', 'Ctrl+Z chưa hoàn tác');
    await page.keyboard.press('Control+y');
    await until(async () => await firstWord() === 'Chọn', 'Ctrl+Y chưa làm lại');
    await button('Tự động', page.locator('.d-app')).click();
    await heading.waitFor();
    assert.equal(await search.inputValue(), 'mẫu');
    assert.equal(await filter('Sẵn sàng xuất').getAttribute('aria-pressed'), 'true');
    assert(Math.abs(await list.evaluate((el) => el.scrollTop) - scroll) <= 2);
    assert.equal(await page.locator('.d-qlist input:checked').count(), 3);
    assert.equal(await row(4).getAttribute('aria-current'), 'true');
    await page.screenshot({ path: join(proof, 'lua-chon-sau-sua-tay.png') });
    const bulk = button('Xuất 3 video đã chọn');
    await bulk.focus();
    await bulk.press('Enter');
    const dialog = page.getByRole('dialog', { name: 'Xuất 3 video', exact: true });
    await dialog.getByText('Video trong lô', { exact: true }).click();
    const queue = await dialog.getByRole('list').first().innerText();
    assert.deepEqual(names.filter((name) => queue.includes(name)), selected.map((i) => names[i]));
    await button('720p', dialog).click();
    const response = page.waitForResponse((res) => res.request().method() === 'POST' && new URL(res.url()).pathname === '/api/export-batch');
    await button('Xuất 3 tệp', dialog).click();
    const batch = await response, result = await batch.json();
    const ids = selected.map((i) => 'p' + i);
    assert.equal(batch.status(), 200);
    assert.deepEqual(batch.request().postDataJSON().ids.sort(), ids);
    assert.deepEqual(result.failed, []);
    assert.deepEqual(result.queued.map((x) => x.id).sort(), ids);
    const rendered = [];
    for (const id of ids) {
      const project = await until(async () => {
        const { project } = await read('projects/' + id);
        assert(!['loi', 'bi-ngat', 'da-huy'].includes(project.job?.state), JSON.stringify(project.job?.error));
        return project.job?.state === 'xong' && project;
      }, 'Quá giờ chờ xuất ' + id, 120_000);
      const file = project.job.files.find((path) => path.endsWith('.mp4'));
      assert(file && (await stat(file)).size > 0);
      const { streams } = JSON.parse(execFileSync(ffprobe, ['-v', 'error', '-of', 'json',
        '-show_entries', 'stream=codec_name,width,height,nb_frames', file], ffOptions));
      assert.deepEqual(streams.map((s) => s.codec_name).sort(), ['aac', 'h264']);
      assert.equal(Number(streams.find((s) => s.codec_name === 'h264').nb_frames), 120);
      await copyFile(file, join(proof, id + '.mp4'));
      rendered.push({ id, streams });
    }
    const projects = (await read('state')).projects;
    assert.deepEqual(projects.filter((p) => p.job?.kind === 'xuat').map((p) => p.id).sort(), ids);
    assert.deepEqual(errors, []);
    await writeFile(join(proof, 'ket-qua.json'), JSON.stringify({
      version: '0.3.24', commit: 'c885057', os: process.env.VEO_QA_OS, browser: browser.version(),
      workerSha256: process.env.VEO_QA_WORKER_SHA, projects: names.length, selectedFolders: 2,
      search: 'mẫu', filter: 'Sẵn sàng xuất', retainedScrollPx: scroll, shortcuts: ['Ctrl+Z', 'Ctrl+Y'],
      viewports, rendered,
    }, null, 2) + '\n');
    console.log('Đã giữ danh sách và xuất đúng 3/10 video từ hai thư mục trong WebView2.');
  } catch (error) {
    console.error((await page.locator('body').innerText({ timeout: 2500 }).catch(() => '')).slice(0, 500));
    await page.screenshot({ path: join(proof, 'loi.png'), timeout: 3000 }).catch(() => {});
    throw error;
  } finally { await browser.close(); }
}

if (phase === 'tao-kho') await taoKho();
else if (phase === 'xem-va-xuat') await xemVaXuat();
else throw new Error('Thiếu giai đoạn kiểm.');
