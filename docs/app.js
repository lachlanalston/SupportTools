'use strict';

// ─── State ────────────────────────────────────────────────────────
let scripts   = [];
let bookmarks = [];
let commands  = [];

let activeTab    = 'scripts';
let scriptFilter = 'all';
let commandFilter = 'all';
let bookmarkFilter = 'all';
let searchQuery  = '';

let fuseScripts   = null;
let fuseBookmarks = null;
let fuseCommands  = null;

// ─── Load data ────────────────────────────────────────────────────
async function loadData() {
  const [s, b, c] = await Promise.all([
    fetch('data/scripts.json').then(r => r.json()),
    fetch('data/bookmarks.json').then(r => r.json()),
    fetch('data/commands.json').then(r => r.json()),
  ]);

  scripts   = s;
  bookmarks = b;
  commands  = c;

  fuseScripts = new Fuse(scripts, {
    keys: ['name', 'description', 'tags', 'category'],
    threshold: 0.35,
    includeScore: true,
  });

  fuseBookmarks = new Fuse(bookmarks, {
    keys: ['name', 'description', 'tags', 'category'],
    threshold: 0.35,
    includeScore: true,
  });

  fuseCommands = new Fuse(commands, {
    keys: ['name', 'description', 'value', 'tags'],
    threshold: 0.35,
    includeScore: true,
  });

  buildBookmarkFilters();
  render();
}

// ─── Build bookmark category filter chips ─────────────────────────
function buildBookmarkFilters() {
  const categories = [...new Set(bookmarks.map(b => b.category))];
  const container  = document.getElementById('bookmark-filters');

  const allBtn = document.createElement('button');
  allBtn.className = 'filter-chip active';
  allBtn.dataset.filter = 'all';
  allBtn.textContent = 'All';
  allBtn.addEventListener('click', () => {
    bookmarkFilter = 'all';
    container.querySelectorAll('.filter-chip').forEach(c => c.classList.remove('active'));
    allBtn.classList.add('active');
    render();
  });
  container.appendChild(allBtn);

  categories.forEach(cat => {
    const btn = document.createElement('button');
    btn.className = 'filter-chip';
    btn.dataset.filter = cat;
    btn.textContent = cat.replace('RFCs — ', 'RFC: ');
    btn.addEventListener('click', () => {
      bookmarkFilter = cat;
      container.querySelectorAll('.filter-chip').forEach(c => c.classList.remove('active'));
      btn.classList.add('active');
      render();
    });
    container.appendChild(btn);
  });
}

// ─── Render ───────────────────────────────────────────────────────
function render() {
  renderScripts();
  renderBookmarks();
  renderCommands();
  updateCounts();
}

function getFiltered(data, fuse, query) {
  if (!query) return data;
  return fuse.search(query).map(r => r.item);
}

// ── Scripts ──
function renderScripts() {
  let data = getFiltered(scripts, fuseScripts, searchQuery);

  if (scriptFilter === 'wip') {
    data = data.filter(s => s.wip);
  } else if (scriptFilter !== 'all') {
    data = data.filter(s => s.platform === scriptFilter && !s.wip);
  }

  const grid  = document.getElementById('scripts-grid');
  const empty = document.getElementById('scripts-empty');
  grid.innerHTML = '';

  if (!data.length) {
    empty.hidden = false;
    return;
  }
  empty.hidden = true;

  data.forEach(script => {
    const card = document.createElement('div');
    card.className = 'card' + (script.wip ? ' wip' : '');
    card.dataset.platform = script.wip ? 'wip' : script.platform;
    card.setAttribute('role', 'button');
    card.setAttribute('tabindex', '0');

    card.innerHTML = `
      <div class="card-header">
        <span class="card-name">${esc(script.name)}</span>
        <div class="card-badges">
          <span class="badge badge-${script.wip ? 'wip' : script.platform}">${script.wip ? 'WIP' : platformLabel(script.platform)}</span>
        </div>
      </div>
      <p class="card-desc">${esc(script.description)}</p>
      <div class="card-tags">${script.tags.slice(0, 5).map(t => `<span class="tag">${esc(t)}</span>`).join('')}</div>
    `;

    card.addEventListener('click', () => openScriptModal(script));
    card.addEventListener('keydown', e => { if (e.key === 'Enter' || e.key === ' ') openScriptModal(script); });
    grid.appendChild(card);
  });
}

