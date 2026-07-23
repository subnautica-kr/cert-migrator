/* ===== 인증서 도우미 UI ===== */
'use strict';

const $ = (s) => document.querySelector(s);
const $$ = (s) => Array.from(document.querySelectorAll(s));

let DATA = { certs: [], clean: [], backups: [], caCache: 0 };
let selectedZip = null;

/* ---------- 통신 ---------- */
async function api(path, body, timeoutMs) {
  const opt = body !== undefined
    ? { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) }
    : {};
  // 서버가 어떤 이유로든 응답을 안 하면 무한 대기하지 않도록 상한을 둔다
  const ctl = new AbortController();
  opt.signal = ctl.signal;
  const timer = setTimeout(() => ctl.abort(), timeoutMs || 60000);
  try {
    const res = await fetch(path, opt);
    const ct = res.headers.get('content-type') || '';
    return ct.includes('json') ? res.json() : res.text();
  } finally { clearTimeout(timer); }
}

/* ---------- 공통 UI ---------- */
function show(view) {
  $$('.view').forEach(v => v.hidden = true);
  const el = $('#view-' + view);
  (el || $('#view-home')).hidden = false;
  window.scrollTo(0, 0);
  if (view === 'rules') loadRules();
  if (view === 'log') loadLog();
  if (view === 'about') loadAbout();
}
// 브라우저 히스토리와 연동 → 마우스 뒤로/앞으로 버튼, Alt+←/→ 가 자동으로 동작
function go(view) {
  show(view);
  history.pushState({ view }, '', '#' + view);
}
$$('[data-go]').forEach(b => b.addEventListener('click', () => go(b.dataset.go)));

// 뒤로가기(마우스 4번 버튼/Alt+←)로 popstate 발생 시 해당 화면 표시
window.addEventListener('popstate', (e) => {
  // 모달이 열려 있으면 화면 이동 대신 모달만 닫고 현재 화면 유지
  if (!$('#modal-back').hidden) {
    const c = $('#modal-cancel');
    (c.hidden ? $('#modal-ok') : c).click();
    history.pushState({ view: currentView() }, '', '#' + currentView());
    return;
  }
  const v = (e.state && e.state.view) || 'home';
  show(v);
});
function currentView() {
  const v = $$('.view').find(x => !x.hidden);
  return v ? v.id.replace('view-', '') : 'home';
}
// 첫 진입 상태 등록 (home)
history.replaceState({ view: 'home' }, '', '#home');

// 키보드: 백스페이스=뒤로, Esc=모달취소/뒤로, Enter=모달확인
document.addEventListener('keydown', (e) => {
  const t = e.target;
  const editing = t && (t.tagName === 'INPUT' || t.tagName === 'TEXTAREA' || t.isContentEditable);
  const modalOpen = !$('#modal-back').hidden;
  if (modalOpen) {
    if (e.key === 'Enter' && t.tagName !== 'TEXTAREA') { e.preventDefault(); $('#modal-ok').click(); }
    else if (e.key === 'Escape' || e.key === 'Backspace' && !editing) { e.preventDefault(); const c = $('#modal-cancel'); (c.hidden ? $('#modal-ok') : c).click(); }
    return;
  }
  if (e.key === 'Backspace' && !editing) { e.preventDefault(); history.back(); }
  if (e.key === 'Escape' && !editing && currentView() !== 'home') { e.preventDefault(); history.back(); }
});

function busy(on, msg) {
  $('#busy').hidden = !on;
  if (msg) $('#busy-msg').textContent = msg;
}
let toastTimer = null;
function toast(msg) {
  const t = $('#toast');
  t.textContent = msg; t.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => t.hidden = true, 2600);
}

