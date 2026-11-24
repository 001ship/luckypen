// 把界面上的产品名从 PentAGI 改为 lucky自动化工具
const fs = require('fs');
const path = require('path');

const BRAND = 'lucky自动化工具';

function patchHtml(file) {
  let h = fs.readFileSync(file, 'utf8');
  const before = (h.match(/<title>[^<]*<\/title>/) || [''])[0];
  // 无论原来是什么 title，直接换成新品牌
  h = h.replace(/<title>[^<]*<\/title>/, `<title>${BRAND}</title>`);
  fs.writeFileSync(file, h, 'utf8');
  const after = (h.match(/<title>[^<]*<\/title>/) || [''])[0];
  console.log(`  html: ${path.basename(file)}`);
  console.log(`        before: ${before}`);
  console.log(`        after : ${after}`);
}

function patchDict(file) {
  let s = fs.readFileSync(file, 'utf8');
  let changed = 0;

  // 1) 独立的 “PentAGI” 文本节点（登录页大标题 / 侧边栏标题）
  if (/^\s*"PentAGI":/m.test(s)) {
    s = s.replace(/^(\s*)"PentAGI":\s*"[^"]*",/m, `$1"PentAGI": "${BRAND}",`);
    changed++;
  } else {
    // 插到对象开头之后，保证优先级
    s = s.replace(
      /(window\.__PENTAGI_ZH_DICT__\s*=\s*\{\n)/,
      `$1  "PentAGI": "${BRAND}",\n`
    );
    changed++;
  }

  // 2) 带前缀的拼接片段 "PentAGI "（用于 "PentAGI v2.2.0-ce" 之类）
  if (/^\s*"PentAGI "\s*:/m.test(s)) {
    s = s.replace(/^(\s*)"PentAGI "\s*:\s*"[^"]*",/m, `$1"PentAGI ": "${BRAND} ",`);
    changed++;
  }

  // 3) 已经译好的整句里也统一品牌名
  s = s.replace(/"PentAGI 正在工作\.\.\. 点击停止以中断"/g, `"${BRAND} 正在工作... 点击停止以中断"`);
  s = s.replace(/"PentAGI 已是最新版本"/g, `"${BRAND} 已是最新版本"`);
  s = s.replace(/"PentAGI 智能体/g, `"${BRAND} 智能体`);

  fs.writeFileSync(file, s, 'utf8');
  console.log(`  dict: ${path.basename(file)}  patches=${changed}`);
}

const targets = process.argv.slice(2);
for (const t of targets) {
  console.log(`--> ${t}`);
  if (t.endsWith('.html')) patchHtml(t);
  else patchDict(t);
}
