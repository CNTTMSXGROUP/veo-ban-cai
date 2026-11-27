// Tạo dự án thử Sửa tay bằng phần dựng của bản cài: vùng làm mờ + nhãn dán khung nhỏ, xuất 720p rồi đo vùng che.
// Dùng: node tao-sua-tay.mjs <thư mục ffmpeg> <thư mục phần dựng> <thư mục thử>
import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import { once } from 'node:events';
import { copyFile, mkdir, writeFile } from 'node:fs/promises';
import { delimiter, join, resolve } from 'node:path';
import { createInterface } from 'node:readline';
import { setTimeout as delay } from 'node:timers/promises';

assert(process.env.GITHUB_ACTIONS === 'true', 'Chỉ chạy trên máy ảo thử.');
const [bin, worker, work] = process.argv.slice(2).map((p) => resolve(p));
const { VEO_QA_DATA: data, VEO_QA_CLIP: voice, VEO_QA_MODEL: model } = process.env;
assert(bin && worker && work && data && voice && model, 'Thiếu thư mục.');
const exe = process.platform === 'win32' ? '.exe' : '';
const ffmpeg = join(bin, 'ffmpeg' + exe), ffprobe = join(bin, 'ffprobe' + exe);
const proof = join(work, 'minh-chung'), music = join(work, 'nhac-trong');
await mkdir(proof, { recursive: true });
await mkdir(music, { recursive: true });
await writeFile(join(music, 'kho-nhac.json'), '[]\n');

// Nguồn kẻ ô 8 px: đo được vùng nào bị làm mờ.
const clip = join(work, 'nguon-ke-o.mp4');
const duration = Number(execFileSync(ffprobe, ['-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', voice], { encoding: 'utf8' }));
assert(duration > 3, 'Tiếng nguồn quá ngắn');
execFileSync(ffmpeg, ['-v', 'error', '-f', 'lavfi', '-i', "color=c=gray:s=1080x1920:r=30,format=yuv420p,geq=lum='255*mod(floor(X/8)+floor(Y/8),2)':cb=128:cr=128",
    '-i', voice, '-map', '0:v', '-map', '1:a', '-t', String(duration), '-c:v', 'libx264', '-preset', 'veryfast', '-c:a', 'aac', '-y', clip], { timeout: 180_000 });