/* 모달: alert / confirm / prompt 대체 */
function modal({ emoji = '✅', title = '', msg = '', input = null, okText = '확인', cancel = false }) {
  return new Promise(resolve => {
    $('#modal-emoji').textContent = emoji;
    $('#modal-title').textContent = title;
    $('#modal-msg').textContent = msg;
    const ta = $('#modal-input');
    ta.hidden = (input === null);
    if (input !== null) { ta.value = input; setTimeout(() => ta.focus(), 50); }
    $('#modal-ok').textContent = okText;
    $('#modal-cancel').hidden = !cancel;
    $('#modal-back').hidden = false;
    const done = (val) => {
      $('#modal-back').hidden = true;
      $('#modal-ok').onclick = $('#modal-cancel').onclick = null;
      resolve(val);
    };
    $('#modal-ok').onclick = () => done(input !== null ? ta.value : true);
    $('#modal-cancel').onclick = () => done(null);
  });
}

/* ---------- 렌더링 ---------- */
function chip(text, cls) { return `<span class="chip ${cls}">${esc(text)}</span>`; }
function esc(s) { return String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c])); }

function certChips(c) {
  let h = '';
  // 발급기관 이름에 종류(GPKI/EPKI)가 이미 드러나면 종류 칩은 생략(중복 방지)
  if (!(c.ca && c.type && c.ca.indexOf(c.type) >= 0)) h += chip(c.type, c.type.toLowerCase());
  h += chip(c.ca, c.type ? c.type.toLowerCase() : 'gray');
  if (c.purpose) h += chip(c.purpose, 'info');
  if (c.status === '중복') h += chip('중복', 'warn');
  return h;
}
function expiryChip(c) {
  if (!c.expire) return '';
  if (c.expireDays < 0) return chip('만료됨 ' + c.expire, 'bad');
  if (c.expireDays < 30) return chip('곧만료 ' + c.expire, 'warn');
  return chip('~' + c.expire, 'ok');
}

function renderCerts() {
  const box = $('#list-certs');
  if (!DATA.certs.length) {
    let note = '이 컴퓨터에서 인증서를 찾지 못했어요.';
    if (DATA.caCache > 0) note += `\n(보안프로그램의 기관CA 파일 ${DATA.caCache}개는 옮길 필요가 없어 뺐어요)`;
    box.innerHTML = `<div class="empty-note">${esc(note).replace(/\n/g, '<br>')}</div>`;
    return;
  }
  box.innerHTML = DATA.certs.map(c => `
    <div class="item" data-cid="${c.id}">
      <div class="tick">✓</div>
      <div class="body">
        <div class="row1"><span class="name">${esc(c.name)}</span>${expiryChip(c)}</div>
        <div class="chips">${certChips(c)}</div>
        ${c.memo ? `<div class="memo">📝 ${esc(c.memo)}</div>` : ''}
        <div class="path">${esc(c.folder)}</div>
      </div>
      <button class="memo-btn" data-memo="${c.id}">✏</button>
    </div>`).join('');

  box.querySelectorAll('.item').forEach(el => {
    el.addEventListener('click', (ev) => {
      if (ev.target.closest('.memo-btn')) return;
      el.classList.toggle('sel');
      syncAllChk('#chk-all-backup', '#list-certs');
    });
  });
  box.querySelectorAll('[data-memo]').forEach(btn => {
    btn.addEventListener('click', async () => {
      const c = DATA.certs[+btn.dataset.memo];
      const val = await modal({
        emoji: '📝', title: '인증서 메모', cancel: true, okText: '저장',
        msg: `"${c.name}"\n예: 학교회계용 / OO은행 / 2027년 갱신\n(비우고 저장하면 메모 삭제)`,
        input: c.memo || ''
      });
      if (val === null) return;
      await api('/api/memo', { thumb: c.thumb, text: val.trim() });
      c.memo = val.trim();
      renderCerts();
      toast(c.memo ? '메모를 저장했어요' : '메모를 지웠어요');
    });
  });
}

