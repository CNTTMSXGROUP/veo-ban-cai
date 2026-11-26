import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { copyFile, mkdir, readFile, rename, writeFile } from 'node:fs/promises';
import { isAbsolute, join, relative } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';

const [root, data, evidence, ffmpeg] = process.argv.slice(2);
assert(root && data && evidence && ffmpeg && [root, data, evidence, ffmpeg].every(isAbsolute));
const boot = JSON.parse(readFileSync(0, 'utf8').replace(/^\uFEFF/, ''));
assert(Number.isInteger(boot.port) && boot.port > 0 && boot.port < 65536 && typeof boot.token === 'string' && boot.token.length);
const base = 'http://127.0.0.1:' + boot.port + '/api/';
const input = join(root, 'nguon-ban-giao');
await mkdir(input);
await mkdir(evidence);

async function api(path, body) {
    const response = await fetch(base + path, {
        method: body === undefined ? 'GET' : 'POST',
        headers: { 'x-dung-token': boot.token, 'content-type': 'application/json' },
        body: body === undefined ? undefined : JSON.stringify(body),
        signal: AbortSignal.timeout(45_000),
    });
    const result = await response.json();
    assert.equal(response.status, 200, result.error?.message ?? path);
    return result;
}
async function waitJob(route, kind, requestId) {
    const until = Date.now() + 150_000;
    while (Date.now() < until) {
        const view = await api(route);
        const job = view.project.job;
        if (job?.kind === kind && (!requestId || job.xuatId === requestId) && !view.project.busy) {
            assert.equal(job.state, 'xong', JSON.stringify(job.error ?? job));
            return view;
        }
        await delay(150);
    }
    throw Error('Quá giờ xử lý ' + kind);
}
function makeClip(name, color, seconds, withAudio) {
    const path = join(input, name + '.mp4');
    const audio = withAudio ? [
        '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000:duration=' + seconds, '-c:a', 'aac',
    ] : ['-an'];
    execFileSync(ffmpeg, ['-hide_banner', '-v', 'error', '-nostdin', '-f', 'lavfi', '-i',
        'color=' + color + ':s=640x360:r=30:d=' + seconds, ...audio, '-c:v', 'libx264', '-threads', '1', '-y', path]);
    return path;
}
async function project(name, clips) {
    const { id } = await api('projects', { name, clips, canvas: 'ngang', dungTheo: 'hinh', useAi: false, autoExport: false });
    const route = 'projects/' + id;
    return { route, view: await waitJob(route, 'dung') };
}
function under(dir, path) {
    const rel = relative(dir, path);
    return !!rel && !isAbsolute(rel) && !/^\.\.(?:[\\/]|$)/.test(rel);
}
const duration = ({ source_range: { duration } }) => duration.value / duration.rate;

async function publish(route, scenario, total, silent) {
    const request = await api(route + '/export', { video: false, audio: true, audioFmt: 'wav', fcpxml: true, draft: true,
        name: scenario, res: 720, check: true });
    const view = await waitJob(route, 'xuat', request.requestId);
    const record = (await api(route + '/exports')).runs.find((r) => r.id === request.requestId);
    const files = Object.fromEntries(record.result.files.map(({ kind, path }) => [kind, path]));
    assert.deepEqual(Object.keys(files), ['audio', 'fcpxml', 'draft']);
    assert(Object.values(files).every((path) => under(data, path)));
    const pcm = execFileSync(ffmpeg, ['-v', 'error', '-nostdin', '-i', files.audio, '-map', '0:a:0',
        '-ac', '2', '-ar', '48000', '-f', 's16le', '-c:a', 'pcm_s16le', '-'], { maxBuffer: 6_000_000 });
    const from = (total-silent) * 48000 * 4;
    assert.equal(pcm.length, total * 48000 * 4);
    assert(pcm.subarray(from).every((byte) => byte === 0), 'Vùng lặng của WAV phải bằng 0');
    if (from) assert(pcm.subarray(0,from).some((byte) => byte !== 0), 'Phần mở đầu của WAV phải còn tiếng');
    const otio = JSON.parse(await readFile(files.draft, 'utf8'));
    const audio = otio.tracks.children.find((t) => t.kind === 'Audio').children;
    const video = otio.tracks.children.find((t) => t.kind === 'Video').children;
    assert.equal(audio.reduce((sum,c) => sum+duration(c), 0), total);
    assert.equal(video.reduce((sum,c) => sum+duration(c), 0), total);
    const gap = audio.filter((c) => c.OTIO_SCHEMA === 'Gap.1');
    assert.equal(gap.reduce((sum,c) => sum+duration(c), 0), silent);
    const xml = await readFile(files.fcpxml, 'utf8');
    if (from) {
        assert.deepEqual(audio.map((c) => c.OTIO_SCHEMA), ['Clip.2','Gap.1']);
        assert(decodeURIComponent(video[1].media_references.DEFAULT_MEDIA.target_url).endsWith('/Nguồn hình câm.mp4'));
        assert(record.result.notes.some((n) => n.includes('Nguồn hình câm.mp4')));
    } else {
        assert(audio.every((c) => c.OTIO_SCHEMA === 'Gap.1'));
        assert.equal((xml.match(/srcEnable="video"/g) ?? []).length, video.length);
        assert(view.plan.style.off.includes('voice'));
    }
    for (const [kind, extension] of [['audio','wav'],['fcpxml','fcpxml'],['draft','otio']]) {
        await copyFile(files[kind], join(evidence, scenario + '.' + extension));
    }
    return { scenario, total, silent, length: audio.length };
}

const first = makeClip('Nguồn có tiếng', 'red', 3, true);
const second = makeClip('Nguồn hình câm', 'blue', 2, false);
const mixed = await project('Thử bàn giao khi thiếu nguồn hình câm', [first,second]);
assert.deepEqual(mixed.view.plan.sources.map(({ frames, hasAudio }) => [frames,hasAudio !== false]), [[90,true],[60,false]]);
const source = mixed.view.plan.sources[1];
for (const path of new Set([source.original, source.path])) {
    assert(under(input,path) || under(data,path), 'Chỉ được mô phỏng mất tệp trong kho kiểm thử');
    await rename(path, path+'.da-doi');
}
const mixedProof = await publish(mixed.route, 'Co-tieng-va-khoang-lang', 5, 2);
const muted = await project('Thử bàn giao khi tắt tiếng gốc', [first]);
const changed = await api(muted.route + '/act', { name: 'setStyle', args: [{ off: ['voice'] }], stamp: muted.view.stamp });
assert(changed.changed && changed.plan.style.off.includes('voice'));
const mutedProof = await publish(muted.route, 'Tat-tieng-goc', 3, 3);
const output = { platform: process.platform, arch: process.arch, checks: [mixedProof, mutedProof] };
await writeFile(join(evidence, 'dinh-dang.json'), JSON.stringify(output, null, 2) + '\n');
console.log('VEO_DELIVERY_OK ' + JSON.stringify(output));
