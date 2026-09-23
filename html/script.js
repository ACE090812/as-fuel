const $ = (id) => document.getElementById(id);

const STATUS = { idle: 'READY', fuel: 'FUELLING', done: 'COMPLETE' };

function render(d) {
    if (!d) return;

    const mode = d.mode || 'idle';
    $('screen').dataset.mode = mode;
    $('statusText').textContent = STATUS[mode] || 'READY';

    if (d.brand) $('brand').textContent = d.brand;
    if (typeof d.price === 'number') $('price').textContent = d.price.toFixed(2);

    if (typeof d.litres === 'number') $('litres').textContent = d.litres.toFixed(1);
    if (typeof d.cost === 'number') $('cost').textContent = Math.round(d.cost);
    $('costLabel').textContent = mode === 'done' ? 'PAID' : 'TOTAL';

    const tankWrap = $('tankWrap');
    if (typeof d.tank === 'number' && mode !== 'done') {
        const pct = Math.max(0, Math.min(100, d.tank));
        tankWrap.classList.add('show');
        $('tankPct').textContent = Math.round(pct) + '%';
        $('tankFill').style.width = pct + '%';
        $('tankFill').classList.toggle('low', pct < 15);
    } else {
        tankWrap.classList.remove('show');
    }

    const prompts = $('prompts');
    prompts.innerHTML = '';
    (d.prompts || []).forEach((p) => {
        const el = document.createElement('div');
        el.className = 'prompt';
        if (p.key) {
            const k = document.createElement('span');
            k.className = 'key';
            k.textContent = p.key;
            el.appendChild(k);
        }
        const t = document.createElement('span');
        t.textContent = p.label;
        el.appendChild(t);
        prompts.appendChild(el);
    });
}

window.addEventListener('message', (e) => {
    let data = e.data;
    if (typeof data === 'string') {
        try { data = JSON.parse(data); } catch (_) { return; }
    }
    render(data);
});

// preview in a normal browser: open index.html?preview
if (location.search.includes('preview')) {
    render({
        mode: 'fuel', brand: 'NINE LABS FUEL', price: 3.5, litres: 12.4, cost: 44, tank: 62,
        prompts: [{ key: 'E', label: 'Release to stop' }],
    });
}