function renderClean() {
  const box = $('#list-clean');
  const badge = $('#clean-count');
  if (!DATA.clean.length) {
    box.innerHTML = `<div class="empty-note">정리할 것이 없어요. 깨끗해요! 👍</div>`;
    badge.hidden = true;
    $('#btn-clean').disabled = true;
    return;
  }
  $('#btn-clean').disabled = false;
  badge.textContent = DATA.clean.length + '건';
  badge.hidden = false;

  const groups = [
    ['잡파일', '🗂 인증서와 상관없는 파일', 'bad'],
    ['만료 인증서', '⌛ 만료된 인증서', 'bad'],
    ['중복 인증서', '👯 중복 복사본', 'warn'],
    ['빈 폴더', '📁 빈 폴더', 'gray'],
  ];
  let html = '';
  for (const [label, head, cls] of groups) {
    const items = DATA.clean.filter(i => i.label === label);
    if (!items.length) continue;
    html += `<div class="group-h">${head} (${items.length})</div>`;
    html += items.map(i => `
      <div class="item ${i.recommend ? 'sel' : ''}" data-kid="${i.id}">
        <div class="tick">✓</div>
        <div class="body">
          <div class="name">${esc(i.title)} ${chip(label, cls)}</div>
          <div class="path">${esc(i.detail)}</div>
        </div>
      </div>`).join('');
  }
  box.innerHTML = html;
  box.querySelectorAll('.item').forEach(el => {
    el.addEventListener('click', () => {
      el.classList.toggle('sel');
      syncAllChk('#chk-all-clean', '#list-clean');
    });
  });
  syncAllChk('#chk-all-clean', '#list-clean');
}

function renderBackups() {
  const box = $('#list-backups');
  if (!DATA.backups.length) {
    box.innerHTML = `<div class="empty-note">아직 백업파일이 없어요.<br>보내는 컴퓨터에서 [인증서 가져가기]로 먼저 만드세요.</div>`;
    $('#preview-box').hidden = true;
    $('#btn-install').disabled = true;
    selectedZip = null;
    return;
  }
  box.innerHTML = DATA.backups.map((b, i) => `
    <div class="item" data-bid="${i}">
      <div class="tick">✓</div>
      <div class="body">
        <div class="name">💾 ${esc(b.name)}</div>
        <div class="path">만든 날짜 ${esc(b.date)}</div>
      </div>
    </div>`).join('');
  box.querySelectorAll('.item').forEach(el => {
    el.addEventListener('click', () => selectBackup(DATA.backups[+el.dataset.bid].path, el));
  });
  // 최신 백업 자동 선택
  selectBackup(DATA.backups[0].path, box.querySelector('.item'));
}

async function selectBackup(path, el) {
  $$('#list-backups .item').forEach(x => x.classList.remove('sel'));
  if (el) el.classList.add('sel');
  selectedZip = null;
  $('#btn-install').disabled = true;
  busy(true, '백업 내용을 확인하는 중…');
  try {
    const r = await api('/api/preview', { path });
    const pv = $('#list-preview');
    $('#preview-box').hidden = false;
    if (!r.ok) {
      pv.innerHTML = `<div class="empty-note">이 파일을 읽을 수 없어요.<br>${esc(r.error || '')}</div>`;
      return;
    }
    if (!r.items.length) {
      pv.innerHTML = `<div class="empty-note">이 파일 안에서 인증서를 찾지 못했어요.</div>`;
      return;
    }
    pv.innerHTML = r.items.map(it => `
      <div class="item static">
        <div class="body">
          <div class="name">${esc(it.name)}</div>
          <div class="chips">${chip(it.type, it.type.toLowerCase())}${it.expire ? chip('만료 ' + it.expire, 'gray') : ''}</div>
          ${it.memo ? `<div class="memo">📝 ${esc(it.memo)}</div>` : ''}
        </div>
      </div>`).join('');
    selectedZip = path;
    $('#btn-install').disabled = false;
  } finally { busy(false); }
}

function syncAllChk(chkSel, listSel) {
  const items = $$(listSel + ' .item');
  $(chkSel).checked = items.length > 0 && items.every(i => i.classList.contains('sel'));
}

