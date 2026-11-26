import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { once } from 'node:events';
import { copyFile, mkdir, rename, stat, writeFile } from 'node:fs/promises';
import { delimiter, join, resolve, sep } from 'node:path';
import { createInterface } from 'node:readline';
import { setTimeout as delay } from 'node:timers/promises';

assert(process.platform === 'win32' && process.env.GITHUB_ACTIONS === 'true');
const [installPath, qaPath] = process.argv.slice(2);
const qa = resolve(qaPath), install = resolve(installPath);
const worker = join(install, 'worker'), data = join(qa, 'Kho thử giọng đọc');
const evidence = join(qa, 'minh-chung'), noMusic = join(qa, 'nhac-trong');
const ffmpeg = join(install, 'ffmpeg.exe'), ffprobe = join(install, 'ffprobe.exe');
const env = Object.fromEntries(Object.entries(process.env).filter(([key]) => !key.startsWith('DUNG_') && key.toUpperCase() !== 'PATH'));
const sha = (bytes) => createHash('sha256').update(bytes).digest('hex');
const native = { windowsHide: true, timeout: 30_000 };
const specs = ['huong-dan', 'ban-tin'];
const content = 'Welcome to the studio. First, choose a story. Next, bring it to life with a clear voice.';
await mkdir(noMusic);
await mkdir(evidence);

async function withWorker(test) {
  const processNode = spawn(join(install, 'node.exe'), [join(worker, 'dung-app.mjs')], {
    cwd: worker, stdio: ['pipe', 'pipe', 'inherit'], windowsHide: true, env: {
      ...env, PATH: [install, join(process.env.SystemRoot, 'System32'), process.env.SystemRoot].join(delimiter),
      DUNG_DATA: data, DUNG_FFMPEG: ffmpeg, DUNG_FFPROBE: ffprobe, DUNG_FONTS: join(worker, 'fonts'),
      DUNG_WHISPER_MODEL: join(qa, 'khong-dung-chep-loi'), DUNG_KHO_NHAC: noMusic,
    },
  });
  const exited = once(processNode, 'exit');
  const output = createInterface({ input: processNode.stdout });
  try {
    const boot = await Promise.race([
      once(output, 'line').then(([line]) => JSON.parse(line)),
      exited.then(([code]) => { throw new Error('Phần dựng thoát sớm: ' + code); }),
      delay(35_000, null, { ref: false }),
    ]);
    assert(boot?.port && boot.token, 'Phần dựng không sẵn sàng');
    const fetchWorker = (path, opt = {}) => fetch('http://127.0.0.1:' + boot.port + '/api/' + path, {
      ...opt, headers: { 'x-dung-token': boot.token, ...opt.headers }, signal: AbortSignal.timeout(60_000),
    });
    return await test(async (path, body, status = 200) => {
      const res = await fetchWorker(path, body === undefined ? {} : {
        method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body),
      });
      const reply = await res.json();
      assert.equal(res.status, status, path + ' ' + JSON.stringify(reply).slice(0, 650));
      return reply;
    }, fetchWorker, boot);
  } finally {
    output.close();
    processNode.stdin.end();
    if (!await Promise.race([exited.then(() => true), delay(8000, false, { ref: false })])) processNode.kill();
    await exited;
  }
}

async function waitJob(api, id, kind) {
  for (const until = Date.now() + 140_000; Date.now() < until;) {
    const view = await api('projects/' + id), job = view.project.job;
    if (job?.kind === kind) {
      assert(!['loi', 'bi-ngat', 'da-huy'].includes(job.state), JSON.stringify(job.error ?? job));
      if (job.state === 'xong' && !view.project.busy) return view;
    }
    await delay(350);
  }
  throw new Error('Quá giờ chờ ' + kind);
}

function audioRms(path, from, seconds) {
  const pcm = execFileSync(ffmpeg, ['-v', 'error', '-ss', String(from), '-i', path, '-t', String(seconds),
    '-map', '0:a:0', '-ac', '1', '-ar', '16000', '-f', 's16le', '-'], native);
  assert(pcm.length >= 15000, 'Thiếu mẫu âm thanh đã giải mã');
  let total = 0;
  for (let i = 0; i < pcm.length; i += 2) total += (pcm.readInt16LE(i) / 32768) ** 2;
  return Math.sqrt(total / (pcm.length / 2));
}

