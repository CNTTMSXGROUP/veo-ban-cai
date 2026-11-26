const assert = require('node:assert/strict');
const { createHash } = require('node:crypto');
const { appendFileSync, readFileSync, writeFileSync } = require('node:fs');
const { createServer } = require('node:https');
const { join } = require('node:path');

const [dir, proof] = process.argv.slice(2);
const cloudHost = 'us-central1-aiplatform.googleapis.com';
const resource = 'projects/veo-lite-qa/locations/us-central1/publishers/google/models/veo-3.1-lite-generate-001';
const operation = resource + '/operations/veo-lite-qa-receipt';
const clip = readFileSync(join(proof, 'clip-cloud-thu.mp4')).toString('base64');
const log = join(proof, 'luot-google-cloud.jsonl');
let submitted = 0;
let queried = 0;

createServer({ key: readFileSync(join(dir, 'cloud-key.pem')), cert: readFileSync(join(dir, 'cloud-cert.pem')) }, async (req, res) => {
  const reply = (status, payload) => {
    res.writeHead(status, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(payload));
  };
  try {
    assert.equal(req.method, 'POST');
    assert.equal(req.headers.host, cloudHost);
    assert.equal(req.headers.authorization, 'Bearer oauth-qa-veo-local-token');
    const pieces = [];
    let length = 0;
    for await (const chunk of req) {
      length += chunk.length;
      assert(length < 4 * 1024 ** 2);
      pieces.push(chunk);
    }
    const body = JSON.parse(Buffer.concat(pieces).toString('utf8'));
    if (req.url === '/v1/' + resource + ':predictLongRunning') {
      assert.equal(++submitted, 1);
      assert.deepEqual(body.parameters, { aspectRatio: '16:9', durationSeconds: 4, generateAudio: false, resolution: '720p', sampleCount: 1 });
      assert.equal(body.instances.length, 1);
      const instance = body.instances[0];
      assert.deepEqual(Object.keys(instance).sort(), ['image', 'prompt']);
      assert.equal(instance.prompt, 'A slow camera move across the opening frame.');
      assert.equal(instance.image.mimeType, 'image/jpeg');
      const image = Buffer.from(instance.image.bytesBase64Encoded, 'base64');
      assert(image.length > 4 && image.readUInt16BE(0) === 0xffd8 && image.readUInt16BE(image.length - 2) === 0xffd9);
      writeFileSync(join(proof, 'anh-mo-dau-da-gui.jpg'), image);
      const imageSha256 = createHash('sha256').update(image).digest('hex');
      appendFileSync(log, JSON.stringify({ action: 'submit', model: 'Veo 3.1 Lite', ...body.parameters, imageSha256 }) + '\n');
      reply(200, { name: operation });
      return;
    }
    assert.equal(req.url, '/v1/' + resource + ':fetchPredictOperation');
    assert.equal(submitted, 1);
    assert.deepEqual(body, { operationName: operation });
    const status = ++queried === 1 ? 503 : 200;
    appendFileSync(log, JSON.stringify({ action: 'poll', operation, status }) + '\n');
    if (status === 503) reply(status, {});
    else reply(status, { done: true, response: { videos: [{ mimeType: 'video/mp4', bytesBase64Encoded: clip }] } });
  } catch (error) {
    appendFileSync(log, JSON.stringify({ action: 'unexpected', message: String(error) }) + '\n');
    reply(400, {});
  }
}).listen(443, '127.0.0.1', () => writeFileSync(join(dir, 'cloud-ready.txt'), 'ready\n'));
