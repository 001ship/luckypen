// 端到端：把版本弹窗里那几条英文真实插入 DOM，看 inject 层是否翻译
const { spawn } = require('child_process');
const fs = require('fs');

const CHROME = 'C:/Program Files/Google/Chrome/Application/chrome.exe';
const PORT = 9339;
const BASE = 'https://127.0.0.1:8443';
const OUT = 'C:/pentagi/shots';
const USER_DIR = OUT + '/dom-profile';
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
    `--remote-debugging-port=${PORT}`, `--user-data-dir=${USER_DIR}`, 'about:blank',
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
    if (r.exceptionDetails) throw new Error('eval: ' + JSON.stringify(r.exceptionDetails).slice(0, 250));
    return r.result && r.result.value;
  };

  await send('Page.enable'); await send('Runtime.enable');
  await send('Page.navigate', { url: BASE + '/login' });
  await sleep(3500);
  await evalJs(`(function(){
    const set=(el,v)=>{const s=Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set;s.call(el,v);el.dispatchEvent(new Event('input',{bubbles:true}));};
    const i=Array.from(document.querySelectorAll('input'));
    set(i.find(x=>x.type==='email')||i[0],'admin@pentagi.com');
    set(i.find(x=>x.type==='password')||i[1],'admin');
    const b=Array.from(document.querySelectorAll('button')).find(b=>/登录|Sign in/i.test(b.textContent||''));
    if(b) b.click(); return 1;
  })()`);
  await sleep(5000);
  await evalJs(`(function(){const b=Array.from(document.querySelectorAll('button')).find(b=>/暂时跳过|Skip for now/i.test(b.textContent||''));if(b)b.click();return 1;})()`);
  await sleep(1500);

  const samples = [
    'Preview',
    'Installed',
    'Checked',
    '10 minutes ago',
    'build cffed94',
    'v2.2.0-ce is the newest version on the preview channel.',
    'PentAGI v2.2.0-ce',
    'All releases',
  ];

  await evalJs(`(function(){
    const box = document.createElement('div');
    box.id = '__probe_box__';
    box.style.cssText = 'position:fixed;left:-9999px;top:0';
    ${JSON.stringify(samples)}.forEach((t, i) => {
      const s = document.createElement('span');
      s.id = '__probe_' + i + '__';
      s.textContent = t;
      box.appendChild(s);
    });
    document.body.appendChild(box);
    return 1;
  })()`);
  await sleep(2000);

  const result = await evalJs(`(function(){
    const out = [];
    ${JSON.stringify(samples)}.forEach((t, i) => {
      const el = document.getElementById('__probe_' + i + '__');
      out.push({ src: t, out: el ? el.textContent : '(missing)' });
    });
    const box = document.getElementById('__probe_box__');
    if (box) box.remove();
    return JSON.stringify(out, null, 1);
  })()`);

  console.log('--- DOM 端到端翻译结果 ---');
  console.log(result);

  ws.close();
  try { chrome.kill(); } catch {}
}

main().catch(e => { console.error('ERR:', e.message); process.exit(1); });