const first = await withWorker(async (api, fetchWorker) => {
  const { giongMay, gemini } = await api('giong-doc?refresh=1');
  assert.equal(gemini.dem, 0);
  assert.equal(gemini.coKhoa, false);
  const voice = giongMay.find((g) => g.tieng === 'en-US') ?? giongMay.find((g) => /^en-/i.test(g.tieng));
  assert(voice, 'Máy Windows thử chưa liệt kê giọng tiếng Anh.');
  console.log('Giọng sẵn có: ' + voice.ten + ' · ' + voice.tieng);
  const spec = { nguon: 'may', giong: voice.id, speed: 1, text: content };
  const approve = async (body) => {
    const review = await api('giong-doc/duyet', body);
    assert.equal(review.gui, 0);
    assert.equal(review.dem, 0);
    return review;
  };
  const create = async (body) => {
    const review = await approve(body);
    return api('giong-doc/tao', { ...body, dau: review.dau, gui: review.gui });
  };
  const start = performance.now();
  const read = await create(spec);
  const synthMs = Math.round(performance.now() - start);
  assert(read.durationSec > 3 && read.durationSec < 10);
  assert.equal(read.nguon, 'may');
  assert(!read.mucDung);
  assert.equal((await approve(spec)).daCo.id, read.id);
  const fast = await create({ ...spec, speed: 1.2 });
  assert(fast.id !== read.id && Math.abs(fast.durationSec * 1.2 - read.durationSec) < 0.25);
  for (const [file, voiceFile] of [['giong.wav', read], ['giong-1.2x.wav', fast]]) {
    const response = await fetchWorker('giong-doc/' + voiceFile.id + '/loi-doc.wav');
    assert.equal(response.status, 200);
    assert.equal(response.headers.get('content-type'), 'audio/wav');
    const bytes = Buffer.from(await response.arrayBuffer());
    assert.equal(bytes.toString('ascii', 0, 4), 'RIFF');
    await writeFile(join(evidence, file), bytes);
    assert(audioRms(join(evidence, file), 0.2, 2) > 0.01);
  }

  const seconds = Math.ceil(read.durationSec);
  const withVoice = { voiceId: read.id, name: read.name, durationSec: read.durationSec };
  const draft = { version: 1, canvas: 'ngang', title: 'Một câu chuyện, hai phong cách',
    scenes: [{ text: 'Choose a story', seconds, loiDoc: withVoice }, { text: 'Bring it to life', seconds: 2 }] };
  await api('tao-video', { ...draft, styleId: specs[0], scenes: [{ ...draft.scenes[0], seconds: 2 }] }, 400);
  assert.equal((await api('state')).projects.length, 0);
  const project = [];
  for (const styleId of specs) {
    const { id } = await api('tao-video', { ...draft, styleId });
    const built = await waitJob(api, id, 'dung');
    const storyboard = built.plan.storyboard;
    assert.equal(storyboard.styleId, styleId);
    assert.equal(storyboard.scenes.length, 2);
    assert.equal(built.timeline.frames, (seconds + 2) * 30);
    assert(storyboard.scenes[0].loiDoc.path.includes(sep + id + sep + 'tu-lieu' + sep));
    assert(storyboard.scenes[0].loiDoc.giongDoc);
    assert.equal(storyboard.scenes[0].loiDoc.durationSec, read.durationSec);
    assert((await stat(storyboard.scenes[0].loiDoc.path)).size > 0);
    project.push({ id, styleId });
  }
  return { spec, read, fast, voice, synthMs, seconds, project, availableVoices: giongMay.length };
});

const result = await withWorker(async (api, fetchWorker, boot) => {
  const approved = await api('giong-doc/duyet', first.spec);
  assert.equal(approved.daCo.id, first.read.id);
  assert.equal(approved.gui, 0);
  assert.equal(approved.dem, 0);
  const wav = await fetchWorker('giong-doc/' + first.read.id + '/loi-doc.wav');
  assert.equal(wav.status, 200);
  const reopenedWavSha = sha(Buffer.from(await wav.arrayBuffer()));
  assert.equal(reopenedWavSha, sha(await import('node:fs/promises').then((fs) => fs.readFile(join(evidence, 'giong.wav')))));
  await rename(join(data, 'giong-doc-v1'), join(data, 'giong-doc-v1-kho-thu-da-doi-ten'));
  const exports = [];
  for (const { id, styleId } of first.project) {
    const started = performance.now();
    await api('projects/' + id + '/export', { video: true, res: 720, shape: 'ngang', check: true });
    const view = await waitJob(api, id, 'xuat');
    const file = view.project.job.files.find((path) => path.endsWith('.mp4'));
    assert(file);
    const streams = JSON.parse(execFileSync(ffprobe, ['-v', 'error', '-of', 'json',
      '-show_entries', 'stream=codec_name,codec_type,width,height,nb_frames', file], native)).streams;
    assert.deepEqual(streams.map((s) => s.codec_name).sort(), ['aac', 'h264']);
    const pic = streams.find((s) => s.codec_type === 'video');
    assert.deepEqual([pic.width, pic.height, Number(pic.nb_frames)], [1280, 720, (first.seconds + 2) * 30]);
    const words = audioRms(file, 0.2, 2), silence = audioRms(file, first.seconds + 0.35, 1);
    assert(words > 0.01 && silence < 0.001, 'Lời đọc hoặc khoảng lặng sai: ' + JSON.stringify({ words, silence }));
    const frame = execFileSync(ffmpeg, ['-v', 'error', '-ss', '1', '-i', file, '-an',
      '-frames:v', '1', '-vf', 'scale=32:18', '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-'], native);
    assert.equal(frame.length, 32 * 18 * 3);
    await copyFile(file, join(evidence, styleId + '.mp4'));
    exports.push({ styleId, streams, words, silence, firstSceneSha: sha(frame), exportMs: Math.round(performance.now() - started) });
  }
  assert.notEqual(exports[0].firstSceneSha, exports[1].firstSceneSha);
  execFileSync(process.env.VEO_QA_PYTHON, [join(qa, 'kiem-timecode.py'), ffmpeg, ffprobe, evidence], {
    windowsHide: true, timeout: 180_000, input: JSON.stringify(boot), stdio: ['pipe', 'inherit', 'inherit'],
  });
  return { version: '0.3.24', source: process.env.VEO_QA_SOURCE, sha: process.env.VEO_QA_WORKER_SHA,
    os: process.env.VEO_QA_OS, availableVoices: first.availableVoices, voice: first.voice.ten, language: first.voice.tieng,
    durationSec: first.read.durationSec, fasterDurationSec: first.fast.durationSec, sends: 0, synthMs: first.synthMs,
    sceneSeconds: first.seconds, reopenedWavSha, sceneSurvivesDetachedVoiceCache: true, exports };
});
console.log(JSON.stringify(result));
await writeFile(join(evidence, 'ket-qua-giong.json'), JSON.stringify(result, null, 2) + '\n');
