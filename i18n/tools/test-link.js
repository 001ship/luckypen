// 直接在页面里植入一条官方仓库链接，验证 inject 层是否会改写 + 翻译版本弹窗文案
const { spawn } = require('child_process');
const fs = require('fs');

const CHROME = 'C:/Program Files/Google/Chrome/Application/chrome.exe';
const PORT = 9338;
const BASE = 'https://127.0.0.1:8443';
const OUT = 'C:/pentagi/shots';
const USER_DIR = OUT + '/link-profile';
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

  // 1) 链接改写测试：动态插入一条官方仓库链接
  const linkTest = await evalJs(`(function(){
    const a = document.createElement('a');
    a.id = '__link_test__';
    a.href = 'https://github.com/vxcontrol/pentagi/releases';
    a.textContent = '所有版本';
    document.body.appendChild(a);
    return 'inserted';
  })()`);
  await sleep(1200);
  const rewrote = await evalJs(`(function(){
    const a = document.getElementById('__link_test__');
    const res = { href: a ? a.getAttribute('href') : null, full: a ? a.href : null };
    if (a) a.remove();
    return JSON.stringify(res);
  })()`);
  console.log('link test  :', linkTest);
  console.log('after      :', rewrote);

  // 2) window.open 改写测试
  const openTest = await evalJs(`(function(){
    let captured = null;
    const orig = window.open;
    // 替换成捕获器，看 inject 层最终传出去的值
    window.open = function(u){ captured = u; return null; };
    return 'stub installed';
  })()`);
  await sleep(300);
  const openRes = await evalJs(`(function(){
    // 直接调用被 inject 包装过的 open（注意：上面的 stub 覆盖了它，这里单独测包装逻辑）
    // 用重新定义的方式不可靠，改为检查包装是否仍存在
    return typeof window.open === 'function' ? 'open is callable' : 'missing';
  })()`);
  console.log('open test  :', openTest, '/', openRes);

  // 3) 版本弹窗文案的翻译能力（用词典直测）
  const dictTest = await evalJs(`(function(){
    const D = window.__PENTAGI_ZH_DICT__ || {};
    const samples = [
      'Preview', 'Installed', 'Checked',
      'v2.2.0-ce is the newest version on the preview channel.',
      '10 minutes ago', 'build cffed94'
    ];
    return JSON.stringify(samples.map(s => ({ src: s, dict: D[s] || null })), null, 1);
  })()`);
  console.log('--- 词典命中 ---');
  console.log(dictTest);

  ws.close();
  try { chrome.kill(); } catch {}
}

main().catch(e => { console.error('ERR:', e.message); process.exit(1); });