/* ---------- 액션 ---------- */
async function rescan(silent) {
  if (!silent) busy(true, '인증서를 찾는 중…');
  try {
    DATA = await api('/api/scan', {}, 90000);
    $('#ver').textContent = 'v' + DATA.version;
    const ok = DATA.certs.filter(c => c.status === '정상').length;
    $('#home-status').textContent = DATA.certs.length
      ? `이 컴퓨터에서 인증서 ${DATA.certs.length}개를 찾았어요 (정상 ${ok}개)`
      : '이 컴퓨터에는 인증서가 없어요';
    renderCerts(); renderClean(); renderBackups();
  } catch (e) {
    $('#home-status').innerHTML = '검색이 지연되고 있어요. <button class="link" id="btn-retry" style="color:#3182F6">다시 시도</button>';
    const rb = document.getElementById('btn-retry');
    if (rb) rb.addEventListener('click', () => rescan(false));
  } finally { if (!silent) busy(false); }
}

$('#btn-rescan').addEventListener('click', () => rescan(false));
$('#chk-all-backup').addEventListener('change', (e) => {
  $$('#list-certs .item').forEach(i => i.classList.toggle('sel', e.target.checked));
});
$('#chk-all-clean').addEventListener('change', (e) => {
  $$('#list-clean .item').forEach(i => i.classList.toggle('sel', e.target.checked));
});

$('#btn-export').addEventListener('click', async () => {
  const ids = $$('#list-certs .item.sel').map(i => +i.dataset.cid);
  if (!ids.length) return toast('가져갈 인증서를 먼저 눌러서 선택하세요');
  busy(true, '백업을 만드는 중…');
  const r = await api('/api/export', { ids });
  busy(false);
  if (!r.ok) return modal({ emoji: '⚠️', title: '백업 실패', msg: r.error || '알 수 없는 오류' });
  let msg = `[백업] 폴더에 저장했어요.\n${r.name}\n\nUSB에서 실행했다면 이미 USB 안에 있어요.\n받는 컴퓨터에서 이 프로그램을 켜면 자동으로 찾아줘요.`;
  if (r.fail > 0) msg += `\n\n※ ${r.fail}개 파일은 사용 중이라 못 담았어요. 은행 프로그램을 끄고 다시 해보세요.`;
  await modal({ emoji: '🎉', title: '백업 완료!', msg });
  rescan(true);
});

$('#btn-pickzip').addEventListener('click', async () => {
  const r = await api('/api/pickzip', {});
  if (r.path) selectBackup(r.path, null);
});

$('#btn-install').addEventListener('click', async () => {
  if (!selectedZip) return;
  const ow = await modal({
    emoji: '📥', title: '설치할게요', cancel: true, okText: '설치',
    msg: '이미 같은 인증서가 있으면 받은 것으로 덮어써요.\n(기존 것을 남기고 싶으면 취소 후 관리자에게 문의)'
  });
  if (ow === null) return;
  busy(true, '설치하는 중…');
  const r = await api('/api/install', { path: selectedZip, overwrite: true });
  busy(false);
  if (!r.ok) return modal({ emoji: '⚠️', title: '설치 실패', msg: r.error || '알 수 없는 오류' });
  let msg = `설치 ${r.installed}개`;
  if (r.skipped) msg += ` · 건너뜀 ${r.skipped}개`;
  if (r.failed) msg += ` · 실패 ${r.failed}개`;
  msg += '\n\n은행·나이스·정부24에서 인증서 선택할 때\n저장위치를 "하드디스크"로 고르면 보여요.';
  if (r.failed) msg += '\n\n※ 실패가 있으면 은행 프로그램을 끄고 다시 설치해 보세요.';
  await modal({ emoji: '🎉', title: '설치 완료!', msg });
  rescan(true);
});

$('#btn-clean').addEventListener('click', async () => {
  const ids = $$('#list-clean .item.sel').map(i => +i.dataset.kid);
  if (!ids.length) return toast('정리할 항목을 먼저 선택하세요');
  const okGo = await modal({
    emoji: '🗑', title: `${ids.length}개를 휴지통으로 보낼까요?`, cancel: true, okText: '휴지통으로',
    msg: '실수로 지워도 바탕화면의 휴지통에서\n되살릴 수 있어요.'
  });
  if (okGo === null) return;
  busy(true, '휴지통으로 보내는 중…');
  const r = await api('/api/clean', { ids });
  busy(false);
  let msg = `휴지통으로 보냄: ${r.done}개`;
  if (r.fail) msg += `\n실패(사용 중 등): ${r.fail}개`;
  await modal({ emoji: '✨', title: '정리 끝!', msg });
  rescan(true);
});

