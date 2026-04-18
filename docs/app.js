'use strict';

// ─── Constants ────────────────────────────────────────────────────
const RAW_BASE = 'https://raw.githubusercontent.com/lachlanalston/SupportTools/main';

function rawUrl(file) {
  return `${RAW_BASE}/${file}`;
}

function oneLiner(script) {
  if (script.platform === 'macos') {
    return `bash <(curl -fsSL ${rawUrl(script.file)})`;
  }
  // windows, m365, 3cx — all PowerShell
  return `irm '${rawUrl(script.file)}' | iex`;
}

function flagOneLiner(script, flag) {
  const url = rawUrl(script.file);
  if (script.platform === 'macos') {
    return `bash <(curl -fsSL ${url}) ${flag}`;
  }
  return `$s = irm '${url}'; & ([scriptblock]::Create($s)) ${flag}`;
}

// ─── State ────────────────────────────────────────────────────────
let scripts   = [];
let bookmarks = [];
let commands  = [];

let activeTab      = 'scripts';
let scriptFilter   = 'all';
let commandFilter  = 'all';
let shortcutFilter = 'all';
let bookmarkFilter = 'all';
let searchQuery    = '';

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
  renderShortcuts();
  updateCounts();
}

function getFiltered(data, fuse, query) {
  if (!query) return data;
  return fuse.search(query).map(r => r.item);
}

