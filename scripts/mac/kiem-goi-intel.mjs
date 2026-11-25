// Chỉ nạp vào DMG kiểm thử. Gọi cùng lệnh Tauri và API mà giao diện Vèo dùng.
const mirror = 'http://127.0.0.1:49325/qa';
const verify = (value, message) => { if (!value) throw new Error(message); };
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const invoke = (command) => window.__TAURI_INTERNALS__.invoke(command);
const packBytes = 33_002_680;
const name = 'Góc đọc sách · Mac Intel';
let stage = 'Mở app';

async function control(path, result) {
    const response = await fetch(mirror + path, result === undefined ? {} : {
        method: 'POST', body: JSON.stringify(result), headers: { 'content-type': 'text/plain' },
    });
    verify(response.ok, 'Máy kiểm thử trả mã ' + response.status);
    return response.json();
}

async function run() {
    const mark = async (name) => { stage = name; await control('/step', { name }); };
    const test = await control('/state');
    const t0 = performance.now();
    const { port, token } = await invoke('dung_boot');
    const bootMs = Math.round(performance.now() - t0);
    verify(port && token, 'Vèo chưa nối được phần dựng');
    const api = async (path, body) => {
        const result = await fetch('http://127.0.0.1:' + port + '/api/' + path, {
            method: body === undefined ? 'GET' : 'POST',
            headers: { 'x-dung-token': token, ...(body === undefined ? {} : { 'content-type': 'application/json' }) },
            body: body === undefined ? undefined : JSON.stringify(body),
            signal: AbortSignal.timeout(120_000),
        }).catch((cause) => { throw new Error(path + ' · ' + String(cause?.message ?? cause)); });
        const data = await result.json();
        verify(result.ok, path + ' trả mã ' + result.status + ' ' + JSON.stringify(data).slice(0, 350));
        return data;
    };
    async function waitJob(id, kind) {
        const until = performance.now() + 120_000;
        while (performance.now() < until) {
            const view = await api('projects/' + id), job = view.project.job;
            if (job?.kind === kind) {
                verify(!['loi', 'da-huy', 'bi-ngat'].includes(job.state), String(job.error?.message ?? job.state));
                if (job.state === 'xong' && !view.project.busy) return view;
            }
            await sleep(250);
        }
        throw new Error('Quá giờ chờ ' + kind);
    }
    const started = await invoke('phan_chay_trang_thai');
    verify(!started.dang && !started.loi, 'Phần chạy chưa ổn định');
    if (test.warm) {
        const { project } = await api('projects/' + test.cold.id);
        const status = await api('do-hoa');
        verify(started.got === 0 && started.total === 0 && status.engine && status.gsap, 'Vèo tải lại gói hoặc không dùng được gói đã cài');
        verify(project.name === name && project.exportPath === test.cold.video, 'Mất dự án hoặc đường dẫn tệp xuất sau khi mở lại');
        return control('/warm', { ok: true, bootMs });
    }
    verify(started.total === test.coreBytes && started.got === started.total, 'Vèo chưa tải đủ phần chạy từ kho trống');
    verify((await api('pixel')).effects.length === 244 && (await api('phong-cach/thu-vien')).items.length >= 802,
        'Danh mục đóng gói bị thiếu');
    verify(!(await api('do-hoa')).engine, 'Vèo đã có bộ dựng trước lượt tải đầu');
    const pack = await invoke('phan_do_hoa_trang_thai');
    verify(pack?.size === packBytes && !pack.dang, 'Thiếu bộ dựng x64 tải theo yêu cầu');
    await mark('Từ chối gói đồ họa sai');
    let rejected = '';
    try { await invoke('phan_do_hoa_cai'); } catch (cause) { rejected = String(cause); }
    verify(/không đúng nội dung/.test(rejected) && !(await api('do-hoa')).engine, 'Bộ dựng có mã băm sai chưa bị từ chối');
    await mark('Cài bộ dựng đúng mã băm');
    const t1 = performance.now();
    await invoke('phan_do_hoa_cai');
    const packMs = Math.round(performance.now() - t1);
    const status = await api('do-hoa');
    verify(status.engine && status.browser && status.three && status.gsap, 'Bộ dựng, Chrome, Three.js hoặc GSAP chưa sẵn sàng');
    const spec = {
        version: 1, id: 'chu-dong', title: 'Góc đọc sách', subtitle: 'Chữ động trên Mac Intel', accent: '#ffc16e',
        seconds: 2, speed: 1, chuDong: { kieu: 'nay', theo: 'tu', treMs: 50, doNay: 1.8 },
    };
    await mark('Dựng bản xem chữ động');
    const t2 = performance.now();
    const preview = await api('do-hoa/xem', { canvas: 'ngang', spec });
    const renderMs = Math.round(performance.now() - t2);
    verify(preview.key, 'Bộ dựng chưa tạo bản xem chữ động');
    await mark('Đặt lớp chữ động vào storyboard');
    const { id } = await api('tao-video', {
        version: 1, styleId: 'pixel', canvas: 'ngang', title: name,
        scenes: [
            { text: '', seconds: 2, hinh: { fit: 'vua', startSec: 0, useAudio: false, asset: { doHoaMoi: spec, name: spec.title } } },
            { text: 'Một buổi sáng yên tĩnh', seconds: 2 },
        ],
    });
    await mark('Dựng hai cảnh đã chọn');
    const built = await waitJob(id, 'dung');
    const layer = built.plan.storyboard?.scenes[0]?.hinh?.asset?.doHoa;
    verify(layer?.id === spec.id && layer.subtitle === spec.subtitle, 'Cảnh đầu chưa gắn đúng lớp chữ động');
    await mark('Xuất MP4 ngang');
    await api('projects/' + id + '/export', { video: true, captions: false, check: false, res: 720, shape: 'ngang' });
    const output = await waitJob(id, 'xuat');
    const video = output.project.job.files.find((path) => path.endsWith('.mp4'));
    verify(video, 'Vèo chưa xuất MP4 từ storyboard');
    await control('/cold', { ok: true, bootMs, packMs, renderMs, preview: preview.key, id, video });
}

try { await run(); } catch (error) {
    await control('/failure', { stage, message: String(error?.message ?? error) });
    throw error;
}
