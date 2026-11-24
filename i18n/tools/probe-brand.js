// 登录后定位：侧边栏品牌名、版本弹窗内容与其中的外链
const { spawn } = require('child_process');
const fs = require('fs');

const CHROME = 'C:/Program Files/Google/Chrome/Application/chrome.exe';
const PORT = 9336;
const BASE = 'https://127.0.0.1:8443';
const OUT = 'C:/pentagi/shots';
const USER_DIR = OUT + '/probe-profile';

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
    if (r.exceptionDetails) throw new Error('eval: ' + JSON.stringify(r.exceptionDetails).slice(0, 250));
    return r.result && r.result.value;
  };
  const shot = async name => {
    const r = await send('Page.captureScreenshot', { format: 'png' });
    fs.writeFileSync(OUT + '/' + name, Buffer.from(r.data, 'base64'));
    console.log('  shot:', name);
  };

  await send('Page.enable'); await send('Runtime.enable');

  // 登录
  await send('Page.navigate', { url: BASE + '/login' });
  await sleep(3500);
  await evalJs(`(function(){
    const set=(el,v)=>{const s=Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set;s.call(el,v);el.dispatchEvent(new Event('input',{bubbles:true}));};
    const i=Array.from(document.querySelectorAll('input'));
    const e=i.find(x=>x.type==='email')||i[0], p=i.find(x=>x.type==='password')||i[1];
    set(e,'admin@pentagi.com'); set(p,'admin');
    const b=Array.from(document.querySelectorAll('button')).find(b=>/登录|Sign in|Login/i.test(b.textContent||''));
    if(b) b.click(); return 'ok';
  })()`);
  await sleep(5000);
  await evalJs(`(function(){const b=Array.from(document.querySelectorAll('button')).find(b=>/暂时跳过|Skip for now/i.test(b.textContent||''));if(b)b.click();return 1;})()`);
  await sleep(1500);

  // 侧边栏区域：找出含 PentAGI 的文本节点及其父元素
  const brandProbe = await evalJs(`(function(){
    const out = [];
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
    let n;
    while ((n = walker.nextNode())) {
      const t = n.nodeValue || '';
      if (!/PentAGI|lucky/i.test(t)) continue;
      const p = n.parentElement;
      out.push({
        text: t.trim().slice(0, 80),
        tag: p ? p.tagName : '?',
        cls: p ? (p.className || '').toString().slice(0, 80) : '',
        parentText: p && p.parentElement ? (p.parentElement.innerText || '').replace(/\\n/g,' | ').slice(0, 100) : ''
      });
      if (out.length >= 15) break;
    }
    return JSON.stringify(out, null, 1);
  })()`);
  console.log('--- 品牌名文本节点 ---');
  console.log(brandProbe);

  // 所有外链
  const links = await evalJs(`(function(){
    return JSON.stringify(Array.from(document.querySelectorAll('a[href]'))
      .map(a => ({href: a.href, text: (a.innerText||'').trim().slice(0,60)}))
      .filter(x => !x.href.includes('127.0.0.1'))
      .slice(0, 25), null, 1);
  })()`);
  console.log('--- 外部链接 ---');
  console.log(links);

  await shot('probe-sidebar.png');

  // 点开左下角的版本选择器（截图里带箭头的那个）
  const opened = await evalJs(`(function(){
    const cands = Array.from(document.querySelectorAll('button,[role="combobox"],[data-slot="trigger"],div[aria-haspopup]'));
    const hit = cands.find(b => /PentAGI|v2\\.2\\.0|lucky/.test((b.innerText||'')) && (b.innerText||'').length < 60);
    if (!hit) return 'not found';
    hit.click();
    return 'clicked: ' + (hit.innerText||'').replace(/\\n/g,' | ').slice(0,60);
  })()`);
  console.log('--- 版本弹窗 ---');
  console.log(opened);
  await sleep(2500);

  const popup = await evalJs(`(function(){
    const t = document.body.innerText || '';
    const i = t.indexOf('build');
    return i >= 0 ? t.slice(Math.max(0,i-120), i+400) : t.slice(0, 400);
  })()`);
  console.log(popup);

  const popupLinks = await evalJs(`(function(){
    return JSON.stringify(Array.from(document.querySelectorAll('a[href]'))
      .map(a => ({href: a.href, text: (a.innerText||'').trim().slice(0,50)}))
      .filter(x => /github|pentagi|vxcontrol/i.test(x.href)), null, 1);
  })()`);
  console.log('--- 弹窗内链接 ---');
  console.log(popupLinks);

  await shot('probe-version-popup.png');

  ws.close();
  try { chrome.kill(); } catch {}
}

main().catch(e => { console.error('ERR:', e.message); process.exit(1); });