const env = Object.fromEntries(Object.entries(process.env).filter(([k]) => !k.startsWith('DUNG_') && k !== 'NODE_OPTIONS'));
const pathKey = Object.keys(env).find((k) => k.toUpperCase() === 'PATH') ?? 'PATH';
env[pathKey] = [bin, env[pathKey]].join(delimiter);
const child = spawn(join(bin, 'node' + exe), [join(worker, 'dung-app.mjs')], {
    cwd: worker, windowsHide: true, stdio: ['pipe', 'pipe', 'inherit'], env: {
        ...env, DUNG_DATA: data, DUNG_FFMPEG: ffmpeg, DUNG_FFPROBE: ffprobe, DUNG_WHISPER_CLI: join(bin, 'whisper-cli' + exe),
        DUNG_WHISPER_MODEL: model, DUNG_CHEP_LOI: 'may', DUNG_KHO_NHAC: music, DUNG_FONTS: join(worker, 'fonts'),
        DUNG_MAU_VIDEO_DIR: join(worker, 'mau-video'), DUNG_CLAUDE: join(work, 'khong-co-claude'), DUNG_PORT: '0',
    },
});
const exited = once(child, 'exit');
const output = createInterface({ input: child.stdout });
kiem: try {
    const boot = await Promise.race([
        once(output, 'line').then(([line]) => JSON.parse(line)),
        exited.then(([code]) => { throw new Error('Phần dựng thoát trước khi mở: ' + code); }),
        delay(45_000, undefined, { ref: false }).then(() => { throw new Error('Phần dựng chưa mở'); }),
    ]);
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
        const until = Date.now() + 240_000;
        do {
            const v = await call('projects/' + id), j = v.project.job;
            if (j?.kind === kind && ['loi', 'bi-ngat', 'da-huy'].includes(j.state)) throw new Error(JSON.stringify(j.error ?? j.state));
            if (j?.kind === kind && j.state === 'xong' && !v.project.busy) return v;
            await delay(300);
        } while (Date.now() < until);
        throw new Error('Quá giờ chờ ' + kind);
    }
    const { id } = await call('projects', { name: '[TEST] Sửa tay', clips: [clip], ngonNgu: 'en', useAi: false, autoExport: false });
    let v = await waitFor(id, 'dung');
    if (process.env.VEO_QA_CHI_DUNG) { console.log('ĐẠT: chép lời và dựng được.'); break kiem; }
    const act = async (name, args) => { v = await call('projects/' + id + '/act', { name, args, stamp: v.stamp }); };
    const sourceId = v.plan.sources[0].id;
    const sticker = (await call('projects/' + id + '/nhan-dan', { id: 'mui-ten' })).id;
    v = await call('projects/' + id);
    await act('placeAsset', [sticker, '', '', { at: { sourceId, startSec: 0, endSec: 2.6 }, fit: 'nho', box: { x: 240, y: 760, w: 420, h: 300 } }]);
    const mask = { mode: 'blur', shape: 'rect', strength: 70, soft: 45, color: '#101014' };
    await act('placeMask', [mask, { sourceId, startSec: 3.4, endSec: 5 }, { box: { x: 600, y: 300, w: 400, h: 400 } }]);

    await call('projects/' + id + '/export', { video: true, captions: true, check: false, res: 720, name: '[TEST] Sửa tay' });
    const done = await waitFor(id, 'xuat'), mp4 = done.project.job.files.find((p) => p.endsWith('.mp4'));
    assert(mp4, 'Xuất thiếu MP4');
    await copyFile(mp4, join(proof, 'xuat-sua-tay.mp4'));
    const streams = JSON.parse(execFileSync(ffprobe, ['-v', 'error', '-of', 'json', '-show_entries', 'stream=codec_name,width,height', mp4], { encoding: 'utf8' })).streams;
    const video = streams.find((s) => s.codec_name === 'h264');
    assert(video && streams.some((s) => s.codec_name === 'aac'), 'Thiếu hình h264 hoặc tiếng aac');
    assert(video.height > video.width, 'Khung xuất không phải dọc');
    const k = video.width / 1080;
    // Độ gắt: chênh lệch sáng trung bình giữa hai điểm ảnh kề ngang, đo phần giữa mỗi ô.
    const detail = (frame, x, y) => {
        let sum = 0, n = 0;
        for (let row = Math.round(y * k); row < Math.round((y + 200) * k); row++)
            for (let col = Math.round(x * k); col < Math.round((x + 200) * k); col++, n++) sum += Math.abs(frame[row * video.width + col + 1] - frame[row * video.width + col]);
        return sum / n;
    };
    const maskSpan = v.timeline.inserts.find((c) => c.mask), other = v.timeline.inserts.find((c) => !c.mask);
    assert(maskSpan && other, 'Dải thời gian thiếu cảnh chèn');
    const measure = (span, label) => {
        const at = String((span.startSec + span.endSec) / 2);
        const frame = execFileSync(ffmpeg, ['-v', 'error', '-ss', at, '-i', mp4, '-frames:v', '1', '-f', 'rawvideo', '-pix_fmt', 'gray', '-'], { maxBuffer: 1 << 26 });
        assert.equal(frame.length, video.width * video.height);
        execFileSync(ffmpeg, ['-v', 'error', '-ss', at, '-i', mp4, '-frames:v', '1', '-y', join(proof, label + '.png')]);
        return { at, masked: detail(frame, 700, 400), control: detail(frame, 180, 400) };
    };
    const during = measure(maskSpan, 'khung-co-vung-mo'), outside = measure(other, 'khung-khong-vung-mo');
    const result = { id, streams, during, outside, inserts: v.timeline.inserts.map(({ id, name, startSec, endSec, box }) => ({ id, name, startSec, endSec, box })) };
    await writeFile(join(proof, 'ket-qua-xuat.json'), JSON.stringify(result, null, 1));
    await writeFile(join(work, 'id-du-an.txt'), id);
    console.log(JSON.stringify({ during, outside }));
    assert(during.control > 10 && outside.masked > outside.control * 0.6, 'Nguồn không đủ chi tiết để đo');
    assert(during.masked < during.control * 0.25, 'Vùng làm mờ KHÔNG che trong tệp xuất');
    console.log('ĐẠT: xuất có vùng làm mờ, vùng được che trong tệp.');
} finally {
    output.close();
    child.stdin.end();
    if (!await Promise.race([exited.then(() => true), delay(8000, false, { ref: false })])) { child.kill(); await exited; }
}
