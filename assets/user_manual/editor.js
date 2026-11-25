/* Local authoring for the Windows manual. Only the host can pick or write files. */
const ManualAuthor = (() => {
  'use strict';
  const byId = (id) => document.getElementById(id);
  const bridge = window.chrome?.webview;
  const pending = new Map();
  const labels = {
    p: '段落', h2: '小节标题', h3: '子标题', ul: '项目列表', ol: '步骤列表',
    callout: '提示框', table: '表格', cards: '页面链接', widget: '交互演示',
    image: '图片 / GIF', video: '视频',
  };
  const demos = { 'topbar-demo': '导航栏开关', 'proxy-route': '代理线路', 'semantic-chips': '语义分块' };
  let api, draft, original, busy = false;
  if (bridge) {
    bridge.addEventListener('message', ({ data }) => {
      const wait = pending.get(data?.id);
      if (!wait) return;
      pending.delete(data.id);
      if (data.error) wait.reject(new Error(data.error));
      else wait.resolve(data.value);
    });
  }
  function request(method, data = {}) {
    if (!bridge) return Promise.reject(new Error('请在 Plana 客户端内打开使用手册。'));
    const id = crypto.randomUUID();
    return new Promise((resolve, reject) => {
      pending.set(id, { resolve, reject });
      try { bridge.postMessage({ id, method, ...data }); }
      catch (e) { pending.delete(id); reject(e); }
    });
  }
  function node(tag, text, className) {
    const item = document.createElement(tag);
    if (text != null) item.textContent = text;
    if (className) item.className = className;
    return item;
  }
  function button(label, action, title = label) {
    const btn = node('button', label);
    btn.type = 'button';
    btn.title = title;
    btn.setAttribute('aria-label', title);
    btn.addEventListener('click', action);
    return btn;
  }
  function select(options, value, update) {
    const field = node('select');
    for (const [id, title] of Object.entries(options)) field.add(new Option(title, id));
    field.value = value;
    field.addEventListener('change', () => update(field.value));
    return field;
  }
  function field(label, control) {
    const wrap = node('label', null, 'editor-field');
    wrap.append(node('span', label), control);
    return wrap;
  }
  function textField(label, value, update, multiline = false) {
    const input = node(multiline ? 'textarea' : 'input');
    input.value = value || '';
    if (multiline) input.rows = 3;
    input.addEventListener('input', () => update(input.value));
    return field(label, input);
  }
  function figure(block) {
    const wrap = node('figure', null, 'manual-media');
    const movie = block.type === 'video';
    const asset = node(movie ? 'video' : 'img');
    if (movie) {
      asset.controls = true;
      asset.preload = 'metadata';
      asset.playsInline = true;
      asset.setAttribute('aria-label', block.caption || '教学视频');
    } else {
      asset.alt = block.caption || '操作配图';
      asset.loading = 'lazy';
    }
    asset.addEventListener('error', () => {
      const msg = movie ? '视频暂时无法播放，请检查素材或视频编码。' : '图片暂时无法加载，请检查素材文件。';
      wrap.replaceChildren(node('p', msg));
    }, { once: true });
    asset.src = 'https://media.plana.invalid/' + encodeURIComponent(block.file);
    wrap.append(asset);
    if (block.caption) wrap.append(node('figcaption', block.caption));
    return wrap;
  }
  function fresh(type) {
    switch (type) {
      case 'h2': case 'h3': return { type, id: 'h-' + crypto.randomUUID(), text: '' };
      case 'ul': case 'ol': return { type, items: [] };
      case 'table': return { type, headers: ['项目', '说明'], rows: [['', '']] };
      case 'callout': return { type, tone: 'info', title: '提示', text: '' };
      case 'cards': return { type, items: [] };
      case 'widget': return { type, kind: 'semantic-chips' };
      default: return { type, text: '' };
    }
  }
  function editorBody(block, area) {
    const bind = (key) => (value) => { block[key] = value; };
    switch (block.type) {
      case 'h2': case 'h3': case 'p':
        area.append(textField(block.type === 'p' ? '正文' : '标题文字', block.text, bind('text'), block.type === 'p'));
        break;
      case 'ul': case 'ol':
        area.append(textField('每行一项', block.items.join('\n'),
          (value) => { block.items = value.split('\n'); }, true));
        break;
      case 'callout':
        area.append(field('样式', select({ info: '说明', tip: '建议', warn: '提醒' }, block.tone, bind('tone'))),
          textField('标题', block.title, bind('title')), textField('说明', block.text, bind('text'), true));
        break;
      case 'table': {
        const grid = node('div', null, 'editor-grid');
        const draw = () => {
          grid.replaceChildren();
          [block.headers, ...block.rows].forEach((row, i) => {
            const line = node('div', null, 'editor-grid-row');
            block.headers.forEach((_, j) => line.append(textField(
              (i === 0 ? '表头' : '第 ' + i + ' 行') + ' · ' + (j + 1), row[j], (v) => { row[j] = v; })));
            if (i) line.append(button('移除行', () => { block.rows.splice(i - 1, 1); draw(); }));
            grid.append(line);
          });
        };
        draw();
        area.append(grid, button('加一行', () => { block.rows.push(block.headers.map(() => '')); draw(); }),
          button('加一列', () => { block.headers.push(''); block.rows.forEach((r) => r.push('')); draw(); }));
        if (block.headers.length > 1) area.append(button('移除末列', () => {
          if (block.headers.length < 2) return;
          block.headers.pop(); block.rows.forEach((r) => r.pop()); draw();
        }));
        break;
      }
      case 'cards': {
        const links = node('div');
        function drawLinks() {
          const pages = new Map(api.pages().map((p) => [p.id, p]));
          pages.set(draft.id, draft);
          const pageNames = Object.fromEntries(Array.from(pages, ([id, page]) => [id, page.title || '本页']));
          links.replaceChildren();
          block.items.forEach((item, i) => {
            const row = node('div', null, 'editor-link');
            const dest = api.cardDestination(item);
            const sections = (pages.get(item.target)?.blocks || []).filter((b) => b.type === 'h2' || b.type === 'h3');
            const titles = { '': '页首', ...Object.fromEntries(sections.map((b) => [b.id, (b.type === 'h3' ? '　' : '') + (b.text || '未命名小节')])) };
            if (dest.headingId && !Object.hasOwn(titles, dest.headingId)) titles[dest.headingId] = '原小节已移除';
            const changeTarget = (target, heading) => {
              if (item.title.trim() === '#' + item.target + '/' + dest.headingId) item.title = '';
              item.target = target;
              item.heading = heading;
              drawLinks();
            };
            row.append(field('目标页面', select(pageNames, item.target, (v) => changeTarget(v, ''))),
              field('目标小节', select(titles, dest.headingId, (v) => changeTarget(item.target, v))),
              textField('链接标题', item.title, (v) => { item.heading ??= dest.headingId; item.title = v; }),
              textField('说明', item.desc, (v) => { item.desc = v; }),
              button('移除链接', () => { block.items.splice(i, 1); drawLinks(); }));
            links.append(row);
          });
        }
        drawLinks();
        area.append(links, button('添加链接', () => {
          block.items.push({ target: api.pages()[0].id, heading: '', title: '', desc: '' }); drawLinks();
        }));
        break;
      }
      case 'widget':
        area.append(field('演示内容', select(demos, block.kind, bind('kind'))));
        break;
      case 'image': case 'video':
        area.append(figure(block), textField('图片说明 / 视频标题', block.caption, bind('caption')),
          button('替换素材', () => pickMedia(block)));
        break;
    }
  }
  function drawBlocks(focusIndex) {
    const container = byId('editBlocks');
    container.replaceChildren();
    draft.blocks.forEach((block, i) => {
      const row = node('section', null, 'editor-block');
      const header = node('header');
      const title = node('strong', labels[block.type]);
      const move = (offset) => {
        const other = i + offset;
        [draft.blocks[i], draft.blocks[other]] = [draft.blocks[other], draft.blocks[i]];
        drawBlocks(other);
      };
      const up = button('↑', () => move(-1), '上移内容块');
      const down = button('↓', () => move(1), '下移内容块');
      up.disabled = i === 0;
      down.disabled = i === draft.blocks.length - 1;
      header.append(title, up, down, button('移除', () => { draft.blocks.splice(i, 1); drawBlocks(i); }));
      const body = node('div', null, 'editor-block-body');
      editorBody(block, body);
      row.append(header, body);
      container.append(row);
    });
    if (focusIndex != null) {
      const row = container.children[focusIndex];
      row?.scrollIntoView({ block: 'nearest' });
      row?.querySelector('input, textarea, select')?.focus({ preventScroll: true });
    }
  }
  function openEditor(newPage) {
    const { page, section } = api.current();
    draft = newPage
      ? { section: section.id, id: 'page-' + crypto.randomUUID(), title: '', summary: '', blocks: [fresh('p')] }
      : { ...structuredClone(page), section: section.id };
    original = JSON.stringify(draft);
    byId('editorHeading').textContent = (newPage ? '新增页面' : '编辑本页') + ' · ' + section.title;
    byId('editorStatus').textContent = '';
    byId('editTitle').value = draft.title;
    byId('editSummary').value = draft.summary;
    drawBlocks();
    byId('articleEditor').showModal();
    byId('editTitle').focus();
  }
  function setBusy(value, message = '') {
    busy = value;
    byId('editorForm').inert = value;
    byId('editorStatus').textContent = message;
  }
  async function pickMedia(replacing) {
    if (busy) return;
    setBusy(true, '正在读取素材…');
    try {
      const media = await request('media');
      if (!media) { setBusy(false); return; }
      const index = replacing ? draft.blocks.indexOf(replacing) : draft.blocks.length;
      if (replacing) media.caption = replacing.caption;
      draft.blocks.splice(index, replacing ? 1 : 0, media);
      setBusy(false);
      drawBlocks(index);
    } catch (e) { setBusy(false, e.message); }
  }
  async function finish() {
    byId('articleEditor').close();
    byId('editBlocks').replaceChildren();
    draft = null;
    try { await request('discard'); } catch (e) { api.toast(e.message); }
  }
  async function cancel() {
    if (busy) return;
    if (JSON.stringify(draft) !== original && !window.confirm('放弃本次未保存的修改？')) return;
    await finish();
  }
  async function save(e) {
    e.preventDefault();
    if (busy || !draft) return;
    setBusy(true, '正在保存…');
    try {
      const saved = await request('save', { page: draft });
      await finish();
      api.savePage(saved);
      api.toast('已保存到本机手册');
      setBusy(false);
    } catch (err) { setBusy(false, err.message); }
  }
  async function init(actions) {
    api = actions;
    if (!bridge) { byId('backToAboutBtn').hidden = true; return []; }
    const mode = byId('devMode');
    const warn = (message) => {
      byId('manualWarning').textContent = message;
      byId('manualWarning').hidden = false;
    };
    byId('editTitle').addEventListener('input', (e) => { draft.title = e.target.value; });
    byId('editSummary').addEventListener('input', (e) => { draft.summary = e.target.value; });
    byId('editArticle').addEventListener('click', () => openEditor(false));
    byId('newArticle').addEventListener('click', () => openEditor(true));
    byId('openManualFolder').addEventListener('click', () => request('folder').catch((e) => api.toast(e.message)));
    mode.addEventListener('click', () => {
      const enabled = mode.getAttribute('aria-pressed') !== 'true';
      mode.setAttribute('aria-pressed', String(enabled));
      byId('authorTools').hidden = !enabled;
    });
    for (const [type, label] of Object.entries(labels)) {
      if (type !== 'image' && type !== 'video') byId('insertType').add(new Option(label, type));
    }
    byId('insertBlock').addEventListener('click', () => {
      draft.blocks.push(fresh(byId('insertType').value)); drawBlocks(draft.blocks.length - 1);
    });
    byId('insertMedia').addEventListener('click', () => pickMedia());
    byId('articleEditor').addEventListener('cancel', (e) => { e.preventDefault(); cancel(); });
    for (const btn of document.querySelectorAll('[data-action="cancel"]')) btn.addEventListener('click', cancel);
    byId('editorForm').addEventListener('submit', save);
    byId('articleEditor').addEventListener('keydown', (e) => {
      if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 's') {
        e.preventDefault(); byId('editorForm').requestSubmit();
      }
    });
    try {
      const local = await request('load');
      if (local.version) document.querySelector('.obs-version').textContent = 'Plana Windows · ' + local.version;
      mode.hidden = false;
      if (local.unreadable.length) warn('以下本地页面无法读取，请检查手册文件夹：' + local.unreadable.join('、'));
      return local.pages;
    } catch (e) {
      warn('本地手册暂时无法读取。' + e.message);
      return [];
    }
  }
  return { init, figure, request };
})();
