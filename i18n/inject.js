/* PentAGI 简体中文注入层
 *
 * 设计要点：
 * 1. 不修改原始 bundle，全部在 DOM 层完成，升级镜像不受影响。
 * 2. React 每次重渲染都会写回英文原文，因此必须用 MutationObserver 持续校正。
 * 3. 文本节点与属性分开判断：INPUT/TEXTAREA 自身的文本要跳过，
 *    但它们的 placeholder 必须翻译。
 * 4. 已翻译节点打标记，避免观察者自触发形成死循环。
 */
(function () {
  'use strict';

  var DICT = window.__PENTAGI_ZH_DICT__ || {};
  var KEYS = Object.keys(DICT).sort(function (a, b) { return b.length - a.length; });

  // 拼接型文案的前后缀（"Are you sure you want to " 之类）
  var AFFIX = KEYS.filter(function (k) { return k.length >= 8; });

  // 这些标签内部的「文本」永不翻译
  var TEXT_SKIP = {
    SCRIPT: 1, STYLE: 1, NOSCRIPT: 1, CODE: 1, PRE: 1,
    TEXTAREA: 1, INPUT: 1, SVG: 1, PATH: 1, CANVAS: 1, IFRAME: 1,
    KBD: 1, SAMP: 1,
  };
  // 这些标签连属性也不碰
  var ATTR_SKIP = { SCRIPT: 1, STYLE: 1, NOSCRIPT: 1 };

  var ATTRS = ['placeholder', 'title', 'aria-label', 'alt', 'aria-description', 'label'];

  // 版本/更新相关外链改指向自有仓库
  var REPO_OLD = 'github.com/vxcontrol/pentagi';
  var REPO_NEW = 'github.com/001ship/luckypen';

  function fixUrl(u) {
    if (typeof u !== 'string') return u;
    return u.split(REPO_OLD).join(REPO_NEW);
  }

  function rewriteLink(el) {
    if (!el || el.tagName !== 'A') return;
    var h = el.getAttribute('href');
    if (h && h.indexOf(REPO_OLD) >= 0) el.setAttribute('href', fixUrl(h));
  }

  // 前端有些跳转走 window.open，DOM 层拦不住，这里挂一层
  (function hookOpen() {
    var orig = window.open;
    if (typeof orig !== 'function') return;
    window.open = function (url) {
      var args = Array.prototype.slice.call(arguments);
      if (typeof url === 'string') args[0] = fixUrl(url);
      return orig.apply(window, args);
    };
  })();
  var CACHE_LIMIT = 6000;
  var cache = new Map();
  var HAN = /[\u4e00-\u9fff]/;

  function longestAffix(t) {
    for (var i = 0; i < AFFIX.length; i++) {
      var k = AFFIX[i];
      if (t.length <= k.length) continue;
      if (t.indexOf(k) === 0) return { head: k, rest: t.slice(k.length) };
      if (t.slice(-k.length) === k) return { tail: k, rest: t.slice(0, t.length - k.length) };
    }
    return null;
  }

  var MONTH_FULL = ['January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December'];
  var MONTH_ABBR = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

  function monthIndex(name) {
    var i = MONTH_FULL.indexOf(name);
    if (i >= 0) return i;
    i = MONTH_ABBR.indexOf(name);
    return i;
  }

  // 把常见的英文日期写法本地化为中文
  function trDate(t) {
    var m, i;
    // November 2026
    m = t.match(/^([A-Z][a-z]{2,8})\s+(\d{4})$/);
    if (m) { i = monthIndex(m[1]); if (i >= 0) return m[2] + '年' + (i + 1) + '月'; }

    // 12 November 2026 / 12 Nov 2026
    m = t.match(/^(\d{1,2})\s+([A-Z][a-z]{2,8})\s+(\d{4})$/);
    if (m) { i = monthIndex(m[2]); if (i >= 0) return m[3] + '年' + (i + 1) + '月' + parseInt(m[1], 10) + '日'; }

    // November 12, 2026
    m = t.match(/^([A-Z][a-z]{2,8})\s+(\d{1,2}),?\s+(\d{4})$/);
    if (m) { i = monthIndex(m[1]); if (i >= 0) return m[3] + '年' + (i + 1) + '月' + parseInt(m[2], 10) + '日'; }

    // 01 Nov 2026, 14:30
    m = t.match(/^(\d{1,2})\s+([A-Z][a-z]{2,8})\s+(\d{4}),?\s+(\d{2}:\d{2})$/);
    if (m) { i = monthIndex(m[2]); if (i >= 0) return m[3] + '年' + (i + 1) + '月' + parseInt(m[1], 10) + '日 ' + m[4]; }

    // Nov 2026
    m = t.match(/^([A-Z][a-z]{2})\s+(\d{4})$/);
    if (m) { i = monthIndex(m[1]); if (i >= 0) return m[2] + '年' + (i + 1) + '月'; }

    return null;
  }

  // 相对时间："10 minutes ago" -> "10 分钟前"
  var REL_UNITS = {
    second: '秒', minute: '分钟', hour: '小时', day: '天',
    week: '周', month: '个月', year: '年',
  };

  function trRelative(t) {
    var m = t.match(/^(?:about |in )?(\d+)\s+(second|minute|hour|day|week|month|year)s?\s+ago$/i);
    if (m) {
      var u = REL_UNITS[m[2].toLowerCase()];
      if (u) return m[1] + ' ' + u + '前';
    }
    m = t.match(/^a few (second|minute|hour|day)s? ago$/i);
    if (m) {
      var u2 = REL_UNITS[m[1].toLowerCase()];
      if (u2) return '几' + u2 + '前';
    }
    if (/^just now$/i.test(t)) return '刚刚';
    if (/^yesterday$/i.test(t)) return '昨天';
    if (/^less than a minute ago$/i.test(t)) return '不到一分钟前';
    return null;
  }

  function tr(text) {
    if (!text) return null;
    var t = text.trim();
    if (!t) return null;
    if (HAN.test(t)) return null;
    if (t.length > 300) return null;

    if (cache.has(t)) return cache.get(t);

    var out = trDate(t);
    if (out === null) out = trRelative(t);
    if (out === null) {
      var bm = t.match(/^build\s+([0-9a-f]{5,})$/i);
      if (bm) out = '构建 ' + bm[1];
    }
    if (out !== null) {
      if (cache.size > CACHE_LIMIT) cache.clear();
      cache.set(t, out);
      return out;
    }
    if (Object.prototype.hasOwnProperty.call(DICT, t)) {
      out = DICT[t];
    } else {
      var a = longestAffix(t);
      if (a) {
        if (a.head !== undefined) out = DICT[a.head] + a.rest;
        else if (DICT[a.tail] !== undefined) out = a.rest + DICT[a.tail];
      }
    }

    if (cache.size > CACHE_LIMIT) cache.clear();
    cache.set(t, out);
    return out;
  }

  function skipText(el) {
    if (!el || el.nodeType !== 1) return true;
    if (TEXT_SKIP[el.tagName]) return true;
    if (el.isContentEditable) return true;
    if (el.closest && el.closest('.xterm, .monaco-editor, [contenteditable="true"], [data-no-i18n]')) return true;
    return false;
  }

  function skipAttr(el) {
    if (!el || el.nodeType !== 1) return true;
    if (ATTR_SKIP[el.tagName]) return true;
    if (el.closest && el.closest('#root script, #root style, .xterm, [data-no-i18n]')) return true;
    return false;
  }

  function translateTextNode(node) {
    var parent = node.parentNode;
    if (!parent || skipText(parent)) return;
    var raw = node.nodeValue;
    if (!raw) return;
    var next = tr(raw);
    if (next === null) return;
    var lead = (raw.match(/^\s*/) || [''])[0];
    var tail = (raw.match(/\s*$/) || [''])[0];
    node.nodeValue = lead + next + tail;
  }

  function translateAttrs(el) {
    if (skipAttr(el)) return;
    if (!el.getAttribute) return;
    for (var i = 0; i < ATTRS.length; i++) {
      var name = ATTRS[i];
      var v = el.getAttribute(name);
      if (!v) continue;
      // select/option 的 label 属性仅在无文本时使用
      var next = tr(v);
      if (next !== null && next !== v) el.setAttribute(name, next);
    }
    // React 会通过 property 写 value，placeholder 有时同步到 dataset
    if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') {
      var ph = el.getAttribute('placeholder');
      if (ph) {
        var phz = tr(ph);
        if (phz !== null && phz !== ph) el.setAttribute('placeholder', phz);
      }
    }
  }

  function walk(root) {
    if (!root) return;
    if (root.nodeType === 3) { translateTextNode(root); return; }
    if (root.nodeType !== 1) return;

    translateAttrs(root);
    rewriteLink(root);
    if (skipText(root)) return;

    var kids = root.childNodes;
    for (var i = 0; i < kids.length; i++) walk(kids[i]);
  }

  var pending = false;
  var queue = [];

  function flush() {
    pending = false;
    var batch = queue;
    queue = [];
    for (var i = 0; i < batch.length; i++) {
      try { walk(batch[i]); } catch (e) { /* 单节点失败不影响整体 */ }
    }
  }

  function schedule(node) {
    if (!node) return;
    queue.push(node);
    if (pending) return;
    pending = true;
    if (window.requestAnimationFrame) window.requestAnimationFrame(flush);
    else window.setTimeout(flush, 0);
  }

  function boot() {
    walk(document.body);

    var mo = new MutationObserver(function (records) {
      for (var i = 0; i < records.length; i++) {
        var r = records[i];
        if (r.type === 'characterData') {
          schedule(r.target);
        } else if (r.type === 'attributes') {
          schedule(r.target);
        } else if (r.addedNodes) {
          for (var j = 0; j < r.addedNodes.length; j++) schedule(r.addedNodes[j]);
        }
      }
    });

    mo.observe(document.body, {
      childList: true,
      subtree: true,
      characterData: true,
      attributes: true,
      attributeFilter: ATTRS
    });

    // 兜底：部分同步渲染路径观察者抓不到
    [150, 600, 1500, 3500, 7000].forEach(function (ms) {
      setTimeout(function () { walk(document.body); }, ms);
    });

    document.documentElement.setAttribute('lang', 'zh-CN');
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot);
  } else {
    boot();
  }
})();