/* ---------- 규칙 / 로그 ---------- */
async function loadRules() { $('#ta-rules').value = await api('/api/rules'); }
$('#btn-rules-save').addEventListener('click', async () => {
  const r = await api('/api/rules', { text: $('#ta-rules').value });
  if (!r.ok) return modal({ emoji: '⚠️', title: 'JSON 형식 오류', msg: r.error || '' });
  toast('저장했어요. 다시 검색할게요');
  await rescan(false);
  show('home');
});
$('#btn-rules-reset').addEventListener('click', async () => {
  const okGo = await modal({ emoji: '♻️', title: '기본값으로 되돌릴까요?', msg: '', cancel: true, okText: '되돌리기' });
  if (okGo === null) return;
  await api('/api/rulesreset', {});
  await loadRules();
  toast('기본값으로 되돌렸어요');
  rescan(true);
});

async function loadLog() {
  const el = $('#log-view');
  el.textContent = await api('/api/logtail');
  el.scrollTop = el.scrollHeight;
}
$('#btn-log-refresh').addEventListener('click', loadLog);
$('#btn-log-folder').addEventListener('click', () => api('/api/openlogs', {}));

/* ---------- 정보(About) + 업데이트 ---------- */
$('#ver').addEventListener('click', () => go('about'));

async function loadAbout() {
  try {
    const a = await api('/api/about');
    $('#about-ver').textContent = 'v' + a.version;
    renderChangelog(a.changelog);
  } catch (e) {}
  // 정보 화면의 상태 줄은 홈에서 이미 확인한 결과를 반영
  const box = $('#about-update');
  if (UPDATE_STATE === 'latest') { box.classList.remove('has'); box.textContent = '최신 버전이에요'; }
  else if (UPDATE_STATE === 'cannot') { box.classList.remove('has'); box.textContent = '최신버전 확인할 수 없음'; }
  else if (UPDATE_STATE === 'updating') { box.classList.add('has'); box.textContent = '업데이트 중…'; }
  else { box.textContent = '확인 중…'; }
}

