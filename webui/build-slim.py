#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Build the web UI page for the router image from page.html and core.js.

  python3 build-slim.py             writes ../files-web/www-bench/index.html
  python3 build-slim.py --measure   prints the LZMA2 size of the page and what each optional cut would save
  python3 build-slim.py CUT ...     builds with those cuts (the default build has none)

CSS and JavaScript are minified with esbuild and the whitespace between tags is removed. Every control,
formatter, confirm and the reboot wait stay. esbuild is optional: set ESBUILD to its path if it is not on
PATH. Without it the page is written unminified, which costs about 500 bytes more in the squashfs.

Optional cuts, for measuring:
  svg      header router icon
  prof     Wi-Fi profile hints under the select
  log      log line colouring (benchweb, warn, err)
  tables   leases and clients as tables (plain text lines instead)
  back     waiting for the router after reboot, restore, flash or reset
  confirm  the extra confirms for port down and large netem without auto-clear
  raw      the per-card "raw" toggle (request, HTTP status and body)
"""
import json, lzma, os, re, shutil, subprocess, sys

D = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(D, '..', 'files-web', 'www-bench', 'index.html')
ESB = os.environ.get('ESBUILD') or shutil.which('esbuild')
SPDX = '<!-- SPDX-License-Identifier: MIT -->\n'


def rd(p):
    with open(os.path.join(D, p), encoding='utf-8') as f:
        return f.read()


def sub(s, a, b, n=1):
    """replace a by b exactly n times (regex), fail loudly if the source changed"""
    r, k = re.subn(a, lambda m: b, s, flags=re.S)
    assert k == n, (a, k)
    return r


def cut(name, h, js):
    if name == 'svg':
        h = sub(h, r'<svg .*?</svg>', '')
        h = sub(h, r'h1 svg\{[^}]*\}\n', '')
    elif name == 'prof':
        js = sub(js, r"const PROF=\{.*?\};\n", '')
        js = sub(js, r"if\(!wp\.dataset\.t&&PROF\[w\.profile\]\)\{wp\.value=w\.profile;hint\(\)\}\n", '')
        js = sub(js, r"const wp=\$\('wp'\),hint=.*?hint\(\);\n", '')
        h = sub(h, r'<p class="hint" id="wpd"></p>', '')
    elif name == 'log':
        js = sub(js, r"log:j=>`<pre class=\"log\">.*?</pre>`,", "log:j=>`<pre>${esc(j.join('\\n'))}</pre>`,")
        h = sub(h, r'\.bw\{color:var\(--acc\)\}', '')
    elif name == 'tables':
        js = sub(js, r"const tbl=.*?;\n", "const tbl=(hd,rs)=>`<pre>${esc(rs.map(r=>r.join('  ')).join('\\n'))}</pre>`;\n")
        h = sub(h, r'table\{[^\n]*\n', '')
    elif name == 'back':
        js = sub(js, r"// after reboot, flash.*?setTimeout\(tick,4e3\)\}\n", "")
        js = sub(js, r"flash:back,restore:back,reboot:back,reset:back", "")
    elif name == 'confirm':
        js = sub(js, r"if\(k=='port'.*?\n", '')
        js = sub(js, r"if\(k=='netem'.*?\n", '')
    elif name == 'raw':
        js = sub(js, r"\+\(raw\?`<details.*?:''\)", '')
    else:
        raise SystemExit('unknown cut ' + name)
    return h, js


def esbuild(src, loader, extra=()):
    return subprocess.run([ESB, '--minify', f'--loader={loader}', *extra], input=src.encode(),
                          capture_output=True, check=True).stdout.decode().strip()


def build(cuts=(), minify=True):
    h, js = rd('page.html'), rd('core.js')
    h = h[len(SPDX):] if h.startswith(SPDX) else h
    for c in cuts:
        h, js = cut(c, h, js)
    if minify:
        css = re.search(r'<style>\n(.*?)</style>', h, re.S).group(1)
        h = h.replace(css, esbuild(css, 'css'))
        # iife: lets esbuild rename the top-level names; the page has no inline handlers that need globals
        js = esbuild(js, 'js', ['--format=iife', '--target=chrome113,firefox112'])
        h = re.sub(r'>\s*\n\s*<', '><', h)
        h = re.sub(r'\n(?=<)', '', h)
    h = h.replace('/*CORE*/', js.rstrip('\n'))
    return re.sub(r'\n(?=</script>)', '', h) if minify else h


def lz(s):
    return len(lzma.compress(s.encode(), format=lzma.FORMAT_RAW,
                             filters=[{'id': lzma.FILTER_LZMA2, 'preset': 9 | lzma.PRESET_EXTREME}]))


def main():
    a = sys.argv[1:]
    mini = bool(ESB)
    if not mini:
        print('build-slim: esbuild not found (set ESBUILD), writing the page unminified', file=sys.stderr)
    if a[:1] == ['--measure']:
        full = build(minify=False)
        rows = [('unminified', len(full.encode()), lz(full), 0)]
        if mini:
            mn = build()
            base = lz(mn)
            rows.append(('minified (CSS, JS, whitespace)', len(mn.encode()), base, base - lz(full)))
            for c in ['svg', 'prof', 'log', 'tables', 'back', 'confirm', 'raw']:
                p = build([c])
                rows.append((f'minified, without {c}', len(p.encode()), lz(p), lz(p) - base))
        for r in rows:
            print('%-45s raw %6d  lzma2 %5d  delta %+d' % r)
        return
    page = build(a, minify=mini)
    with open(OUT, 'w', encoding='utf-8') as f:
        f.write(page)
    print(json.dumps({'out': os.path.relpath(OUT), 'cuts': a, 'minified': mini, 'raw': len(page.encode()), 'lzma2': lz(page)}))


main()