// ── Scripts ──
function renderScripts() {
  let data = getFiltered(scripts, fuseScripts, searchQuery);

  if (scriptFilter === 'has-fix') {
    data = data.filter(s => s.flags && s.flags.some(f => f.type === 'fix'));
  } else if (scriptFilter !== 'all') {
    data = data.filter(s => s.platform === scriptFilter);
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
    card.className = 'card';
    card.dataset.platform = script.platform;
    card.setAttribute('role', 'button');
    card.setAttribute('tabindex', '0');

    const hasFixFlag = script.flags && script.flags.some(f => f.type === 'fix');
    card.innerHTML = `
      <div class="card-header">
        <span class="card-name">${esc(script.name)}</span>
        <div class="card-badges">
          <span class="badge badge-${script.platform}">${platformLabel(script.platform)}</span>
          ${hasFixFlag ? '<span class="badge badge-fix">Remediate</span>' : ''}
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
  let data = getFiltered(commands, fuseCommands, searchQuery).filter(c => c.type === 'command');

  if (commandFilter !== 'all') {
    data = data.filter(c => c.platform === commandFilter || c.platform === 'both');
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

// ── Shortcuts ──
function renderShortcuts() {
  let data = getFiltered(commands, fuseCommands, searchQuery).filter(c => c.type === 'shortcut');

  if (shortcutFilter !== 'all') {
    data = data.filter(c => c.platform === shortcutFilter || c.platform === 'both');
  }

  const grid  = document.getElementById('shortcuts-grid');
  const empty = document.getElementById('shortcuts-empty');
  grid.innerHTML = '';

  if (!data.length) {
    empty.hidden = false;
    return;
  }
  empty.hidden = true;

  data.forEach(cmd => {
    const card = document.createElement('div');
    card.className = 'card';
    card.dataset.platform = 'shortcut';
    card.setAttribute('role', 'button');
    card.setAttribute('tabindex', '0');

    card.innerHTML = `
      <div class="card-header">
        <span class="card-name">${esc(cmd.name)}</span>
        <div class="card-badges">
          <span class="badge badge-shortcut">Shortcut</span>
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
  document.getElementById('count-shortcuts').textContent = document.querySelectorAll('#shortcuts-grid .card').length;
}

// ─── Modals ───────────────────────────────────────────────────────
function openScriptModal(script) {
  const platformColor = {
    windows: '#2196f3',
    macos:   '#9b8af4',
    m365:    '#d83b01',
    api:     '#00a859',
  };

  const color    = platformColor[script.platform] || '#388bfd';
  const cmdText  = oneLiner(script);
  const canRun   = !script.requires_config;
  const needsCfg = script.requires_config;

  const ghIcon = `<svg viewBox="0 0 16 16" fill="currentColor" width="14" height="14"><path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8c0-4.42-3.58-8-8-8z"/></svg>`;
  const cpyIcon = `<svg viewBox="0 0 16 16" fill="currentColor" width="14" height="14"><path fill-rule="evenodd" d="M0 6.75C0 5.784.784 5 1.75 5h1.5a.75.75 0 010 1.5h-1.5a.25.25 0 00-.25.25v7.5c0 .138.112.25.25.25h7.5a.25.25 0 00.25-.25v-1.5a.75.75 0 011.5 0v1.5A1.75 1.75 0 019.25 16h-7.5A1.75 1.75 0 010 14.25v-7.5z"/><path fill-rule="evenodd" d="M5 1.75C5 .784 5.784 0 6.75 0h7.5C15.216 0 16 .784 16 1.75v7.5A1.75 1.75 0 0114.25 11h-7.5A1.75 1.75 0 015 9.25v-7.5zm1.75-.25a.25.25 0 00-.25.25v7.5c0 .138.112.25.25.25h7.5a.25.25 0 00.25-.25v-7.5a.25.25 0 00-.25-.25h-7.5z"/></svg>`;
  const playIcon = `<svg viewBox="0 0 16 16" fill="currentColor" width="14" height="14"><path d="M8 0a8 8 0 100 16A8 8 0 008 0zM1.5 8a6.5 6.5 0 1113 0 6.5 6.5 0 01-13 0zm4.879-2.773a.5.5 0 01.52.038l3.5 2.5a.5.5 0 010 .47l-3.5 2.5A.5.5 0 016 10.25v-5a.5.5 0 01.379-.523z"/></svg>`;
  const warnIcon = `<svg viewBox="0 0 16 16" fill="currentColor" width="13" height="13"><path d="M8.22 1.754a.25.25 0 00-.44 0L1.698 13.132a.25.25 0 00.22.368h12.164a.25.25 0 00.22-.368L8.22 1.754zm-1.763-.707c.659-1.234 2.427-1.234 3.086 0l6.082 11.378A1.75 1.75 0 0114.082 15H1.918a1.75 1.75 0 01-1.543-2.575L6.457 1.047zM9 11a1 1 0 11-2 0 1 1 0 012 0zm-.25-5.25a.75.75 0 00-1.5 0v2.5a.75.75 0 001.5 0v-2.5z"/></svg>`;

  const runSection = `
    <div class="modal-section-label" style="margin-top:4px;">Run one-liner</div>
    ${needsCfg ? `<div class="modal-config-warning">${warnIcon} Edit required — ${esc(script.config_note || 'configure variables before running.')}</div>` : ''}
    <div class="modal-oneliner">${esc(cmdText)}</div>
    <div class="modal-actions" style="margin-top:10px;">
      <button class="btn ${canRun ? 'btn-run' : 'btn-run-config'}" id="copy-run-btn">
        ${canRun ? playIcon : cpyIcon}
        Copy
      </button>
      <a class="btn btn-secondary" href="${script.github_url}" target="_blank" rel="noopener">
        ${ghIcon} View on GitHub
      </a>
    </div>
  `;

  const flags = script.flags || [];
  const flagsSection = flags.length ? `
    <div class="modal-section-label modal-flags-label">Flags</div>
    <div class="modal-flags">
      ${flags.map((f, i) => `
        <div class="modal-flag-item">
          <div class="modal-flag-header">
            <code class="modal-flag-name">${esc(f.flag)}</code>
            <span class="modal-flag-type modal-flag-type-${esc(f.type)}">${f.type === 'fix' ? 'Remediate' : 'Mode'}</span>
            <span class="modal-flag-when">${esc(f.when)}</span>
          </div>
          <div class="modal-oneliner modal-flag-cmd">${esc(flagOneLiner(script, f.flag))}</div>
          <div class="modal-actions" style="margin-top:8px;">
            <button class="btn btn-secondary" id="copy-flag-${i}-btn">${cpyIcon} Copy</button>
          </div>
        </div>
      `).join('')}
    </div>
  ` : '';

  const body = document.getElementById('modal-body');
  body.innerHTML = `
    <div class="modal-platform-bar" style="background: ${color};"></div>
    <h2 class="modal-name">${esc(script.name)}</h2>
    <div class="modal-badges">
      <span class="badge badge-${script.platform}">${platformLabel(script.platform)}</span>
      <span class="badge" style="background:rgba(110,118,129,0.15);color:var(--sub);">${esc(script.category)}</span>
    </div>
    <p class="modal-desc">${esc(script.description)}</p>
    <div class="modal-section-label">File</div>
    <div class="modal-value">${esc(script.file.split('/').pop())}</div>
    <div class="modal-section-label">Tags</div>
    <div class="modal-tags">${script.tags.map(t => `<span class="tag">${esc(t)}</span>`).join('')}</div>
    ${runSection}
    ${flagsSection}
  `;

  const copyRunBtn = document.getElementById('copy-run-btn');
  if (copyRunBtn) {
    copyRunBtn.addEventListener('click', () => {
      copyToClipboard(cmdText, 'copy-run-btn');
    });
  }

  flags.forEach((f, i) => {
    const btn = document.getElementById(`copy-flag-${i}-btn`);
    if (btn) {
      btn.addEventListener('click', () => {
        copyToClipboard(flagOneLiner(script, f.flag), `copy-flag-${i}-btn`);
      });
    }
  });

  showModal();
}

function openCommandModal(cmd) {
  const platformColor = { windows: '#2196f3', macos: '#9b8af4', m365: '#d83b01', both: '#2196f3' };
  const color  = cmd.type === 'shortcut' ? '#9b8af4' : (platformColor[cmd.platform] || '#388bfd');
  const cpyIcon = `<svg viewBox="0 0 16 16" fill="currentColor" width="14" height="14"><path fill-rule="evenodd" d="M0 6.75C0 5.784.784 5 1.75 5h1.5a.75.75 0 010 1.5h-1.5a.25.25 0 00-.25.25v7.5c0 .138.112.25.25.25h7.5a.25.25 0 00.25-.25v-1.5a.75.75 0 011.5 0v1.5A1.75 1.75 0 019.25 16h-7.5A1.75 1.75 0 010 14.25v-7.5z"/><path fill-rule="evenodd" d="M5 1.75C5 .784 5.784 0 6.75 0h7.5C15.216 0 16 .784 16 1.75v7.5A1.75 1.75 0 0114.25 11h-7.5A1.75 1.75 0 015 9.25v-7.5zm1.75-.25a.25.25 0 00-.25.25v7.5c0 .138.112.25.25.25h7.5a.25.25 0 00.25-.25v-7.5a.25.25 0 00-.25-.25h-7.5z"/></svg>`;

  let commandBlock = '';
  if (cmd.type === 'shortcut') {
    commandBlock = `
      <div class="modal-section-label">Keys</div>
      <div class="modal-value">${esc(cmd.value)}</div>`;
  } else if (cmd.platform === 'macos') {
    commandBlock = `
      <div class="modal-section-label">Command</div>
      <div class="terminal terminal-macos">
        <div class="terminal-titlebar">
          <span class="terminal-dot terminal-dot-red"></span>
          <span class="terminal-dot terminal-dot-yellow"></span>
          <span class="terminal-dot terminal-dot-green"></span>
          <span class="terminal-title">Terminal</span>
        </div>
        <div class="terminal-body">
          <div class="terminal-line">
            <span class="terminal-prompt">~ %</span>
            <span class="terminal-cmd">${esc(cmd.value)}</span>
          </div>
        </div>
      </div>`;
  } else if (cmd.platform === 'm365') {
    const prereq = cmd.prereq ? `
          <div class="terminal-prereq-note">${esc(cmd.prereq.label)}</div>
          <div class="terminal-line">
            <span class="terminal-prompt">PS C:\\&gt;</span>
            <span class="terminal-cmd terminal-cmd-dim">${esc(cmd.prereq.value)}</span>
          </div>
          <hr class="terminal-divider">` : '';
    commandBlock = `
      <div class="modal-section-label">Command</div>
      <div class="terminal terminal-ps">
        <div class="terminal-titlebar">
          <span class="terminal-title">Windows PowerShell</span>
        </div>
        <div class="terminal-body">${prereq}
          <div class="terminal-line">
            <span class="terminal-prompt">PS C:\\&gt;</span>
            <span class="terminal-cmd">${esc(cmd.value)}</span>
          </div>
        </div>
      </div>`;
  } else {
    commandBlock = `
      <div class="modal-section-label">Command</div>
      <div class="modal-value">${esc(cmd.value)}</div>`;
  }

  const body = document.getElementById('modal-body');
  body.innerHTML = `
    <div class="modal-platform-bar" style="background: ${color};"></div>
    <h2 class="modal-name">${esc(cmd.name)}</h2>
    <div class="modal-badges">
      <span class="badge badge-${cmd.type}">${cmd.type === 'shortcut' ? 'Shortcut' : 'Command'}</span>
      <span class="badge badge-${cmd.platform}">${platformLabel(cmd.platform)}</span>
    </div>
    <p class="modal-desc">${esc(cmd.description)}</p>
    ${commandBlock}
    <div class="modal-section-label" style="margin-top:16px;">Tags</div>
    <div class="modal-tags">${cmd.tags.map(t => `<span class="tag">${esc(t)}</span>`).join('')}</div>
    <div class="modal-actions">
      <button class="btn btn-primary" id="copy-cmd-btn">
        ${cpyIcon}
        Copy ${cmd.type === 'shortcut' ? 'shortcut' : 'command'}
      </button>
    </div>
  `;

  document.getElementById('copy-cmd-btn').addEventListener('click', () => {
    copyToClipboard(cmd.value, 'copy-cmd-btn');
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
const checkIcon = `<svg viewBox="0 0 16 16" fill="currentColor" width="14" height="14"><path d="M13.78 4.22a.75.75 0 010 1.06l-7.25 7.25a.75.75 0 01-1.06 0L2.22 9.28a.75.75 0 011.06-1.06L6 10.94l6.72-6.72a.75.75 0 011.06 0z"/></svg>`;

function copyToClipboard(text, btnId) {
  const done = () => {
    const btn = document.getElementById(btnId);
    if (btn) {
      const original = btn.innerHTML;
      btn.innerHTML = `${checkIcon} Copied!`;
      btn.classList.add('btn-copy-success');
      setTimeout(() => {
        btn.innerHTML = original;
        btn.classList.remove('btn-copy-success');
      }, 2000);
    }
    showToast('Copied to clipboard');
  };

  if (navigator.clipboard && navigator.clipboard.writeText) {
    navigator.clipboard.writeText(text).then(done).catch(() => execCommandFallback(text, done));
  } else {
    execCommandFallback(text, done);
  }
}

function execCommandFallback(text, callback) {
  const el = document.createElement('textarea');
  el.value = text;
  el.style.cssText = 'position:fixed;top:-999px;left:-999px;opacity:0;';
  document.body.appendChild(el);
  el.focus();
  el.select();
  try {
    document.execCommand('copy');
    callback();
  } catch (_) {}
  document.body.removeChild(el);
}

let toastTimer = null;

function showToast(message) {
  let toast = document.getElementById('copy-toast');
  if (!toast) {
    toast = document.createElement('div');
    toast.id = 'copy-toast';
    toast.setAttribute('role', 'status');
    toast.setAttribute('aria-live', 'polite');
    document.body.appendChild(toast);
  }

  toast.innerHTML = `<svg viewBox="0 0 16 16" fill="currentColor" width="14" height="14"><path d="M13.78 4.22a.75.75 0 010 1.06l-7.25 7.25a.75.75 0 01-1.06 0L2.22 9.28a.75.75 0 011.06-1.06L6 10.94l6.72-6.72a.75.75 0 011.06 0z"/></svg> ${message}`;
  toast.classList.remove('toast-hide');
  toast.classList.add('toast-show');

  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => {
    toast.classList.remove('toast-show');
    toast.classList.add('toast-hide');
  }, 2200);
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
  const map = { windows: 'Windows', macos: 'macOS', m365: 'M365', api: 'API', both: 'Win/Mac' };
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

  // Shortcut filters
  document.getElementById('shortcut-filters').addEventListener('click', e => {
    const chip = e.target.closest('.filter-chip');
    if (!chip) return;
    document.querySelectorAll('#shortcut-filters .filter-chip').forEach(c => c.classList.remove('active'));
    chip.classList.add('active');
    shortcutFilter = chip.dataset.filter;
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