// ── Bookmarks ──
function renderBookmarks() {
  let data = getFiltered(bookmarks, fuseBookmarks, searchQuery);

  if (bookmarkFilter !== 'all') {
    data = data.filter(b => b.category === bookmarkFilter);
  }

  const grid  = document.getElementById('bookmarks-grid');
  const empty = document.getElementById('bookmarks-empty');
  grid.innerHTML = '';

  if (!data.length) {
    empty.hidden = false;
    return;
  }
  empty.hidden = true;

  data.forEach(bm => {
    const card = document.createElement('a');
    card.className = 'card';
    card.dataset.platform = 'bookmark';
    card.href = bm.url;
    card.target = '_blank';
    card.rel = 'noopener noreferrer';

    card.innerHTML = `
      <div class="card-header">
        <span class="card-name">${esc(bm.name)}</span>
        <div class="card-badges">
          <span class="badge badge-bookmark">${esc(shortCategory(bm.category))}</span>
        </div>
      </div>
      <p class="card-desc">${esc(bm.description)}</p>
      <p class="card-category">${esc(bm.category)}</p>
      <div class="card-tags">${bm.tags.slice(0, 5).map(t => `<span class="tag">${esc(t)}</span>`).join('')}</div>
    `;
    grid.appendChild(card);
  });
}

// ── Commands ──
function renderCommands() {
  let data = getFiltered(commands, fuseCommands, searchQuery);

  if (commandFilter !== 'all') {
    if (commandFilter === 'shortcut' || commandFilter === 'command') {
      data = data.filter(c => c.type === commandFilter);
    } else {
      data = data.filter(c => c.platform === commandFilter || c.platform === 'both');
    }
  }

  const grid  = document.getElementById('commands-grid');
  const empty = document.getElementById('commands-empty');
  grid.innerHTML = '';

  if (!data.length) {
    empty.hidden = false;
    return;
  }
  empty.hidden = true;

  data.forEach(cmd => {
    const card = document.createElement('div');
    card.className = 'card';
    card.dataset.platform = cmd.type;
    card.setAttribute('role', 'button');
    card.setAttribute('tabindex', '0');

    card.innerHTML = `
      <div class="card-header">
        <span class="card-name">${esc(cmd.name)}</span>
        <div class="card-badges">
          <span class="badge badge-${cmd.type}">${cmd.type === 'shortcut' ? 'Shortcut' : 'Command'}</span>
          <span class="badge badge-${cmd.platform}">${platformLabel(cmd.platform)}</span>
        </div>
      </div>
      <p class="card-desc">${esc(cmd.description)}</p>
      <div class="card-value">${esc(cmd.value)}</div>
    `;

    card.addEventListener('click', () => openCommandModal(cmd));
    card.addEventListener('keydown', e => { if (e.key === 'Enter' || e.key === ' ') openCommandModal(cmd); });
    grid.appendChild(card);
  });
}

// ─── Counts ───────────────────────────────────────────────────────
function updateCounts() {
  document.getElementById('count-scripts').textContent   = document.querySelectorAll('#scripts-grid .card').length;
  document.getElementById('count-bookmarks').textContent = document.querySelectorAll('#bookmarks-grid .card').length;
  document.getElementById('count-commands').textContent  = document.querySelectorAll('#commands-grid .card').length;
}

