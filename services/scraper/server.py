#!/usr/bin/env python3
"""PentAGI scraper replacement.

PentAGI's browser tool calls four GET endpoints on the scraper service:

    GET /markdown?url=<target>            -> text/markdown body
    GET /html?url=<target>                -> text/html body
    GET /links?url=<target>               -> JSON [{"Title": str, "Link": str}, ...]
    GET /screenshot?fullPage=true&url=... -> image/png bytes

This process serves the same contract using a headless Chromium driven by
Playwright, so agents get a real browser (JS execution, redirects, cookies)
without pulling vxcontrol/scraper from Docker Hub.
"""
import base64
import json
import os
import re
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs, unquote

PORT = int(os.environ.get("SCRAPER_PORT", "8081"))
NAV_TIMEOUT = int(os.environ.get("SCRAPER_NAV_TIMEOUT", "30000"))
WAIT_MS = int(os.environ.get("SCRAPER_WAIT_MS", "1500"))
MAX_BYTES = int(os.environ.get("SCRAPER_MAX_BYTES", str(20 * 1024 * 1024)))
USER = os.environ.get("SCRAPER_USER", "")
PASS = os.environ.get("SCRAPER_PASS", "")

UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
)

try:
    from playwright.sync_api import sync_playwright
except Exception as exc:  # noqa: BLE001
    print(f"FATAL: playwright missing: {exc}", flush=True)
    sys.exit(1)

try:
    import html2text
    _H2T = html2text.HTML2Text()
    _H2T.ignore_images = False
    _H2T.ignore_links = False
    _H2T.body_width = 0
except Exception:  # noqa: BLE001
    _H2T = None

_pw = None
_browser = None
_lock = threading.Lock()


def start_browser():
    global _pw, _browser
    _pw = sync_playwright().start()
    launch_kwargs = {
        "headless": True,
        "args": [
            "--no-sandbox",
            "--disable-dev-shm-usage",
            "--disable-gpu",
            "--ignore-certificate-errors",
        ],
    }
    # 允许指向手工解压的 Chrome for Testing，绕开 playwright 自带浏览器下载
    chrome_path = os.environ.get("SCRAPER_CHROME", "")
    if chrome_path and os.path.exists(chrome_path):
        launch_kwargs["executable_path"] = chrome_path
        print(f"using external chrome: {chrome_path}", flush=True)
    _browser = _pw.chromium.launch(**launch_kwargs)
    print("chromium started", flush=True)


def ensure_browser():
    if _browser is None or not _browser.is_connected():
        start_browser()


def html_to_markdown(html, base_url=""):
    if _H2T is not None:
        try:
            return _H2T.handle(html)
        except Exception:  # noqa: BLE001
            pass
    # 退化实现：去脚本样式，粗转标题/链接
    text = re.sub(r"(?is)<(script|style|noscript)[^>]*>.*?</\1>", " ", html)
    text = re.sub(r"(?is)<h([1-6])[^>]*>(.*?)</h\1>", lambda m: "\n" + "#" * int(m.group(1)) + " " + re.sub(r"<[^>]+>", "", m.group(2)) + "\n", text)
    text = re.sub(r"(?is)<a[^>]+href=[\"']([^\"']+)[\"'][^>]*>(.*?)</a>", lambda m: f"[{re.sub(r'<[^>]+>', '', m.group(2))}]({m.group(1)})", text)
    text = re.sub(r"(?is)<li[^>]*>", "\n- ", text)
    text = re.sub(r"(?is)<br\s*/?>", "\n", text)
    text = re.sub(r"(?is)</p>", "\n\n", text)
    text = re.sub(r"(?is)<[^>]+>", "", text)
    text = re.sub(r"[ \t]+", " ", text)
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip()


