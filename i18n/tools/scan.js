// Scan all routes for text that is still English after the zh injector ran.
const { spawn } = require('child_process');
const fs = require('fs');

const CHROME = 'C:/Program Files/Google/Chrome/Application/chrome.exe';
const PORT = 9334;
const BASE = 'https://127.0.0.1:8443';
const USER_DIR = 'C:/pentagi/shots/scan-profile';

const sleep = ms => new Promise(r => setTimeout(r, ms));

async function waitJson(url, tries = 80) {
  for (let i = 0; i < tries; i++) {
    try { const r = await fetch(url); if (r.ok) return await r.json(); } catch {}
    await sleep(250);
  }
  throw new Error('devtools never came up');
}

async function main() {
  fs.rmSync(USER_DIR, { recursive: true, force: true });
  const chrome = spawn(CHROME, [
    '--headless=new', '--disable-gpu', '--no-sandbox',
    '--ignore-certificate-errors', '--allow-insecure-localhost',
    '--hide-scrollbars', '--disable-dev-shm-usage',
    '--window-size=1600,1000',
    `--remote-debugging-port=${PORT}`,
    `--user-data-dir=${USER_DIR}`,
    'about:blank',
  ], { stdio: 'ignore' });
  process.on('exit', () => { try { chrome.kill(); } catch {} });

  await waitJson(`http://127.0.0.1:${PORT}/json/version`);
  const list = await (await fetch(`http://127.0.0.1:${PORT}/json/list`)).json();
  const page = list.find(t => t.type === 'page');
  const ws = new WebSocket(page.webSocketDebuggerUrl);
  await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });

  let id = 0; const pending = new Map();
  ws.onmessage = ev => {
    let m; try { m = JSON.parse(ev.data); } catch { return; }
    if (m.id && pending.has(m.id)) {
      const p = pending.get(m.id); pending.delete(m.id);
      m.error ? p.rej(new Error(JSON.stringify(m.error))) : p.res(m.result);
    }
  };
  const send = (method, params = {}) => new Promise((res, rej) => {
    const mid = ++id; pending.set(mid, { res, rej });
    ws.send(JSON.stringify({ id: mid, method, params }));
    setTimeout(() => { if (pending.has(mid)) { pending.delete(mid); rej(new Error('timeout ' + method)); } }, 25000);
  });
  const evalJs = async expr => {
    const r = await send('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true });
    if (r.exceptionDetails) throw new Error('eval: ' + JSON.stringify(r.exceptionDetails).slice(0, 200));
    return r.result && r.result.value;
  };

  await send('Page.enable'); await send('Runtime.enable');

  // login once
  await send('Page.navigate', { url: BASE + '/login' });
  await sleep(3500);
  await evalJs(`(function(){
    const set=(el,v)=>{const s=Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set;s.call(el,v);el.dispatchEvent(new Event('input',{bubbles:true}));};
    const i=Array.from(document.querySelectorAll('input'));
    const e=i.find(x=>x.type==='email')||i[0], p=i.find(x=>x.type==='password')||i[1];
    set(e,'admin@pentagi.com'); set(p,'admin');
    const b=Array.from(document.querySelectorAll('button')).find(b=>/登录|Sign in|Login/i.test(b.textContent||''));
    if(b) b.click();
    return 'ok';
  })()`);
  await sleep(5000);

  const COLLECT = `(function(){
    const seen = new Map();
    const HAN = /[\\u4e00-\\u9fff]/;
    const skipTags = {SCRIPT:1,STYLE:1,CODE:1,PRE:1,TEXTAREA:1,SVG:1,PATH:1,KBD:1,SAMP:1};
    const skipCls = '.xterm,.monaco-editor,[contenteditable="true"],.hljs';
    function add(s, where){
      const t=(s||'').trim();
      if(!t||t.length<2||t.length>160) return;
      if(HAN.test(t)) return;
      if(!/[A-Za-z]/.test(t)) return;
      if(/^[\\d\\s.,:%+\\-()\\/]+$/.test(t)) return;
      if(/^[\\w.+-]+@[\\w.-]+$/.test(t)) return;
      if(/^https?:|^www\\.|^\\/(api|assets)/.test(t)) return;
      if(/^(v?\\d+\\.\\d+|\\d+(\\.\\d+)?(ms|s|KB|MB|GB|%|tokens?|k))$/i.test(t)) return;
      if(/^[0-9a-f]{8,}$/i.test(t)) return;
      const k=t;
      if(!seen.has(k)) seen.set(k, where);
    }
    const walker=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT,null);
    let n;
    while((n=walker.nextNode())){
      const p=n.parentElement;
      if(!p) continue;
      if(skipTags[p.tagName]) continue;
      if(p.closest&&p.closest(skipCls)) continue;
      add(n.nodeValue,'text');
    }
    document.querySelectorAll('[placeholder],[title],[aria-label],[alt]').forEach(el=>{
      ['placeholder','title','aria-label','alt'].forEach(a=>{
        const v=el.getAttribute(a);
        if(v) add(v,'@'+a);
      });
    });
    return JSON.stringify([...seen.entries()]);
  })()`;

  const routes = [
    '/dashboard', '/flows', '/templates', '/resources', '/knowledge',
    '/settings/account', '/settings/providers', '/settings/prompts', '/settings/tokens',
  ];

  const all = new Map();
  for (const r of routes) {
    await send('Page.navigate', { url: BASE + r });
    await sleep(3500);
    await evalJs(`(function(){const b=Array.from(document.querySelectorAll('button')).find(b=>/暂时跳过|Skip for now/i.test(b.textContent||''));if(b)b.click();return 1;})()`);
    await sleep(800);
    try {
      const raw = await evalJs(COLLECT);
      const arr = JSON.parse(raw);
      console.log('== ' + r + ' -> ' + arr.length + ' pending');
      for (const [s, w] of arr) {
        if (!all.has(s)) all.set(s, { where: w, routes: [] });
        all.get(s).routes.push(r);
      }
    } catch (e) {
      console.log('== ' + r + ' FAILED: ' + e.message);
    }
  }

  const rows = [...all.entries()].sort((a, b) => a[0].localeCompare(b[0]));
  fs.writeFileSync('C:/pentagi/i18n/pending.json', JSON.stringify(rows.map(([s, v]) => ({ s, where: v.where, routes: v.routes })), null, 2), 'utf8');
  fs.writeFileSync('C:/pentagi/i18n/pending.txt', rows.map(([s]) => s).join('\n'), 'utf8');
  console.log('\n=== TOTAL PENDING: ' + rows.length + ' ===');

  ws.close();
  try { chrome.kill(); } catch {}
}

main().catch(e => { console.error('ERR:', e.message); process.exit(1); });