// ─── Modals ───────────────────────────────────────────────────────
function openScriptModal(script) {
  const platformColor = {
    windows: '#2196f3',
    macos:   '#9b8af4',
    m365:    '#d83b01',
    '3cx':   '#00a859',
    wip:     '#e3b341',
  };

  const color = script.wip ? platformColor.wip : (platformColor[script.platform] || '#388bfd');

  const body = document.getElementById('modal-body');
  body.innerHTML = `
    <div class="modal-platform-bar" style="background: ${color};"></div>
    <h2 class="modal-name">${esc(script.name)}</h2>
    <div class="modal-badges">
      <span class="badge badge-${script.wip ? 'wip' : script.platform}">${script.wip ? 'WIP' : platformLabel(script.platform)}</span>
      <span class="badge badge-${script.platform === 'macos' ? 'macos' : 'windows'}" style="background:rgba(110,118,129,0.15);color:var(--sub);">${esc(script.category)}</span>
    </div>
    <p class="modal-desc">${esc(script.description)}</p>
    <div class="modal-section-label">File</div>
    <div class="modal-value">${esc(script.file)}</div>
    <div class="modal-section-label">Tags</div>
    <div class="modal-tags">${script.tags.map(t => `<span class="tag">${esc(t)}</span>`).join('')}</div>
    <div class="modal-actions">
      <a class="btn btn-primary" href="${script.github_url}" target="_blank" rel="noopener">
        <svg viewBox="0 0 16 16" fill="currentColor" width="14" height="14"><path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8c0-4.42-3.58-8-8-8z"/></svg>
        View on GitHub
      </a>
      <button class="btn btn-secondary" id="copy-path-btn">
        <svg viewBox="0 0 16 16" fill="currentColor" width="14" height="14"><path fill-rule="evenodd" d="M0 6.75C0 5.784.784 5 1.75 5h1.5a.75.75 0 010 1.5h-1.5a.25.25 0 00-.25.25v7.5c0 .138.112.25.25.25h7.5a.25.25 0 00.25-.25v-1.5a.75.75 0 011.5 0v1.5A1.75 1.75 0 019.25 16h-7.5A1.75 1.75 0 010 14.25v-7.5z"/><path fill-rule="evenodd" d="M5 1.75C5 .784 5.784 0 6.75 0h7.5C15.216 0 16 .784 16 1.75v7.5A1.75 1.75 0 0114.25 11h-7.5A1.75 1.75 0 015 9.25v-7.5zm1.75-.25a.25.25 0 00-.25.25v7.5c0 .138.112.25.25.25h7.5a.25.25 0 00.25-.25v-7.5a.25.25 0 00-.25-.25h-7.5z"/></svg>
        Copy path
      </button>
    </div>
  `;

  document.getElementById('copy-path-btn').addEventListener('click', () => {
    copyToClipboard(script.file, 'copy-path-btn', 'Copied!');
  });

  showModal();
}

function openCommandModal(cmd) {
  const body = document.getElementById('modal-body');
  body.innerHTML = `
    <div class="modal-platform-bar" style="background: ${cmd.type === 'shortcut' ? '#9b8af4' : '#2196f3'};"></div>
    <h2 class="modal-name">${esc(cmd.name)}</h2>
    <div class="modal-badges">
      <span class="badge badge-${cmd.type}">${cmd.type === 'shortcut' ? 'Shortcut' : 'Command'}</span>
      <span class="badge badge-${cmd.platform}">${platformLabel(cmd.platform)}</span>
    </div>
    <p class="modal-desc">${esc(cmd.description)}</p>
    <div class="modal-section-label">${cmd.type === 'shortcut' ? 'Keys' : 'Command'}</div>
    <div class="modal-value">${esc(cmd.value)}</div>
    <div class="modal-section-label">Tags</div>
    <div class="modal-tags">${cmd.tags.map(t => `<span class="tag">${esc(t)}</span>`).join('')}</div>
    <div class="modal-actions">
      <button class="btn btn-primary" id="copy-cmd-btn">
        <svg viewBox="0 0 16 16" fill="currentColor" width="14" height="14"><path fill-rule="evenodd" d="M0 6.75C0 5.784.784 5 1.75 5h1.5a.75.75 0 010 1.5h-1.5a.25.25 0 00-.25.25v7.5c0 .138.112.25.25.25h7.5a.25.25 0 00.25-.25v-1.5a.75.75 0 011.5 0v1.5A1.75 1.75 0 019.25 16h-7.5A1.75 1.75 0 010 14.25v-7.5z"/><path fill-rule="evenodd" d="M5 1.75C5 .784 5.784 0 6.75 0h7.5C15.216 0 16 .784 16 1.75v7.5A1.75 1.75 0 0114.25 11h-7.5A1.75 1.75 0 015 9.25v-7.5zm1.75-.25a.25.25 0 00-.25.25v7.5c0 .138.112.25.25.25h7.5a.25.25 0 00.25-.25v-7.5a.25.25 0 00-.25-.25h-7.5z"/></svg>
        Copy ${cmd.type === 'shortcut' ? 'shortcut' : 'command'}
      </button>
    </div>
  `;

  document.getElementById('copy-cmd-btn').addEventListener('click', () => {
    copyToClipboard(cmd.value, 'copy-cmd-btn', 'Copied!');
  });

  showModal();
}

