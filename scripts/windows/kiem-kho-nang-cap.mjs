import assert from 'node:assert/strict';
import { execFileSync, spawn, spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { once } from 'node:events';
import { copyFile, mkdir, readFile, writeFile } from 'node:fs/promises';
import { delimiter, join, resolve } from 'node:path';
import { createInterface } from 'node:readline';
import { setTimeout as delay } from 'node:timers/promises';

const [phase, installPath, workPath] = process.argv.slice(2);
assert(process.platform === 'win32' && process.env.GITHUB_ACTIONS === 'true', 'Chỉ dùng kho thử của máy Windows GitHub Actions.');
assert(installPath && workPath && ['truoc', 'sau'].includes(phase), 'Thiếu thư mục hoặc giai đoạn kiểm.');
const install = resolve(installPath), work = resolve(workPath);
const data = join(process.env.APPDATA, 'vn.msxgroup.phongdung');
const worker = join(install, 'worker');
const ffmpeg = join(install, 'ffmpeg.exe'), ffprobe = join(install, 'ffprobe.exe');
const proofPath = join(work, 'kho-0.3.24.json');
const caption = 'Ba THẺ Màu · giữ kho cũ';
const mask = { mode: 'solid', shape: 'rect', strength: 100, color: '#172937' };

const env = Object.fromEntries(Object.entries(process.env).filter(([key]) => !key.startsWith('DUNG_') && key !== 'NODE_OPTIONS'));
for (const key of Object.keys(env)) if (key.toUpperCase() === 'PATH') delete env[key];
const child = spawn(join(install, 'node.exe'), [join(worker, 'dung-app.mjs')], {
    cwd: worker, stdio: ['pipe', 'pipe', 'inherit'], windowsHide: true, env: {
        ...env, PATH: [install, join(process.env.SystemRoot, 'System32'), process.env.SystemRoot].join(delimiter),
        DUNG_DATA: data, DUNG_FFMPEG: ffmpeg, DUNG_FFPROBE: ffprobe, DUNG_WHISPER_CLI: join(install, 'whisper-cli.exe'),
        DUNG_WHISPER_MODEL: join(work, 'ggml-base.en-q5_1.bin'), DUNG_CHEP_LOI: 'may',
        DUNG_FONTS: join(worker, 'fonts'), DUNG_CLAUDE: join(work, 'khong-co-claude.exe'),
    },
});
const exited = once(child, 'exit');
const output = createInterface({ input: child.stdout });
const sha = async (path) => createHash('sha256').update(await readFile(path)).digest('hex');
const probe = (path) => JSON.parse(execFileSync(ffprobe, [
    '-v', 'error', '-of', 'json', '-show_entries', 'stream=codec_name,width,height,avg_frame_rate,nb_frames', path,
], { encoding: 'utf8', windowsHide: true })).streams;
const capture = (v) => ({
    head: v.head, stamp: v.stamp, revs: v.history.map(({ n, label }) => ({ n, label })),
    frames: v.timeline.frames, text: v.timeline.pages.map((page) => page.text),
    source: v.plan.sources.map(({ id, path, original }) => ({ id, path, original })),
    inserts: v.plan.style.inserts, cover: v.plan.style.cover,
});

try {
    const boot = await Promise.race([
        once(output, 'line').then(([line]) => JSON.parse(line)),
        exited.then(([code]) => { throw new Error('Phần dựng thoát trước khi mở: ' + code); }),
        delay(45_000, undefined, { ref: false }).then(() => { throw new Error('Phần dựng chưa mở'); }),
    ]);
    assert(boot.port && boot.token, 'Thiếu thông tin mở phần dựng');
    const call = async (route, body) => {
        const result = await fetch('http://127.0.0.1:' + boot.port + '/api/' + route, {
            method: body === undefined ? 'GET' : 'POST', headers: { 'x-dung-token': boot.token, 'content-type': 'application/json' },
            body: body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(60_000),
        });
        const value = await result.json();
        assert.equal(result.status, 200, route + ' ' + JSON.stringify(value).slice(0, 800));
        return value;
    };
    async function waitFor(id, kind) {
        const until = Date.now() + 150_000;
        do {
            const v = await call('projects/' + id), j = v.project.job;
            if (j?.kind === kind && ['loi', 'bi-ngat', 'da-huy'].includes(j.state)) throw new Error(JSON.stringify(j.error ?? j.state));
            if (j?.kind === kind && j.state === 'xong' && !v.project.busy) return v;
            await delay(300);
        } while (Date.now() < until);
        throw new Error('Quá giờ chờ ' + kind);
    }
    async function render(id, name) {
        await call('projects/' + id + '/export', { video: true, captions: true, check: false, res: 720, name });
        const v = await waitFor(id, 'xuat'), mp4 = v.project.job.files.find((path) => path.endsWith('.mp4'));
        assert(mp4, 'Xuất thiếu MP4');
        return { path: mp4, streams: probe(mp4) };
    }
    if (phase === 'truoc') {
        const input = join(work, 'qa-upgrade-voice.mp4'), cover = join(work, 'Bìa thử.jpg');
        execFileSync(ffmpeg, ['-v', 'error', '-i', input, '-frames:v', '1', '-y', cover], { windowsHide: true });
        const { id } = await call('projects', { name: 'Kho cũ · Ba thẻ màu', clips: [input], ngonNgu: 'en', useAi: false, autoExport: false });
        let v = await waitFor(id, 'dung');
        const firstPage = v.timeline.pages[0];
        assert(firstPage, 'Ca chép lời chưa có phụ đề');
        const act = async (name, args) => {
            v = await call('projects/' + id + '/act', { name, args, stamp: v.stamp });
        };
        await act('editPageText', [firstPage.firstWordId, caption]);
        const sourceId = v.plan.sources[0].id;
        await act('placeMask', [mask, { sourceId, startSec: 1, endSec: 3 }, { box: { x: 325, y: 695, w: 432, h: 418 } }]);
        const sticker = (await call('projects/' + id + '/nhan-dan', { id: 'mui-ten' })).id;
        await act('placeAsset', [sticker, '', '', { at: { sourceId, startSec: 3.1, endSec: 5 }, box: { x: 90, y: 980, w: 360, h: 260 } }]);
        await act('setCoverImage', [cover]);
        await act('editCoverImage', [{ zoom: 130, x: 21, preset: 'dien-anh' }]);
        const old = capture(v);
        assert.equal(old.revs.length, 6);
        assert(old.text.includes(caption) && old.inserts.some((c) => c.mask?.color === mask.color) && old.inserts.some((c) => c.asset === sticker));
        assert.equal(old.cover.imageEdit.zoom, 130);
        const video = await render(id, 'Xuất từ Vèo 0.3.24');
        const paths = new Set([input, old.cover.imagePath, video.path, ...old.source.map((s) => s.path), ...old.inserts.map((c) => c.path).filter(Boolean)]);
        const hashes = await Promise.all([...paths].map(async (path) => ({ path, sha: await sha(path) })));
        await writeFile(proofPath, JSON.stringify({ id, old, video, hashes }));
        console.log('Vèo 0.3.24 đã chép lời, lưu 6 phiên bản sửa và xuất MP4.');
    } else {
        const { id, old, video, hashes } = JSON.parse(await readFile(proofPath, 'utf8'));
        assert.deepEqual(capture(await call('projects/' + id)), old, 'Nội dung hoặc lịch sử dự án cũ bị đổi');
        for (const file of hashes) assert.equal(await sha(file.path), file.sha, 'Tệp cũ đã thay đổi: ' + file.path);
        const current = process.env.VEO_QA_EXPORT;
        assert(current && current !== video.path, 'Thiếu MP4 đã xuất bằng giao diện.');
        const streams = probe(current);
        assert.deepEqual(streams, video.streams, 'Tệp xuất sau cập nhật sai thông số');
        assert.deepEqual(streams.map((s) => s.codec_name), ['h264', 'aac']);
        // r27 sửa ma trận màu. So cấu trúc hình và giữ mã băm cũ của tệp đã bàn giao.
        const comparison = spawnSync(ffmpeg, ['-nostats', '-i', video.path, '-i', current, '-lavfi', 'ssim=shortest=1', '-an', '-f', 'null', '-'],
            { encoding: 'utf8', windowsHide: true, stdio: ['ignore', 'ignore', 'pipe'] });
        assert.equal(comparison.status, 0, comparison.stderr || comparison.error?.message);
        const ssim = Number(/All:(\d+(?:\.\d+)?)/.exec(comparison.stderr)?.[1]);
        assert(ssim >= 0.9, 'Khung mới sai hình quá mức: ' + ssim);
        const evidence = join(work, 'minh-chung');
        await mkdir(evidence, { recursive: true });
        await copyFile(video.path, join(evidence, 'Veo-truoc-0323.mp4'));
        await copyFile(current, join(evidence, 'Veo-sau-0325.mp4'));
        await writeFile(join(evidence, 'ket-qua.json'), JSON.stringify({
            scenario: process.env.VEO_QA_CASE, history: old.revs.length, preservedFiles: hashes.length,
            frames: Number(streams[0].nb_frames), ssim, platform: process.platform,
            from: '0.3.24', to: '0.3.25', workerSha256: await sha(join(worker, 'dung-app.mjs')),
            oldMp4Sha256: await sha(video.path), newMp4Sha256: await sha(current), uiExportAndReopen: true,
        }, null, 2) + '\n');
        console.log('Giữ ' + old.revs.length + ' phiên bản và ' + hashes.length + ' tệp. MP4 xuất từ Vèo có ' + streams[0].nb_frames + ' khung, SSIM ' + ssim + '.');
    }
} finally {
    output.close();
    child.stdin.end();
    const finished = await Promise.race([exited.then(() => true), delay(8000, false, { ref: false })]);
    if (!finished) { child.kill(); await exited; }
}