def render(url, want="html"):
    """Render url in a fresh context; returns (payload, content_type)."""
    with _lock:
        ensure_browser()
        ctx = _browser.new_context(
            user_agent=UA,
            ignore_https_errors=True,
            viewport={"width": 1366, "height": 900},
        )
        try:
            page = ctx.new_page()
            page.set_default_timeout(NAV_TIMEOUT)
            try:
                page.goto(url, wait_until="domcontentloaded", timeout=NAV_TIMEOUT)
            except Exception as exc:  # noqa: BLE001
                # 已部分加载的页面仍可尝试取内容
                body = ""
                try:
                    body = page.content()
                except Exception:  # noqa: BLE001
                    pass
                if len(body) < 200:
                    raise RuntimeError(f"navigation failed: {exc}") from exc

            try:
                page.wait_for_load_state("networkidle", timeout=min(8000, NAV_TIMEOUT))
            except Exception:  # noqa: BLE001
                pass
            page.wait_for_timeout(WAIT_MS)

            final_url = page.url or url

            if want == "html":
                return page.content().encode("utf-8"), "text/html; charset=utf-8"

            if want == "markdown":
                html = page.content()
                md = html_to_markdown(html, final_url)
                return md.encode("utf-8"), "text/markdown; charset=utf-8"

            if want == "links":
                raw = page.evaluate(
                    """() => Array.from(document.querySelectorAll('a[href]')).map(a => ({
                        Title: (a.innerText || a.getAttribute('title') || a.href || '').trim().slice(0, 300),
                        Link: a.href
                    }))"""
                )
                seen = set()
                out = []
                for item in raw or []:
                    link = (item.get("Link") or "").strip()
                    if not link or link in seen:
                        continue
                    seen.add(link)
                    out.append({"Title": item.get("Title") or link, "Link": link})
                return json.dumps(out, ensure_ascii=False).encode("utf-8"), "application/json; charset=utf-8"

            if want == "screenshot":
                full = True
                png = page.screenshot(full_page=full, type="png")
                return png, "image/png"

            raise RuntimeError("unknown render mode")
        finally:
            try:
                ctx.close()
            except Exception:  # noqa: BLE001
                pass


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _send(self, code, body, ctype="text/plain; charset=utf-8", extra=None):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        try:
            self.wfile.write(body)
        except Exception:  # noqa: BLE001
            pass

    def _auth_ok(self):
        if not USER:
            return True
        hdr = self.headers.get("Authorization", "")
        if not hdr.startswith("Basic "):
            return False
        try:
            raw = base64.b64decode(hdr[6:]).decode("utf-8", "replace")
            u, _, p = raw.partition(":")
            return u == USER and p == PASS
        except Exception:  # noqa: BLE001
            return False

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/") or "/"

        if path in ("/health", "/healthz"):
            return self._send(200, json.dumps({"status": "ok", "browser": bool(_browser)}), "application/json")

        if not self._auth_ok():
            return self._send(401, "unauthorized", extra={"WWW-Authenticate": 'Basic realm="scraper"'})

        mode = {
            "/markdown": "markdown",
            "/html": "html",
            "/links": "links",
            "/screenshot": "screenshot",
        }.get(path)

        if mode is None:
            return self._send(404, f"unknown endpoint {path}")

        qs = parse_qs(parsed.query)
        target = (qs.get("url") or [""])[0]
        if not target:
            return self._send(400, "missing url parameter")

        target = unquote(target)
        if not re.match(r"^https?://", target, re.I):
            return self._send(400, "url must be http(s)")

        try:
            body, ctype = render(target, mode)
        except Exception as exc:  # noqa: BLE001
            msg = str(exc)[:500]
            return self._send(502, f"scrape failed: {msg}")

        if len(body) > MAX_BYTES:
            body = body[:MAX_BYTES]
        return self._send(200, body, ctype)

    def do_HEAD(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()

    def log_message(self, fmt, *args):
        try:
            with open("/var/log/scraper-access.log", "a", encoding="utf-8") as fh:
                fh.write("%s %s\n" % (self.command, self.path[:200]))
        except Exception:  # noqa: BLE001
            pass


if __name__ == "__main__":
    print(f"starting scraper on 0.0.0.0:{PORT}", flush=True)
    start_browser()
    # 单线程服务：Playwright 的 sync API 绑定创建它的线程（greenlet），
    # 用 ThreadingHTTPServer 会触发 "Cannot switch to a different thread"。
    # PentAGI 的浏览器工具是顺序调用，串行处理足够。
    HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
