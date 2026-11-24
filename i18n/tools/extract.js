// Linear single-pass extraction of string literals from JS bundles.
// Avoids backtracking regex; runs O(n) per file.
const fs = require('fs');
const path = require('path');

const dir = process.argv[2] || 'C:/pentagi/fe/assets';
const out = process.argv[3] || 'C:/pentagi/i18n/candidates.json';

const files = fs.readdirSync(dir).filter(f => f.endsWith('.js'));

function extractLiterals(src) {
  const res = [];
  let i = 0;
  const n = src.length;
  while (i < n) {
    const c = src.charCodeAt(i);
    // " 39 ' 96 `
    if (c === 34 || c === 39 || c === 96) {
      const q = c;
      let j = i + 1;
      let buf = '';
      let ok = true;
      while (j < n) {
        const d = src.charCodeAt(j);
        if (d === 92) { // backslash
          const e = src.charCodeAt(j + 1);
          if (e === 110) buf += '\n';
          else if (e === 116) buf += '\t';
          else buf += String.fromCharCode(e || 0);
          j += 2;
          continue;
        }
        if (d === q) break;
        if (d === 10) { ok = false; break; } // unterminated / template literal with newline
        buf += src[j];
        j++;
        if (buf.length > 600) { ok = false; break; }
      }
      if (ok && j < n && buf.length >= 2) res.push(buf);
      i = j + 1;
      continue;
    }
    i++;
  }
  return res;
}

const denyExact = new Set([
  'string','number','boolean','object','function','undefined','default',
  'button','submit','radio','checkbox','text','password','email',
  'true','false','null','GET','POST','PUT','DELETE','PATCH','HEAD',
]);

function looksHuman(s) {
  if (s.length < 3 || s.length > 300) return false;
  if (denyExact.has(s)) return false;
  if (!/[A-Za-z]/.test(s)) return false;
  if (/[{};=<>|&$\\^~@#`]/.test(s)) return false;
  if (/^[\d\s.,:%+-]+$/.test(s)) return false;
  if (/^(?:https?:|\/|\.\/|data:|blob:)/.test(s)) return false;
  if (/\.[a-z]{2,5}$/.test(s) && !/\s/.test(s)) return false; // filenames
  if (/^[a-z0-9-]+$/.test(s)) return false;                  // lowercase token
  if (/^[A-Za-z0-9]+$/.test(s) && s.length < 12) return false; // single token
  const hasSpace = /\s/.test(s);
  if (!hasSpace) {
    // allow only Title Case single words that look like labels
    if (!/^[A-Z][a-z]{2,}$/.test(s)) return false;
  }
  // reject tailwind chains: many lowercase hyphenated tokens separated by spaces
  const toks = s.trim().split(/\s+/);
  if (toks.length >= 2 && toks.every(t => /^[a-z0-9:./[\]-]+$/.test(t))) return false;
  const letters = (s.match(/[A-Za-z]/g) || []).length;
  if (letters / s.length < 0.5) return false;
  return true;
}

const counts = new Map();
for (const f of files) {
  let src;
  try { src = fs.readFileSync(path.join(dir, f), 'utf8'); } catch { continue; }
  for (const s of extractLiterals(src)) {
    if (!looksHuman(s)) continue;
    let e = counts.get(s);
    if (!e) { e = { n: 0, files: [] }; counts.set(s, e); }
    e.n++;
    if (e.files.length < 3 && !e.files.includes(f)) e.files.push(f);
  }
}

const rows = [...counts.entries()]
  .map(([s, v]) => ({ s, n: v.n, files: v.files }))
  .sort((a, b) => b.n - a.n || a.s.localeCompare(b.s));

fs.mkdirSync(path.dirname(out), { recursive: true });
fs.writeFileSync(out, JSON.stringify(rows, null, 2), 'utf8');

console.log('files:', files.length, 'candidates:', rows.length);
for (const r of rows.slice(0, 60)) console.log(`[${r.n}] ${r.s}`);
