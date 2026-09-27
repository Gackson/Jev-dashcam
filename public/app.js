const $ = selector => document.querySelector(selector);
const esc = value => String(value ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
let state = { topics: [], records: [], status: {}, events: [] };
let view = 'all', search = '', selected = null, snapshot = '', toastTimer;
const time = value => new Date(value).toLocaleTimeString('zh-CN', { hour: '2-digit', minute: '2-digit' });
const date = value => new Date(value).toLocaleDateString('zh-CN', { month: 'short', day: 'numeric' });
function toast(message) { $('#toast').textContent = message; $('#toast').hidden = false; clearTimeout(toastTimer); toastTimer = setTimeout(() => $('#toast').hidden = true, 4200); }
async function api(path, data, method = 'POST') {
  const response = await fetch(path, { method, headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(data || {}) });
  const result = await response.json();
  if (!response.ok) throw new Error(result.error || '操作失败');
  await refresh();
  return result;
}
async function safe(action) { try { await action(); } catch (error) { toast(error.message); } }
function tag(topic) { return `<span class="tag ${esc(topic.color)}"><i class="topic-dot"></i>${esc(topic.name)}</span>`; }
function showTopic() { $('#topic-dialog').showModal(); }
function render() {
  const { topics, records, status, events } = state;
  if (view !== 'all' && view !== 'inbox' && !topics.some(t => t.id === view)) view = 'all';
  const topic = topics.find(t => t.id === view);
  $('#navigation').innerHTML = `<button class="nav-item ${view === 'all' ? 'active' : ''}" data-view="all"><span class="nav-icon">▦</span>全部资料<span class="count">${records.length}</span></button><button class="nav-item ${view === 'inbox' ? 'active' : ''}" data-view="inbox"><span class="nav-icon">▤</span>待整理<span class="count">${records.filter(r => !r.labels.length).length}</span></button>`;
  $('#topic-nav').innerHTML = topics.length ? topics.map(t => `<button class="nav-item ${view === t.id ? 'active' : ''} ${esc(t.color)}" data-view="${t.id}"><i class="topic-dot"></i>${esc(t.name)}<span class="count">${records.filter(r => r.labels.includes(t.id)).length}</span></button>`).join('') : '<p class="empty-topics">种下一个话题，<br>开始积累你的好奇心。</p>';
  $('#breadcrumb').textContent = topic?.name || (view === 'inbox' ? '待整理' : '全部资料');
  let filtered = records.filter(r => view === 'all' || (view === 'inbox' ? !r.labels.length : r.labels.includes(view)));
  if (search.trim()) { const q = search.trim().toLowerCase(); filtered = filtered.filter(r => `${r.title} ${r.text} ${r.app}`.toLowerCase().includes(q)); }
  $('#view-title').innerHTML = `${esc(topic?.name || (view === 'inbox' ? '待整理' : '你的资料库'))} <span>${filtered.length}</span>`;
  $('#view-description').textContent = topic?.description || (view === 'inbox' ? '暂未匹配的内容，也值得再看一眼。' : '每一份收集，都有迹可循。');
  $('#records').innerHTML = filtered.length ? filtered.map(r => {
    const labels = topics.filter(t => r.labels.includes(t.id));
    const pending = ['pending', 'processing'].includes(r.status);
    const cover = r.frames.at(-1);
    const preview = cover
      ? `<div class="note-preview"><img src="/screenshots/${encodeURIComponent(cover.image)}" alt="${esc(r.title)}的截图" loading="lazy" decoding="async"><span class="preview-count">${r.frames.length} 张截图</span></div>`
      : '';
    return `<button class="note-card ${cover ? 'has-screenshot' : ''}" data-record="${r.id}">${preview}<div class="note-source"><span class="source-icon">${r.kind === 'capture' ? '▣' : r.kind === 'demo' ? '✳' : '↳'}</span>${esc(r.app)}<time>${date(r.created)} · ${time(r.created)}</time></div><h3>${esc(r.title)}</h3>${cover ? '' : `<p class="note-excerpt">${esc(r.text)}</p>`}<div class="note-bottom">${labels.map(tag).join('')}${!labels.length ? `<span class="tag ${pending ? 'pending-tag' : ''}">${pending ? 'Jev 正在归类…' : r.status === 'error' ? '归类失败 · 可重试' : '待整理'}</span>` : ''}${r.kind === 'demo' ? '<span class="sample-label">示例内容</span>' : ''}</div><div class="card-meta"><span>${r.frames.length ? `${r.frames.length} 张截图 · ` : ''}${r.text.length.toLocaleString()} 字</span><span>${cover ? '查看截图' : '查看原文'} ↗</span></div></button>`;
  }).join('') : `<div class="empty"><div class="empty-symbol">${search ? '⌕' : '✳'}</div><h3>${search ? '还没有找到这份内容' : topic ? '这个话题，等待第一份发现' : view === 'inbox' ? '暂时没有待整理的资料' : '好奇心，值得被好好收藏'}</h3><p>${search ? '试试换一个关键词。' : !topics.length ? '从一个你关心的话题开始。<br>之后的每一次阅读，都可能带来新的发现。' : '开始采集，或粘贴一段你想留下的文字。<br>Jev 会把相关内容收进对应的话题。'}</p>${!search && !topics.length ? '<button class="primary" data-action="add-topic">＋ 创建第一个话题</button>' : !search && view !== 'inbox' ? '<button class="primary" data-action="import">＋ 收集一段文字</button>' : ''}</div>`;
  if (topic) $('#records').insertAdjacentHTML('beforeend', `<button class="delete-topic" data-delete-topic="${topic.id}">移除这个话题（保留资料）</button>`);
  const running = ['running', 'starting'].includes(status.capture);
  $('#capture-button').innerHTML = running ? '<span>Ⅱ</span> 暂停采集' : '<span>▶</span> 开始采集';
  $('#capture-title').textContent = { running: '正在留意', starting: '连接中…', permission: '等待授权', paused: '已暂停', error: '需要留意' }[status.capture] || '等待开启';
  $('#capture-message').textContent = status.message || '';
  $('#status-dot').className = `status-dot ${running ? 'running' : ''}`;
  $('#wave').className = `wave ${running ? 'live' : ''}`;
  $('#sample-count').textContent = (status.samples || 0).toLocaleString();
  $('#matched-count').textContent = records.filter(r => r.labels.length).length;
  $('#model-label').textContent = status.modelConfigured ? 'Jev 已配置 · 文字语义归类' : 'Jev 未配置 · 请设置 API Key';
  $('#queue-count').textContent = status.queue ? `${status.queue} 份处理中` : '';
  $('#error-banner').hidden = !status.error && !records.some(r => r.status === 'error');
  $('#error-banner').innerHTML = status.error ? esc(status.error) : records.some(r => r.status === 'error') ? `${esc(records.find(r => r.status === 'error').error)} <button class="subtle" data-action="retry">重试归类 ↗</button>` : '';
  $('#activity-list').innerHTML = events.length ? events.slice(0, 4).map(e => `<div class="activity-item"><span class="activity-point ${e.type}"></span><div><p>${esc(e.message)}</p><time>${time(e.time)}</time></div></div>`).join('') : '<p class="quiet">下一次发现，从这里开始。</p>';
}
function showDetail(id) {
  const r = state.records.find(r => r.id === id); if (!r) return;
  const keepOCROpen = selected === id && $('#detail-dialog').open && Boolean($('#ocr-content')?.open);
  selected = id;
  const screenshots = r.frames.length ? `
    <section class="detail-section screenshot-section">
      <h3>截图记录 <span class="optional">${r.frames.length} 张 · 点击图片查看原图</span></h3>
      ${r.frames.map((f, i) => ({ ...f, index: i })).reverse().map((f, i) => `
        ${i ? `<details class="earlier-screenshot"><summary>${time(f.time)} · 第 ${f.index + 1} 次收集</summary>` : `<p class="screenshot-caption">${time(f.time)} · 最新截图</p>`}
        <a class="screenshot-link" href="/screenshots/${encodeURIComponent(f.image)}" target="_blank" rel="noopener noreferrer" aria-label="查看第 ${f.index + 1} 张原始截图">
          <img class="detail-image" src="/screenshots/${encodeURIComponent(f.image)}" alt="${esc(r.title)}的第 ${f.index + 1} 张截图" loading="lazy">
        </a>${i ? '</details>' : ''}`).join('')}
    </section>` : '';
  const text = r.frames.length || r.kind === 'capture'
    ? `<details class="detail-section ocr-section" id="ocr-content" ${keepOCROpen ? 'open' : ''}><summary>OCR 识别文字 <span class="optional">${r.text.length.toLocaleString()} 字</span></summary><p class="small-help">自动识别可能存在错字，阅读请以截图为准。</p><div class="detail-text">${esc(r.text)}</div></details>`
    : `<section class="detail-section"><h3>原始文字</h3><div class="detail-text">${esc(r.text)}</div></section>`;
  $('#detail-content').innerHTML = `
    <div class="dialog-top"><span class="eyebrow">A THOUGHT, KEPT${r.kind === 'demo' ? ' · 示例内容' : ''}</span><button class="icon-button" data-close aria-label="关闭">×</button></div>
    <h2 class="detail-title">${esc(r.title)}</h2>
    <div class="detail-meta"><span>${esc(r.app)}</span><span>${date(r.created)} ${time(r.created)}</span><span>${r.frames.length ? `${r.frames.length} 张截图` : `${r.text.length.toLocaleString()} 字`}</span></div>
    ${r.error ? `<p class="error-text">${esc(r.error)}</p>` : ''}
    ${screenshots}
    <section class="detail-section"><h3>归属话题 <span class="optional">点击可手动调整</span></h3><div class="label-controls">${state.topics.map(t => `<button class="label-control ${esc(t.color)} ${r.labels.includes(t.id) ? 'selected' : ''}" data-label="${t.id}" aria-pressed="${r.labels.includes(t.id)}">${r.labels.includes(t.id) ? '✓ ' : '＋ '}${esc(t.name)} ${r.manual[t.id] !== undefined ? '· 手动' : r.scores[t.id] !== undefined ? `· ${Math.round(r.scores[t.id] * 100)}%` : ''}</button>`).join('') || '<button class="subtle" data-action="add-topic">＋ 添加话题</button>'}</div><p class="small-help">百分比表示 Jev 判断“符合该话题”的概率。原型自动归类阈值为 75%。</p></section>
    ${text}
    <div class="detail-actions">${r.url ? `<a class="source-link" href="${esc(r.url)}" target="_blank" rel="noopener noreferrer">打开来源 ↗</a>` : '<span class="small-help">原文已保存在本地</span>'}<button class="danger" data-delete-record="${r.id}">删除这份资料</button></div>`;
  if (!$('#detail-dialog').open) { $('#detail-dialog').showModal(); $('#detail-dialog').scrollTop = 0; }
}

async function refresh() {
  try {
    const response = await fetch('/api/state');
    if (!response.ok) throw new Error('服务连接失败');
    const next = await response.json();
    const key = JSON.stringify(next);
    const oldSelected = state.records.find(r => r.id === selected);
    const nextSelected = next.records.find(r => r.id === selected);
    state = next;
    if (key !== snapshot) { snapshot = key; render(); }
    if ($('#detail-dialog').open && nextSelected && JSON.stringify(oldSelected) !== JSON.stringify(nextSelected)) {
      const scroll = $('#detail-dialog').scrollTop;
      showDetail(selected);
      $('#detail-dialog').scrollTop = scroll;
    }
  } catch { snapshot = ''; $('#error-banner').hidden = false; $('#error-banner').textContent = '本地服务连接中断，请确认 npm start 仍在运行。'; }
}
document.addEventListener('click', event => {
  const close = event.target.closest('[data-close]'); if (close) close.closest('dialog').close();
  const nav = event.target.closest('[data-view]'); if (nav) { view = nav.dataset.view; render(); }
  const card = event.target.closest('[data-record]'); if (card) showDetail(card.dataset.record);
  const action = event.target.closest('[data-action]')?.dataset.action;
  if (action === 'add-topic') showTopic();
  if (action === 'import') $('#import-dialog').showModal();
  if (action === 'retry') safe(async () => { await api('/api/retry'); toast('已重新加入归类队列'); });
  const label = event.target.closest('[data-label]');
  if (label) safe(async () => { const r = state.records.find(r => r.id === selected); await api(`/api/records/${selected}`, { topicId: label.dataset.label, matched: !r.labels.includes(label.dataset.label) }, 'PATCH'); showDetail(selected); });
  const deleteRecord = event.target.closest('[data-delete-record]');
  if (deleteRecord && confirm('删除这份资料及其截图？此操作不能撤销。')) safe(async () => { await api(`/api/records/${deleteRecord.dataset.deleteRecord}`, {}, 'DELETE'); $('#detail-dialog').close(); toast('资料已删除'); });
  const deleteTopic = event.target.closest('[data-delete-topic]');
  if (deleteTopic && confirm('移除这个话题？已收集的资料会保留。')) safe(async () => { await api(`/api/topics/${deleteTopic.dataset.deleteTopic}`, {}, 'DELETE'); toast('话题已移除'); });
});
$('#add-topic').onclick = showTopic; $('#add-topic-small').onclick = showTopic;
$('#import-button').onclick = () => $('#import-dialog').showModal();
$('#search').oninput = event => { search = event.target.value; render(); };
document.addEventListener('keydown', event => { if ((event.metaKey || event.ctrlKey) && event.key === 'k') { event.preventDefault(); $('#search').focus(); } });
$('#capture-button').onclick = () => safe(async () => {
  if (['running', 'starting'].includes(state.status.capture)) await api('/api/capture/stop');
  else if (!state.topics.length) { toast('先创建一个话题，让 Jev 知道你在关注什么'); showTopic(); }
  else $('#capture-dialog').showModal();
});
$('#confirm-capture').onclick = () => safe(async () => { await api('/api/capture/start'); $('#capture-dialog').close(); });
$('#demo-button').onclick = () => safe(async () => {
  const button = $('#demo-button'); button.disabled = true; button.textContent = '正在加入示例…';
  try { await api('/api/demo'); toast('已加入 4 份示例内容，正在调用真实 Jev 归类'); }
  finally { button.disabled = false; button.textContent = '体验示例 ↗'; }
});
for (const [formId, endpoint, dialogId] of [['topic-form', '/api/topics', 'topic-dialog'], ['import-form', '/api/import', 'import-dialog']]) {
  $(`#${formId}`).onsubmit = event => { event.preventDefault(); safe(async () => {
    const form = event.target, button = form.querySelector('[type=submit]'); button.disabled = true;
    try { const result = await api(endpoint, Object.fromEntries(new FormData(form))); $(`#${dialogId}`).close(); form.reset(); toast(result.duplicate ? '这段内容已经收集过了' : formId === 'topic-form' ? '话题已创建，已有资料也会重新归类' : '已收集，Jev 正在归类'); }
    finally { button.disabled = false; }
  }); };
}
await refresh(); setInterval(refresh, 1800);
