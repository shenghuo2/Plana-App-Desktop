/* Plana Windows · 使用手册交互逻辑
 * 涵盖：Obsidian 折叠目录树与实时筛选、Linear 右侧滑动大纲、
 * Ctrl+K 全文检索、文内 Plana 活交互演示、复制本页 Markdown 及全屏入口切换。
 */
(function initPlanaManualApp() {
  'use strict';

  const DATA = window.PLANA_MANUAL_DATA;
  const flatPages = [];
  const pageById = new Map();
  const sectionByPageId = new Map();

  function indexPages() {
    flatPages.length = 0;
    pageById.clear();
    sectionByPageId.clear();
    for (const section of DATA.sections) {
      for (const page of section.pages) {
        flatPages.push({ section, page });
        pageById.set(page.id, page);
        sectionByPageId.set(page.id, section);
      }
    }
  }
  indexPages();

  const state = {
    currentPageId: flatPages[0].page.id,
    openFolders: new Set(DATA.sections.filter((s) => s.defaultOpen).map((s) => s.id)),
    sidebarFilter: '',
    activeHeadingId: null,
    demoTopbarAi: true,
    demoTopbarTools: true,
    demoProxyMode: 'local', // 'local' | 'relay' | 'direct'
    demoActiveChip: 0,
    searchModalOpen: false,
    searchSelectedIdx: 0,
    searchHits: [],
  };

  const el = {
    html: document.documentElement,
    manualView: document.getElementById('manualView'),
    backToAboutBtn: document.getElementById('backToAboutBtn'),
    brandHomeLink: document.getElementById('brandHomeLink'),
    bcSection: document.getElementById('bcSection'),
    bcPage: document.getElementById('bcPage'),
    obsSidebar: document.getElementById('obsSidebar'),
    drawerScrim: document.getElementById('drawerScrim'),
    mobileMenuBtn: document.getElementById('mobileMenuBtn'),
    sidebarFilterInput: document.getElementById('sidebarFilterInput'),
    sidebarFilterClear: document.getElementById('sidebarFilterClear'),
    obsTree: document.getElementById('obsTree'),
    toggleAllFoldersBtn: document.getElementById('toggleAllFoldersBtn'),
    docScroll: document.getElementById('docScroll'),
    docLayout: document.querySelector('.doc-layout'),
    docCategoryTag: document.getElementById('docCategoryTag'),
    docVersionTag: document.getElementById('docVersionTag'),
    docTitle: document.getElementById('docTitle'),
    docLead: document.getElementById('docLead'),
    docContent: document.getElementById('docContent'),
    docPager: document.getElementById('docPager'),
    linToc: document.getElementById('linToc'),
    linTocList: document.getElementById('linTocList'),
    linTocIndicator: document.getElementById('linTocIndicator'),
    openSearchBtn: document.getElementById('openSearchBtn'),
    copyPageBtn: document.getElementById('copyPageBtn'),
    copyPageLabel: document.getElementById('copyPageLabel'),
    themeToggle: document.getElementById('themeToggle'),
    searchModal: document.getElementById('searchModal'),
    modalSearchInput: document.getElementById('modalSearchInput'),
    modalSearchResults: document.getElementById('modalSearchResults'),
    toast: document.getElementById('toast'),
  };

  let scrollSpyRaf = 0;
  let pinnedHeading = null;
  let toastTimer = 0;
  let copyTimer = 0;

  function escapeHtml(str) {
    return String(str)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }

  function showToast(msg) {
    clearTimeout(toastTimer);
    el.toast.textContent = msg;
    el.toast.hidden = false;
    toastTimer = setTimeout(() => {
      el.toast.hidden = true;
    }, 2400);
  }

  function copyText(text) {
    if (navigator.clipboard && navigator.clipboard.writeText) {
      return navigator.clipboard.writeText(text).catch(() => fallbackCopy(text));
    }
    return Promise.resolve(fallbackCopy(text));
  }

  function fallbackCopy(text) {
    const ta = document.createElement('textarea');
    ta.value = text;
    ta.style.position = 'fixed';
    ta.style.opacity = '0';
    document.body.appendChild(ta);
    ta.select();
    try { document.execCommand('copy'); } catch {}
    ta.remove();
  }

  /* ==================== Obsidian 左侧目录树 ==================== */
  function syncToggleAllLabel() {
    const allOpen = DATA.sections.every((s) => state.openFolders.has(s.id));
    el.toggleAllFoldersBtn.textContent = allOpen ? '全部收起' : '全部展开';
  }

  function renderSidebarTree() {
    const q = state.sidebarFilter.trim().toLowerCase();
    el.obsTree.innerHTML = '';
    let matchedAny = false;

    for (const sec of DATA.sections) {
      const secMatches = q && sec.title.toLowerCase().includes(q);
      const visiblePages = q
        ? sec.pages.filter((p) => {
            if (secMatches) return true;
            if (p.title.toLowerCase().includes(q) || p.summary.toLowerCase().includes(q)) return true;
            return p.blocks.some((b) => (b.text && b.text.toLowerCase().includes(q)));
          })
        : sec.pages;

      if (visiblePages.length === 0) continue;
      matchedAny = true;

      const hasActive = visiblePages.some((p) => p.id === state.currentPageId);
      const isOpen = q ? true : state.openFolders.has(sec.id);

      const folder = document.createElement('div');
      folder.className = `obs-folder${isOpen ? ' is-open' : ''}${hasActive ? ' has-active' : ''}`;
      folder.dataset.sectionId = sec.id;

      const folderBtn = document.createElement('button');
      folderBtn.type = 'button';
      folderBtn.className = 'obs-folder-btn';
      folderBtn.setAttribute('aria-expanded', String(isOpen));
      folderBtn.innerHTML = `
        <svg class="obs-chevron" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="m9 18 6-6-6-6"/></svg>
        <span class="obs-folder-title">${escapeHtml(sec.title)}</span>
      `;
      folderBtn.addEventListener('click', () => {
        if (state.openFolders.has(sec.id)) {
          state.openFolders.delete(sec.id);
        } else {
          state.openFolders.add(sec.id);
        }
        renderSidebarTree();
      });

      const children = document.createElement('div');
      children.className = 'obs-children';
      for (const page of visiblePages) {
        const btn = document.createElement('button');
        btn.type = 'button';
        btn.className = `obs-page-link${page.id === state.currentPageId ? ' is-active' : ''}`;
        btn.textContent = page.title;
        if (page.id === state.currentPageId) {
          btn.setAttribute('aria-current', 'page');
        }
        btn.addEventListener('click', () => {
          navigateToPage(page.id);
          closeDrawer();
        });
        children.appendChild(btn);
      }

      folder.appendChild(folderBtn);
      folder.appendChild(children);
      el.obsTree.appendChild(folder);
    }

    if (!matchedAny) {
      const empty = document.createElement('div');
      empty.className = 'obs-empty';
      empty.textContent = '没有找到匹配的文档章节';
      el.obsTree.appendChild(empty);
    }

    syncToggleAllLabel();
  }

  /* ==================== 文内活 UI 演示片段 ==================== */
  function buildWidget(kind) {
    const frame = document.createElement('div');
    frame.className = 'ui-demo-frame';

    if (kind === 'topbar-demo') {
      const renderTopbar = () => {
        const aiOn = state.demoTopbarAi;
        const toolsOn = state.demoTopbarTools;
        frame.innerHTML = `
          <div class="ui-demo-topbar" aria-label="Plana 顶栏显示效果模拟">
            <span class="ui-demo-brand">Plana</span>
            <span class="ui-demo-tab is-active">创作</span>
            <span class="ui-demo-tab">图库</span>
            ${aiOn ? '<span class="ui-demo-tab is-opt">AI 助手</span>' : ''}
            <span class="ui-demo-tab">灵感</span>
            ${toolsOn ? '<span class="ui-demo-tab is-opt">工具箱</span>' : ''}
            <span class="ui-demo-tab">我的</span>
          </div>
          <div class="ui-demo-switches">
            <button type="button" class="demo-switch-pill${aiOn ? ' is-on' : ''}" data-demo-toggle="ai" role="switch" aria-checked="${aiOn}">
              <span class="switch-track"><span class="switch-knob"></span></span>
              <span>顶栏显示 AI 助手</span>
            </button>
            <button type="button" class="demo-switch-pill${toolsOn ? ' is-on' : ''}" data-demo-toggle="tools" role="switch" aria-checked="${toolsOn}">
              <span class="switch-track"><span class="switch-knob"></span></span>
              <span>顶栏显示工具箱</span>
            </button>
          </div>
          <div class="ui-demo-note">
            AI 助手位于「${aiOn ? '顶部导航栏独立页 + 创作右侧栏' : '创作界面右侧边栏'}」，工具箱位于「${toolsOn ? '顶部导航栏独立页' : '我的 → 工具箱'}」。
          </div>
        `;
        frame.querySelector('[data-demo-toggle="ai"]').addEventListener('click', () => {
          state.demoTopbarAi = !state.demoTopbarAi;
          renderTopbar();
        });
        frame.querySelector('[data-demo-toggle="tools"]').addEventListener('click', () => {
          state.demoTopbarTools = !state.demoTopbarTools;
          renderTopbar();
        });
      };
      renderTopbar();
      return frame;
    }

    if (kind === 'proxy-route') {
      const routes = {
        local: {
          nodes: ['Plana', '本机代理 (127.0.0.1:7897)', 'NovelAI'],
          note: '适用所有联网请求（NovelAI、Bot 后端、AI 助手与资源下载）；开启本机代理时建议关闭云端转发。',
        },
        relay: {
          nodes: ['Plana', 'Plana 云端转发', 'NovelAI'],
          note: '仅作用于官方 NovelAI 接口，不经过 Clash，也不影响第三方接口与 Bot 后端。',
        },
        direct: {
          nodes: ['Plana', '直连 / 系统 TUN', 'NovelAI'],
          note: '若系统已启用 Clash TUN 模式接管，此处按应用设置仍显示直连，属正常状态。',
        },
      };
      const renderProxy = () => {
        const cur = routes[state.demoProxyMode];
        frame.innerHTML = `
          <div class="route-diagram">
            ${cur.nodes
              .map((n, idx) => `<span class="route-node${idx === 1 ? ' is-accent' : ''}">${escapeHtml(n)}</span>`)
              .join('<span class="route-arrow" aria-hidden="true">→</span>')}
          </div>
          <div class="ui-demo-switches">
            <button type="button" class="demo-switch-pill${state.demoProxyMode === 'local' ? ' is-on' : ''}" data-route="local">本机代理</button>
            <button type="button" class="demo-switch-pill${state.demoProxyMode === 'relay' ? ' is-on' : ''}" data-route="relay">云端转发</button>
            <button type="button" class="demo-switch-pill${state.demoProxyMode === 'direct' ? ' is-on' : ''}" data-route="direct">直连 / TUN</button>
          </div>
          <div class="ui-demo-note">${escapeHtml(cur.note)}</div>
        `;
        frame.querySelectorAll('[data-route]').forEach((btn) => {
          btn.addEventListener('click', () => {
            state.demoProxyMode = btn.dataset.route;
            renderProxy();
          });
        });
      };
      renderProxy();
      return frame;
    }

    if (kind === 'semantic-chips') {
      const chips = [
        { label: '# 画风 · D33 · Brush', tags: '__ARTIST_D33__, delicate ink lineart, soft cel shading,' },
        { label: '# 角色 · 樱粉女仆 · Shirt', tags: '1girl, solo, long pink hair, classic frilled maid dress, gentle smile, looking at viewer,' },
        { label: '# 场景 · 午后窗边低视角 · Sun', tags: 'medium shot, low angle view, sunlit Victorian parlor, warm golden light streaming through lace curtains,' },
      ];
      const renderChips = () => {
        const active = chips[state.demoActiveChip] || chips[0];
        frame.innerHTML = `
          <div class="chip-demo-list">
            ${chips
              .map(
                (c, idx) =>
                  `<button type="button" class="semantic-chip-demo" data-chip="${idx}" style="${idx === state.demoActiveChip ? 'outline: 2px solid var(--primary); outline-offset: 2px;' : 'opacity: .84;'}">${escapeHtml(c.label)}</button>`
              )
              .join('')}
          </div>
          <div class="ui-demo-note">点击上方芯片预览底层英文词：<code>${escapeHtml(active.tags)}</code></div>
        `;
        frame.querySelectorAll('[data-chip]').forEach((btn) => {
          btn.addEventListener('click', () => {
            state.demoActiveChip = Number(btn.dataset.chip);
            renderChips();
          });
        });
      };
      renderChips();
      return frame;
    }

    return frame;
  }

  /* ==================== 中间正文渲染 + Linear 右侧大纲 ==================== */
  function cardDestination(item) {
    const page = pageById.get(item.target);
    // The original editor only offered a page picker. Authors pasted the copied
    // section link into its title field, e.g. "#first-setup/setup-proxy".
    const copied = /^#([a-z][a-z0-9-]*)\/([a-z][a-z0-9-]*)$/.exec(item.title.trim());
    const legacy = copied && copied[1] === item.target;
    const headingId = item.heading ?? (legacy ? copied[2] : '');
    const heading = page?.blocks.find((b) => (b.type === 'h2' || b.type === 'h3') && b.id === headingId);
    const title = (!item.title.trim() || legacy) ? (heading?.text || page?.title || item.title) : item.title;
    return { pageId: item.target, headingId, title };
  }

  function pageHash(pageId, headingId) {
    return '#' + pageId + (headingId ? '/' + headingId : '');
  }

  function renderArticle(pageId, targetHeadingId) {
    pinnedHeading = null;
    el.docScroll.style.removeProperty('--anchor-room');
    const page = pageById.get(pageId) || flatPages[0].page;
    const sec = sectionByPageId.get(page.id);
    state.currentPageId = page.id;
    state.openFolders.add(sec.id);

    el.bcSection.textContent = sec.title;
    el.bcPage.textContent = page.title;
    el.docCategoryTag.textContent = sec.title;
    el.docVersionTag.textContent = /^\d{4}-\d{2}-\d{2}$/.test(page.updated || '') ? page.updated : '使用手册';
    el.docTitle.textContent = page.title;
    el.docLead.textContent = page.summary;
    document.title = `${page.title} · Plana 使用手册`;

    el.docContent.innerHTML = '';
    const headings = [];

    for (const block of page.blocks) {
      if (block.type === 'h2' || block.type === 'h3') {
        const h = document.createElement(block.type);
        h.id = block.id;
        h.dataset.tocHeading = '1';
        const textSpan = document.createElement('span');
        textSpan.textContent = block.text;
        const anchor = document.createElement('button');
        anchor.type = 'button';
        anchor.className = 'heading-anchor';
        anchor.textContent = '#';
        anchor.title = '复制小节链接';
        anchor.addEventListener('click', () => {
          const hash = pageHash(page.id, block.id);
          copyText(hash).then(() => showToast(`已复制定位链接 ${hash}`));
        });
        h.appendChild(textSpan);
        h.appendChild(anchor);
        el.docContent.appendChild(h);
        headings.push({ id: block.id, text: block.text, level: block.type === 'h2' ? 2 : 3, node: h });
      } else if (block.type === 'p') {
        const p = document.createElement('p');
        p.textContent = block.text;
        el.docContent.appendChild(p);
      } else if (block.type === 'ol' || block.type === 'ul') {
        const list = document.createElement(block.type);
        for (const item of block.items) {
          const li = document.createElement('li');
          li.textContent = item;
          list.appendChild(li);
        }
        el.docContent.appendChild(list);
      } else if (block.type === 'callout') {
        const box = document.createElement('div');
        box.className = `doc-callout is-${block.tone || 'info'}`;
        box.innerHTML = `
          <div class="doc-callout-title">${escapeHtml(block.title)}</div>
          <p>${escapeHtml(block.text)}</p>
        `;
        el.docContent.appendChild(box);
      } else if (block.type === 'table') {
        const wrap = document.createElement('div');
        wrap.className = 'doc-table-wrap';
        const tbl = document.createElement('table');
        tbl.className = 'doc-table';
        const thead = `<thead><tr>${block.headers.map((th) => `<th>${escapeHtml(th)}</th>`).join('')}</tr></thead>`;
        const tbody = `<tbody>${block.rows
          .map((row) => `<tr>${row.map((td) => `<td>${escapeHtml(td)}</td>`).join('')}</tr>`)
          .join('')}</tbody>`;
        tbl.innerHTML = thead + tbody;
        wrap.appendChild(tbl);
        el.docContent.appendChild(wrap);
      } else if (block.type === 'cards') {
        const grid = document.createElement('div');
        grid.className = 'doc-cards';
        for (const item of block.items) {
          const dest = cardDestination(item);
          const card = document.createElement('a');
          card.href = pageHash(dest.pageId, dest.headingId);
          card.className = 'doc-card';
          card.innerHTML = `
            <div class="doc-card-head">
              <span class="doc-card-title">${escapeHtml(dest.title)}</span>
              <span class="doc-card-arrow" aria-hidden="true">→</span>
            </div>
            <span class="doc-card-desc">${escapeHtml(item.desc)}</span>
          `;
          card.addEventListener('click', (event) => {
            event.preventDefault();
            navigateToPage(dest.pageId, dest.headingId);
          });
          grid.appendChild(card);
        }
        el.docContent.appendChild(grid);
      } else if (block.type === 'image' || block.type === 'video') {
        el.docContent.appendChild(ManualAuthor.figure(block));
      } else if (block.type === 'widget') {
        el.docContent.appendChild(buildWidget(block.kind));
      }
    }

    renderPager(page.id);
    renderLinearToc(headings);
    renderSidebarTree();

    if (targetHeadingId && scrollToHeading(targetHeadingId, false)) return;
    if (targetHeadingId) showToast('目标小节已移除，已打开该页。');

    el.docScroll.scrollTo({ top: 0, behavior: 'instant' });
    if (headings.length > 0) {
      setActiveTocHeading(headings[0].id);
    } else {
      el.linTocIndicator.classList.remove('is-visible');
    }
  }

  function renderPager(pageId) {
    const idx = flatPages.findIndex((item) => item.page.id === pageId);
    const prev = idx > 0 ? flatPages[idx - 1] : null;
    const next = idx < flatPages.length - 1 ? flatPages[idx + 1] : null;

    el.docPager.innerHTML = '';
    if (prev) {
      const btn = document.createElement('button');
      btn.type = 'button';
      btn.className = 'pager-card is-prev';
      btn.innerHTML = `<span class="pager-dir">← 上一篇 · ${escapeHtml(prev.section.title)}</span><span class="pager-title">${escapeHtml(prev.page.title)}</span>`;
      btn.addEventListener('click', () => navigateToPage(prev.page.id));
      el.docPager.appendChild(btn);
    }
    if (next) {
      const btn = document.createElement('button');
      btn.type = 'button';
      btn.className = 'pager-card is-next';
      btn.innerHTML = `<span class="pager-dir">${escapeHtml(next.section.title)} · 下一篇 →</span><span class="pager-title">${escapeHtml(next.page.title)}</span>`;
      btn.addEventListener('click', () => navigateToPage(next.page.id));
      el.docPager.appendChild(btn);
    }
  }

  /* ==================== Linear 右侧大纲 + 2px 平滑滑动高亮条 ==================== */
  let currentHeadings = [];

  function renderLinearToc(headings) {
    currentHeadings = headings;
    el.linTocList.innerHTML = '';

    for (const h of headings) {
      const li = document.createElement('li');
      const btn = document.createElement('button');
      btn.type = 'button';
      btn.className = `lin-toc-link${h.level === 3 ? ' is-h3' : ''}`;
      btn.dataset.headingId = h.id;
      btn.textContent = h.text;
      btn.addEventListener('click', () => {
        scrollToHeading(h.id, true);
        window.history.replaceState(null, '', pageHash(state.currentPageId, h.id));
      });
      li.appendChild(btn);
      el.linTocList.appendChild(li);
    }
  }

  function setActiveTocHeading(headingId) {
    state.activeHeadingId = headingId;
    const links = el.linTocList.querySelectorAll('.lin-toc-link');
    let activeLink = null;
    for (const link of links) {
      const on = link.dataset.headingId === headingId;
      link.classList.toggle('is-active', on);
      if (on) activeLink = link;
    }

    if (!activeLink) {
      el.linTocIndicator.classList.remove('is-visible');
      return;
    }

    const top = activeLink.offsetTop + 4;
    const height = Math.max(16, activeLink.offsetHeight - 8);
    el.linTocIndicator.style.transform = `translate3d(0, ${top}px, 0)`;
    el.linTocIndicator.style.height = `${height}px`;
    el.linTocIndicator.classList.add('is-visible');
  }

  function scrollToHeading(headingId, smooth) {
    pinnedHeading = currentHeadings.find((h) => h.id === headingId)?.node || null;
    if (!pinnedHeading) return false;
    setActiveTocHeading(headingId);
    alignHeading(smooth);
    return true;
  }

  function alignHeading(smooth) {
    const scrollRect = el.docScroll.getBoundingClientRect();
    const nodeRect = pinnedHeading.getBoundingClientRect();
    const nextTop = el.docScroll.scrollTop + (nodeRect.top - scrollRect.top) - 24;
    const room = Math.max(0, Math.ceil(nextTop + el.docScroll.clientHeight - el.docLayout.offsetHeight));
    el.docScroll.style.setProperty('--anchor-room', room + 'px');
    el.docScroll.scrollTo({ top: Math.max(0, nextTop), behavior: smooth ? 'smooth' : 'instant' });
  }

  // An author's photos, GIFs and video metadata can resize earlier paragraphs
  // after navigation. Keep the chosen heading in view until the reader scrolls.
  new ResizeObserver(() => { if (pinnedHeading) alignHeading(false); }).observe(el.docContent);
  for (const event of ['wheel', 'touchstart', 'pointerdown']) {
    el.docScroll.addEventListener(event, () => { pinnedHeading = null; }, { passive: true });
  }
  document.addEventListener('keydown', (event) => {
    if (['ArrowUp', 'ArrowDown', 'PageUp', 'PageDown', 'Home', 'End', ' '].includes(event.key)) pinnedHeading = null;
  });

  function computeActiveHeadingOnScroll() {
    if (!currentHeadings.length || pinnedHeading) return;

    const scrollTop = el.docScroll.scrollTop;
    const maxScroll = el.docScroll.scrollHeight - el.docScroll.clientHeight;

    // Scrolled all the way to bottom -> highlight final heading
    if (maxScroll > 20 && scrollTop >= maxScroll - 8) {
      const lastId = currentHeadings[currentHeadings.length - 1].id;
      if (lastId !== state.activeHeadingId) setActiveTocHeading(lastId);
      return;
    }

    const containerTop = el.docScroll.getBoundingClientRect().top;
    const threshold = containerTop + 96;
    let activeId = currentHeadings[0].id;
    for (const h of currentHeadings) {
      const top = h.node.getBoundingClientRect().top;
      if (top <= threshold) {
        activeId = h.id;
      } else {
        break;
      }
    }
    if (activeId !== state.activeHeadingId) {
      setActiveTocHeading(activeId);
    }
  }

  el.docScroll.addEventListener('scroll', () => {
    if (scrollSpyRaf) return;
    scrollSpyRaf = requestAnimationFrame(() => {
      scrollSpyRaf = 0;
      computeActiveHeadingOnScroll();
    });
  }, { passive: true });

  function navigateToPage(pageId, headingId) {
    if (!pageById.has(pageId)) { showToast('目标页面已移除。'); return; }
    renderArticle(pageId, headingId);
    if (window.history && window.history.replaceState) {
      const hash = pageHash(pageId, pinnedHeading?.id);
      window.history.replaceState(null, '', hash);
    }
  }

  /* ==================== 复制本页 Markdown ==================== */
  function serializeCurrentPageMarkdown() {
    const page = pageById.get(state.currentPageId);
    if (!page) return '';
    const lines = [`# ${page.title}`, '', page.summary, ''];
    for (const b of page.blocks) {
      if (b.type === 'h2') lines.push(`## ${b.text}`, '');
      else if (b.type === 'h3') lines.push(`### ${b.text}`, '');
      else if (b.type === 'p') lines.push(b.text, '');
      else if (b.type === 'ol') lines.push(...b.items.map((x, i) => `${i + 1}. ${x}`), '');
      else if (b.type === 'ul') lines.push(...b.items.map((x) => `- ${x}`), '');
      else if (b.type === 'callout') lines.push(`> **${b.title}**：${b.text}`, '');
      else if (b.type === 'image' || b.type === 'video') {
        const label = b.caption || (b.type === 'video' ? '视频' : '图片');
        lines.push((b.type === 'image' ? '!' : '') + '[' + label + '](media/' + b.file + ')', '');
      } else if (b.type === 'cards') {
        for (const item of b.items) {
          const dest = cardDestination(item);
          lines.push('- [' + dest.title + '](' + pageHash(dest.pageId, dest.headingId) + ') ' + item.desc);
        }
        lines.push('');
      } else if (b.type === 'table') {
        lines.push(`| ${b.headers.join(' | ')} |`);
        lines.push(`| ${b.headers.map(() => '---').join(' | ')} |`);
        for (const r of b.rows) lines.push(`| ${r.join(' | ')} |`);
        lines.push('');
      }
    }
    return lines.join('\n').trim();
  }

  el.copyPageBtn.addEventListener('click', () => {
    const md = serializeCurrentPageMarkdown();
    copyText(md).then(() => {
      clearTimeout(copyTimer);
      el.copyPageBtn.classList.add('is-copied');
      el.copyPageLabel.textContent = '已复制';
      copyTimer = setTimeout(() => {
        el.copyPageBtn.classList.remove('is-copied');
        el.copyPageLabel.textContent = '复制页面';
      }, 1600);
    });
  });

  /* ==================== Ctrl + K 全文搜索弹窗 ==================== */
  function buildSearchHits(rawQuery) {
    const q = rawQuery.trim().toLowerCase();
    const hits = [];
    for (const { section, page } of flatPages) {
      if (!q) {
        hits.push({ pageId: page.id, headingId: null, title: page.title, section: section.title, snippet: page.summary });
        continue;
      }
      const inTitle = page.title.toLowerCase().includes(q) || section.title.toLowerCase().includes(q);
      const inSummary = page.summary.toLowerCase().includes(q);
      let matchedHeading = null;
      let matchedSnippet = page.summary;

      let sectionId = null;
      for (const b of page.blocks) {
        if (b.type === 'h2' || b.type === 'h3') sectionId = b.id;
        if ((b.type === 'h2' || b.type === 'h3') && b.text.toLowerCase().includes(q)) {
          matchedHeading = b.id;
          matchedSnippet = `小节：${b.text}`;
          break;
        }
        const texts = [b.text, b.title, b.caption, ...(b.headers || []), ...(b.rows || []).flat()];
        for (const item of b.items || []) {
          if (typeof item === 'string') texts.push(item);
          else texts.push(item.title, item.desc);
        }
        const match = texts.find((text) => text && text.toLowerCase().includes(q));
        if (match) {
          matchedHeading = sectionId;
          matchedSnippet = match;
          break;
        }
      }

      if (inTitle || inSummary || matchedHeading || matchedSnippet !== page.summary) {
        hits.push({
          pageId: page.id,
          headingId: matchedHeading,
          title: page.title,
          section: section.title,
          snippet: matchedSnippet,
        });
      }
    }
    return hits.slice(0, 12);
  }

  function renderModalSearch() {
    state.searchHits = buildSearchHits(el.modalSearchInput.value);
    if (state.searchSelectedIdx >= state.searchHits.length) {
      state.searchSelectedIdx = 0;
    }
    el.modalSearchResults.innerHTML = '';

    if (state.searchHits.length === 0) {
      const empty = document.createElement('div');
      empty.className = 'obs-empty';
      empty.textContent = '没有找到匹配内容，换个关键词试试';
      el.modalSearchResults.appendChild(empty);
      return;
    }

    state.searchHits.forEach((hit, idx) => {
      const btn = document.createElement('button');
      btn.type = 'button';
      btn.className = `sm-item${idx === state.searchSelectedIdx ? ' is-selected' : ''}`;
      btn.setAttribute('role', 'option');
      btn.setAttribute('aria-selected', String(idx === state.searchSelectedIdx));
      btn.innerHTML = `
        <div class="sm-item-top">
          <span class="sm-item-title">${escapeHtml(hit.title)}</span>
          <span class="sm-item-sec">${escapeHtml(hit.section)}</span>
        </div>
        <div class="sm-item-snippet">${escapeHtml(hit.snippet)}</div>
      `;
      btn.addEventListener('click', () => {
        closeSearchModal();
        navigateToPage(hit.pageId, hit.headingId);
      });
      el.modalSearchResults.appendChild(btn);
    });
  }

  function openSearchModal() {
    state.searchModalOpen = true;
    state.searchSelectedIdx = 0;
    el.searchModal.hidden = false;
    el.modalSearchInput.value = '';
    renderModalSearch();
    setTimeout(() => el.modalSearchInput.focus(), 10);
  }

  function closeSearchModal() {
    state.searchModalOpen = false;
    el.searchModal.hidden = true;
  }

  /* ==================== 窄屏抽屉 ==================== */
  function openDrawer() {
    el.obsSidebar.classList.add('is-open');
    el.drawerScrim.hidden = false;
    el.mobileMenuBtn.setAttribute('aria-expanded', 'true');
  }

  function closeDrawer() {
    el.obsSidebar.classList.remove('is-open');
    el.drawerScrim.hidden = true;
    el.mobileMenuBtn.setAttribute('aria-expanded', 'false');
  }

  /* ==================== 事件绑定 ==================== */
  el.backToAboutBtn.addEventListener('click', () => ManualAuthor.request('back').catch((e) => showToast(e.message)));

  el.brandHomeLink.addEventListener('click', (e) => {
    e.preventDefault();
    navigateToPage('welcome');
  });
  document.querySelector('.skip-link').addEventListener('click', (event) => {
    event.preventDefault();
    el.docScroll.focus({ preventScroll: true });
  });

  el.sidebarFilterInput.addEventListener('input', () => {
    state.sidebarFilter = el.sidebarFilterInput.value;
    el.sidebarFilterClear.hidden = state.sidebarFilter.length === 0;
    renderSidebarTree();
  });

  el.sidebarFilterClear.addEventListener('click', () => {
    state.sidebarFilter = '';
    el.sidebarFilterInput.value = '';
    el.sidebarFilterClear.hidden = true;
    renderSidebarTree();
    el.sidebarFilterInput.focus();
  });

  el.toggleAllFoldersBtn.addEventListener('click', () => {
    const allOpen = DATA.sections.every((s) => state.openFolders.has(s.id));
    if (allOpen) {
      state.openFolders.clear();
      const activeSec = sectionByPageId.get(state.currentPageId);
      if (activeSec) state.openFolders.add(activeSec.id);
    } else {
      for (const s of DATA.sections) state.openFolders.add(s.id);
    }
    renderSidebarTree();
  });

  el.openSearchBtn.addEventListener('click', openSearchModal);
  el.modalSearchInput.addEventListener('input', () => {
    state.searchSelectedIdx = 0;
    renderModalSearch();
  });

  el.searchModal.addEventListener('click', (e) => {
    if (e.target === el.searchModal) closeSearchModal();
  });

  el.mobileMenuBtn.addEventListener('click', () => {
    if (el.obsSidebar.classList.contains('is-open')) closeDrawer();
    else openDrawer();
  });
  el.drawerScrim.addEventListener('click', closeDrawer);

  document.querySelectorAll('[data-accent-pick]').forEach((dot) => {
    dot.addEventListener('click', () => {
      const accent = dot.dataset.accentPick;
      el.html.setAttribute('data-accent', accent);
      document.querySelectorAll('[data-accent-pick]').forEach((other) => {
        const on = other === dot;
        other.classList.toggle('is-active', on);
        other.setAttribute('aria-checked', String(on));
      });
    });
  });

  el.themeToggle.addEventListener('click', () => {
    const next = el.html.getAttribute('data-theme') === 'dark' ? 'light' : 'dark';
    el.html.setAttribute('data-theme', next);
  });

  window.addEventListener('keydown', (e) => {
    if (document.getElementById('articleEditor').open) return;
    if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'k') {
      e.preventDefault();
      if (state.searchModalOpen) closeSearchModal();
      else openSearchModal();
      return;
    }

    if (state.searchModalOpen) {
      if (e.key === 'Escape') {
        e.preventDefault();
        closeSearchModal();
      } else if (e.key === 'ArrowDown') {
        e.preventDefault();
        if (state.searchHits.length > 0) {
          state.searchSelectedIdx = (state.searchSelectedIdx + 1) % state.searchHits.length;
          renderModalSearch();
        }
      } else if (e.key === 'ArrowUp') {
        e.preventDefault();
        if (state.searchHits.length > 0) {
          state.searchSelectedIdx = (state.searchSelectedIdx - 1 + state.searchHits.length) % state.searchHits.length;
          renderModalSearch();
        }
      } else if (e.key === 'Enter') {
        e.preventDefault();
        const hit = state.searchHits[state.searchSelectedIdx];
        if (hit) {
          closeSearchModal();
          navigateToPage(hit.pageId, hit.headingId);
        }
      }
      return;
    }

    if (e.key === 'Escape' && el.obsSidebar.classList.contains('is-open')) {
      closeDrawer();
    }
  });

  window.addEventListener('resize', () => {
    if (pinnedHeading) alignHeading(false);
    if (state.activeHeadingId) {
      setActiveTocHeading(state.activeHeadingId);
    }
  });

  // Restore page from URL hash if present
  function initFromHash() {
    const raw = (window.location.hash || '').replace(/^#/, '');
    if (!raw) {
      renderArticle('welcome');
      return;
    }
    const [pid, hid] = raw.split('/');
    if (pageById.has(pid)) {
      renderArticle(pid, hid || null);
    } else {
      renderArticle('welcome');
    }
  }

  if (new URLSearchParams(location.search).get('theme') === 'dark') el.html.dataset.theme = 'dark';

  function applyLocalPage(page) {
    const section = sectionByPageId.get(page.id) || DATA.sections.find((s) => s.id === page.section);
    if (!section) return;
    const index = section.pages.findIndex((p) => p.id === page.id);
    if (index >= 0) section.pages[index] = page;
    else section.pages.push(page);
  }
  ManualAuthor.init({
    current: () => ({ page: pageById.get(state.currentPageId), section: sectionByPageId.get(state.currentPageId) }),
    pages: () => flatPages.map((item) => item.page),
    cardDestination,
    savePage(page) { applyLocalPage(page); indexPages(); navigateToPage(page.id); },
    toast: showToast,
  }).then((local) => {
    local.forEach(applyLocalPage);
    indexPages();
    initFromHash();
    window.addEventListener('hashchange', initFromHash);
  });
})();
