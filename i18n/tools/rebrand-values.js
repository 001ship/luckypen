// 把词典「值」里残留的 PentAGI 统一替换为新品牌名，键（英文原文）不动。
const fs = require('fs');

const BRAND = 'lucky自动化工具';
const file = process.argv[2];
const raw = fs.readFileSync(file, 'utf8');

let count = 0;
const out = raw.split(/\r?\n/).map(line => {
  // 只处理形如   "English key": "中文值",  的行
  const m = line.match(/^(\s*"[^"]*"\s*:\s*")(.*)("\s*,?\s*)$/);
  if (!m) return line;
  const [, head, value, tail] = m;
  if (!value.includes('PentAGI')) return line;
  if (value.includes(BRAND)) return line;          // 已经改过
  count++;
  return head + value.split('PentAGI').join(BRAND) + tail;
}).join('\n');

fs.writeFileSync(file, out, 'utf8');
console.log(`replaced in ${count} values`);

// 打印改后的结果供核对
const check = out.split('\n').filter(l => l.includes('lucky'));
console.log('--- 含新品牌名的条目 ---');
check.forEach(l => console.log('  ' + l.trim().slice(0, 140)));