function showModal() {
  const backdrop = document.getElementById('modal-backdrop');
  backdrop.hidden = false;
  document.body.style.overflow = 'hidden';
  document.getElementById('modal-close').focus();
}

function closeModal() {
  document.getElementById('modal-backdrop').hidden = true;
  document.body.style.overflow = '';
}

// ─── Clipboard ────────────────────────────────────────────────────
function copyToClipboard(text, btnId, successText) {
  navigator.clipboard.writeText(text).then(() => {
    const btn = document.getElementById(btnId);
    if (!btn) return;
    const original = btn.innerHTML;
    btn.textContent = successText;
    btn.classList.add('btn-copy-success');
    setTimeout(() => {
      btn.innerHTML = original;
      btn.classList.remove('btn-copy-success');
    }, 1800);
  });
}

// ─── Helpers ──────────────────────────────────────────────────────
function esc(str) {
  return String(str)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

function platformLabel(p) {
  const map = { windows: 'Windows', macos: 'macOS', m365: 'M365', '3cx': '3CX', both: 'Win/Mac' };
  return map[p] || p;
}

function shortCategory(cat) {
  if (cat.startsWith('RFCs')) return 'RFC';
  const short = { 'IP & Domain Reputation': 'IP/Domain', 'Malware & Sandbox Analysis': 'Malware', 'Threat Feeds & IOCs': 'Threat Intel', 'Breach & Exposure Checking': 'Breach', 'Email & DNS Tools': 'Email/DNS', 'Cybersecurity Frameworks': 'Framework', 'Compliance & Governance': 'Compliance', 'System & Software Lifecycle': 'Lifecycle', 'Financial Standards': 'Financial' };
  return short[cat] || cat;
}

// ─── Event wiring ─────────────────────────────────────────────────
function init() {
  // Search
  const searchEl = document.getElementById('search');
  let debounce;
  searchEl.addEventListener('input', e => {
    clearTimeout(debounce);
    debounce = setTimeout(() => {
      searchQuery = e.target.value.trim();
      render();
    }, 120);
  });

  // Keyboard shortcut: / to focus search
  document.addEventListener('keydown', e => {
    if (e.key === '/' && document.activeElement !== searchEl) {
      e.preventDefault();
      searchEl.focus();
      searchEl.select();
    }
    if (e.key === 'Escape') {
      if (!document.getElementById('modal-backdrop').hidden) {
        closeModal();
      } else {
        searchEl.blur();
      }
    }
  });

  // Tabs
  document.querySelectorAll('.tab').forEach(tab => {
    tab.addEventListener('click', () => {
      document.querySelectorAll('.tab').forEach(t => { t.classList.remove('active'); t.setAttribute('aria-selected', 'false'); });
      document.querySelectorAll('.tab-panel').forEach(p => p.classList.remove('active'));
      tab.classList.add('active');
      tab.setAttribute('aria-selected', 'true');
      activeTab = tab.dataset.tab;
      document.getElementById(`tab-${activeTab}`).classList.add('active');
    });
  });

  // Script filters
  document.getElementById('script-filters').addEventListener('click', e => {
    const chip = e.target.closest('.filter-chip');
    if (!chip) return;
    document.querySelectorAll('#script-filters .filter-chip').forEach(c => c.classList.remove('active'));
    chip.classList.add('active');
    scriptFilter = chip.dataset.filter;
    render();
  });

  // Command filters
  document.getElementById('command-filters').addEventListener('click', e => {
    const chip = e.target.closest('.filter-chip');
    if (!chip) return;
    document.querySelectorAll('#command-filters .filter-chip').forEach(c => c.classList.remove('active'));
    chip.classList.add('active');
    commandFilter = chip.dataset.filter;
    render();
  });

  // Modal close
  document.getElementById('modal-close').addEventListener('click', closeModal);
  document.getElementById('modal-backdrop').addEventListener('click', e => {
    if (e.target === document.getElementById('modal-backdrop')) closeModal();
  });

  loadData();
}

document.addEventListener('DOMContentLoaded', init);
