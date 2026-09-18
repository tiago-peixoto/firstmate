#!/usr/bin/env python3
"""Render the live herdr ANSI captures and CLI transcripts into one HTML page."""
import html, re, sys, os
EV = os.path.dirname(os.path.abspath(__file__))
BASIC = ['#000000','#cd3131','#0dbc79','#e5e510','#2472c8','#bc3fbc','#11a8cd','#e5e5e5',
         '#666666','#f14c4c','#23d18b','#f5f543','#3b8eea','#d670d6','#29b8db','#ffffff']
def c256(n):
    if n < 16: return BASIC[n]
    if n < 232:
        n -= 16; r, g, b = n // 36, (n // 6) % 6, n % 6
        f = lambda v: 0 if v == 0 else 55 + v * 40
        return '#%02x%02x%02x' % (f(r), f(g), f(b))
    v = 8 + (n - 232) * 10; return '#%02x%02x%02x' % (v, v, v)
def ansi_to_html(text):
    out, st = [], {}
    def style():
        fg, bg = st.get('fg'), st.get('bg')
        if st.get('rev'): fg, bg = (bg or '#1e1e1e'), (fg or '#d4d4d4')
        s = []
        if fg: s.append('color:' + fg)
        if bg: s.append('background:' + bg)
        if st.get('bold'): s.append('font-weight:bold')
        if st.get('dim'): s.append('opacity:.6')
        if st.get('it'): s.append('font-style:italic')
        if st.get('ul'): s.append('text-decoration:underline')
        return ';'.join(s)
    pos = 0
    for m in re.finditer(r'\x1b\[([0-9;:]*)([A-Za-z])|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)', text):
        chunk = text[pos:m.start()]; pos = m.end()
        if chunk:
            s = style(); e = html.escape(chunk)
            out.append('<span style="%s">%s</span>' % (s, e) if s else e)
        if m.group(2) != 'm': continue
        ps = [int(p) if p.isdigit() else 0 for p in re.split('[;:]', m.group(1) or '0')]
        i = 0
        while i < len(ps):
            p = ps[i]
            if p == 0: st = {}
            elif p == 1: st['bold'] = 1
            elif p == 2: st['dim'] = 1
            elif p == 3: st['it'] = 1
            elif p == 4: st['ul'] = 1
            elif p == 7: st['rev'] = 1
            elif p == 22: st.pop('bold', None); st.pop('dim', None)
            elif p == 23: st.pop('it', None)
            elif p == 24: st.pop('ul', None)
            elif p == 27: st.pop('rev', None)
            elif 30 <= p <= 37: st['fg'] = BASIC[p - 30]
            elif 90 <= p <= 97: st['fg'] = BASIC[p - 82]
            elif 40 <= p <= 47: st['bg'] = BASIC[p - 40]
            elif 100 <= p <= 107: st['bg'] = BASIC[p - 92]
            elif p == 39: st.pop('fg', None)
            elif p == 49: st.pop('bg', None)
            elif p in (38, 48) and i + 1 < len(ps):
                key = 'fg' if p == 38 else 'bg'
                if ps[i + 1] == 5 and i + 2 < len(ps): st[key] = c256(ps[i + 2]); i += 2
                elif ps[i + 1] == 2 and i + 4 < len(ps): st[key] = '#%02x%02x%02x' % tuple(ps[i + 2:i + 5]); i += 4
            i += 1
    tail = text[pos:]
    if tail: out.append(html.escape(tail))
    return ''.join(out)
def tail_lines(path, n):
    return '\n'.join(open(path, encoding='utf-8', errors='replace').read().rstrip('\n').split('\n')[-n:])
def term(title, path, n):
    return '<h3>%s</h3><pre class="term">%s</pre>' % (html.escape(title), ansi_to_html(tail_lines(path, n)))
def transcript(title, path):
    return '<h3>%s</h3><pre class="cli">%s</pre>' % (html.escape(title), html.escape(open(path).read().rstrip()))
p = lambda f: os.path.join(EV, f)
body = [
 '<h1>Pi dollar-first status row: live herdr lab run</h1>',
 '<p>Real pi 0.85.1 in an isolated herdr 0.9.0 lab session (<code>fm-lab-pidollar-*</code>). '
 'Base = 07dab42d, target = 5f987b66. The same pane is classified by both code roots.</p>',
 term('1. Real idle pi screen: status row opens with $0.000 (sub) at column 0', p('01-live-idle-pi-screen.ansi'), 9),
 transcript('2. Composer verdict on that pane: base vs target', p('02-live-idle-pi-verdicts.txt')),
 transcript('3. Base fm-control exit refuses; a typed draft still blocks target exit', p('03-live-base-exit-and-draft-guard.txt')),
 term('3b. Pane while the draft is typed (draft kept after the refused exit)', p('03-live-draft-screen.ansi'), 7),
 transcript('4. Target fm-control exit stops pi; re-exit is idempotent; the dead shell reads unknown', p('04-live-target-exit.txt')),
 transcript('5. Relaunch: base refuses at the exit step, target relaunches in the same endpoint', p('05-live-relaunch.txt')),
 transcript('6. The relaunched pi (footer still dollar-first) exits through the target control plane', p('06-live-relaunched-exit.txt')),
 term('6b. Relaunched pi screen before that exit', p('06-live-relaunched-idle-screen.ansi'), 8),
 transcript('7. Read-only probe of the three live local pi mates (reproduction 2)', p('07-live-mates-readonly.txt')),
 transcript('8. Adversarial: real dead shells and a bare-glyph pane never read empty', p('08-live-adversarial.txt') ),
 transcript('8c. Pi-shaped frame directly above a real bash "$ " prompt', p('08c-live-adversarial.txt')),
]
css = ('body{background:#f6f6f4;color:#222;font:14px/1.45 -apple-system,Helvetica,sans-serif;margin:24px;max-width:1280px}'
       'pre{white-space:pre;overflow-x:auto;padding:10px 12px;border-radius:6px;font:12.5px/1.35 Menlo,monospace}'
       '.term{background:#1e1e1e;color:#d4d4d4}.cli{background:#fff;border:1px solid #ddd;white-space:pre-wrap;overflow-wrap:anywhere}h3{margin:22px 0 6px}')
open(p('live-evidence.html'), 'w').write('<!doctype html><meta charset="utf-8"><title>pi dollar status live evidence</title><style>%s</style>%s' % (css, '\n'.join(body)))
print(p('live-evidence.html'))