// 변경이력 마크다운을 버전 카드로 렌더링
function renderChangelog(md) {
  const box = $('#about-changelog');
  if (!md) { box.textContent = '(변경 이력을 불러오지 못했습니다)'; return; }
  const lines = md.split(/\r?\n/);
  let html = '', inList = false, verOpen = false, first = true;
  const closeList = () => { if (inList) { html += '</ul>'; inList = false; } };
  const closeVer = () => { closeList(); if (verOpen) { html += '</div>'; verOpen = false; } };
  for (const raw of lines) {
    const line = raw.replace(/\s+$/, '');
    let m;
    if (/^#\s/.test(line)) continue;                       // 최상단 제목 무시
    if ((m = line.match(/^##\s+(\S+)\s*(?:\(([^)]*)\))?/))) { // 버전 헤더
      closeVer();
      html += '<div class="cl-ver"><div class="cl-head">';
      html += '<span class="cl-badge' + (first ? ' latest' : '') + '">' + esc(m[1]) + '</span>';
      if (m[2]) html += '<span class="cl-date">' + esc(m[2]) + '</span>';
      if (first) html += '<span class="cl-new">최신</span>';
      html += '</div>';
      verOpen = true; first = false;
      continue;
    }
    if ((m = line.match(/^\s*-\s+(.*)/))) {                 // 항목
      if (!inList) { html += '<ul class="cl-list">'; inList = true; }
      html += '<li>' + esc(m[1]) + '</li>';
      continue;
    }
    if (line.trim() && inList) {                            // 이어지는 설명줄 → 앞 항목에 붙임
      html = html.replace(/<\/li>$/, ' ' + esc(line.trim()) + '</li>');
    }
  }
  closeVer();
  box.innerHTML = html || '(변경 이력이 비어 있습니다)';
}

let UPDATE_INFO = null;
let UPDATE_STATE = 'checking';   // checking | latest | cannot | updating

// 업데이트 규칙:
//  - 새 버전 확인됨  → 바로 강제 업데이트(자동 다운로드·교체·재시작)
//  - 확인 불가/실패  → 구석에 작게 "최신버전 확인할 수 없음", 나머지는 정상 사용
async function checkUpdate() {
  let r;
  try { r = await api('/api/checkupdate', {}, 8000); } catch (e) { r = { ok: false, reason: 'network' }; }
  if (!r || !r.ok) {
    UPDATE_STATE = 'cannot';
    showCheckNote(true);
    return;
  }
  showCheckNote(false);
  if (r.hasUpdate) {
    UPDATE_INFO = r;
    forceUpdate(r);
  } else {
    UPDATE_STATE = 'latest';
  }
}

function showCheckNote(show) {
  const n = $('#check-note');
  if (!n) return;
  if (!show) { n.hidden = true; return; }
  n.hidden = false; n.classList.remove('fade');
  // 4초 뒤 스르륵 사라짐 (거슬리지 않게)
  setTimeout(() => {
    n.classList.add('fade');
    setTimeout(() => { n.hidden = true; }, 700);
  }, 4000);
}

// 강제 업데이트: 화면을 덮고 자동으로 내려받아 교체·재시작
async function forceUpdate(r) {
  UPDATE_STATE = 'updating';
  $('#fu-title').textContent = `새 버전 v${r.latest} 설치`;
  $('#fu-msg').innerHTML = (r.notes ? esc(r.notes) + '<br>' : '') + '최신 버전을 내려받아 자동으로 업데이트합니다.<br>잠시 후 창이 다시 열립니다.';
  $('#fu-spin').hidden = false;
  $('#fu-manual').hidden = true;
  $('#force-update').hidden = false;

  let res;
  try { res = await api('/api/doupdate', {}, 120000); } catch (e) { res = { ok: false, error: '통신 오류' }; }

  if (res && res.ok) {
    // 서버가 곧 종료되고 업데이터가 새 창을 띄운다
    $('#fu-msg').innerHTML = '업데이트를 적용하고 있어요.<br>새 창이 열리면 이 창은 닫아도 됩니다.';
    return;
  }
  // 자동 실패 → 하드락 하지 않음: 안내 + 수동 다운로드 제공 후 닫기 가능
  $('#fu-spin').hidden = true;
  $('#fu-title').textContent = '자동 업데이트를 못했어요';
  $('#fu-msg').innerHTML = '네트워크 문제로 자동 설치에 실패했어요.<br>아래에서 직접 내려받거나, 그냥 계속 사용해도 됩니다.';
  const btn = $('#fu-manual');
  btn.hidden = !(UPDATE_INFO && UPDATE_INFO.download);
  btn.onclick = () => { if (UPDATE_INFO && UPDATE_INFO.download) api('/api/openurl', { url: UPDATE_INFO.download }); };
  // 오버레이 클릭(빈 곳)으로 닫기 허용
  $('#force-update').onclick = (e) => { if (e.target.id === 'force-update') { $('#force-update').hidden = true; UPDATE_STATE = 'cannot'; showCheckNote(true); } };
}

/* ---------- 생존 신호 ----------
   창을 닫으면 핑이 끊기고, 서버가 30초 뒤 스스로 종료한다.
   (닫힘 신호를 즉시 보내면 F5 새로고침에도 발사되어 앱이 죽는다 - 절대 넣지 말 것) */
setInterval(() => fetch('/api/ping').catch(() => {}), 3000);

/* ---------- 시작 ---------- */
rescan(false);
checkUpdate();   // 새 버전이면 자동 강제 업데이트, 확인 불가면 구석에 작게 안내
