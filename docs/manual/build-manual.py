#!/usr/bin/env python3
"""
build-manual.py - assembles the EgOS instruction manual as a booklet.

Sources:
    manual.md           Part I (user guide) and Part II (administration)
    ../scripts/*.md     Part III (script and function reference), in SCRIPT_ORDER order

Outputs (in this folder):
    EgOS-manual.html              A5 booklet, opens in the browser
    EgOS-manual.pdf               A5 booklet, one page per sheet
    EgOS-manual-booklet.pdf       booklet printing: A4 landscape, 2 pages per side in folding order
                                  (duplex, short edge; fold and staple in the middle)

Requirements: python3 with the modules `markdown`, `weasyprint`, `pypdf`
    python3 -m venv venv && venv/bin/pip install markdown weasyprint pypdf
    venv/bin/python build-manual.py
"""
import datetime
import html
import os
import re
import sys

import markdown

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.join(HERE, "..", "scripts")
VERSION = "4.3.0"

# Part III order: (file, group)
SCRIPT_ORDER = [
    ("EgOS4-arm64.md", "Build scripts"),
    ("EgOS4-amd64.md", "Build scripts"),
    ("builder.md", "Build scripts"),
    ("hook-live-build.md", "Build scripts"),
    ("setup-webapp.md", "First and second boot"),
    ("webapp-py.md", "First and second boot"),
    ("egos-growroot.md", "First and second boot"),
    ("deploy-compose.md", "First and second boot"),
    ("dirtree.md", "First and second boot"),
    ("wizardall2.md", "First and second boot"),
    ("stack-configuration.md", "First and second boot"),
    ("egos-home.md", "First and second boot"),
    ("egos-storage.md", "Storage"),
    ("cockpit-storage-pool.md", "Storage"),
    ("systemd-udev-units.md", "Storage"),
    ("egos-extras.md", "Optional services"),
    ("torrent_web.md", "Optional services"),
    ("qbt-sort.md", "Optional services"),
    ("audiotags.md", "Optional services"),
]

MD_EXT = ["tables", "fenced_code", "attr_list", "sane_lists"]


def slug(s):
    s = re.sub(r"<[^>]+>", "", s).lower()
    s = re.sub(r"[^a-z0-9àèéìòù]+", "-", s).strip("-")
    return s or "section"


def md_to_html(text):
    return markdown.markdown(text, extensions=MD_EXT, output_format="html5")


def callouts(h):
    """> **Warning** — ... -> coloured box."""
    # several callouts in a row: Markdown merges them into one blockquote, split them here
    def split(m):
        return re.sub(r"</p>\s*<p><strong>(Warning|Note|Tip)</strong>",
                      r"</p>\n</blockquote>\n<blockquote>\n<p><strong>\1</strong>", m.group(0))
    h = re.sub(r"<blockquote>.*?</blockquote>", split, h, flags=re.S)
    kinds = {"Warning": "warning", "Note": "note", "Tip": "tip"}

    def rep(m):
        k = m.group(1)
        return '<blockquote class="box %s">\n<p><strong class="box-title">%s</strong>' % (kinds[k], k)
    return re.sub(r"<blockquote>\s*<p><strong>(Warning|Note|Tip)</strong>", rep, h)


def script_html(fname):
    """A ../scripts document as a Part III section (headings moved down one level)."""
    with open(os.path.join(SCRIPTS, fname), encoding="utf-8") as f:
        text = f.read()
    h = md_to_html(text)
    for n in (5, 4, 3, 2, 1):
        h = re.sub(r"<(/?)h%d([ >])" % n, r"<\1h%d\2" % (n + 1), h)
    sid = "script-" + slug(fname[:-3])
    h = h.replace("<h2>", '<h2 class="script-title" id="%s">' % sid, 1)
    return sid, h


def fix_links(h, ids):
    """[egos-storage.md](egos-storage.md) -> internal link to the section."""
    def rep(m):
        target = os.path.basename(m.group(1))
        sid = ids.get(target)
        return 'href="#%s"' % sid if sid else 'href="%s"' % m.group(1)
    return re.sub(r'href="([^"#:]+\.md)"', rep, h)


def build_body():
    with open(os.path.join(HERE, "manual.md"), encoding="utf-8") as f:
        main = md_to_html(f.read())

    # Part III
    ids, parts, last_group = {}, [], None
    for fname, group in SCRIPT_ORDER:
        sid, h = script_html(fname)
        ids[fname] = sid
        if group != last_group:
            parts.append('<h2 class="group" id="%s">%s</h2>' % ("group-" + slug(group), html.escape(group)))
            last_group = group
        parts.append('<section class="script">%s</section>' % h)
    ref = ('<h1 class="part-start" data-part="Part III — Technical reference" id="reference">'
           'Scripts and functions</h1>\n'
           '<p class="lead">Every script of the project, with its functions. This is the collection of the documents '
           'in the <code>docs/scripts/</code> folder: the same material is there, one file per script.</p>\n'
           + "\n".join(parts))

    body = callouts(main + "\n" + ref)
    body = fix_links(body, ids)

    # ids for chapters without one
    def h1id(m):
        attrs, title = m.group(1), m.group(2)
        if "id=" not in attrs:
            attrs += ' id="ch-%s"' % slug(title)
        return "<h1%s>%s</h1>" % (attrs, title)
    body = re.sub(r"<h1([^>]*)>(.*?)</h1>", h1id, body)

    # divider page before each part
    def divider(m):
        tag = m.group(0)
        p = re.search(r'data-part="([^"]+)"', tag).group(1)
        num, _, name = p.partition(" — ")
        return ('<div class="part-page"><div class="part-num">%s</div>'
                '<div class="part-name">%s</div></div>\n%s' % (num, name, tag))
    body = re.sub(r'<h1[^>]*data-part="[^"]+"[^>]*>', divider, body)
    return body


def build_toc(body):
    items = []
    for m in re.finditer(r'<(h1|h2)([^>]*)id="([^"]+)"[^>]*>(.*?)</\1>', body):
        tag, attrs, hid, title = m.groups()
        title = re.sub(r"<[^>]+>", "", title)
        if tag == "h1":
            pm = re.search(r'data-part="([^"]+)"', m.group(0))
            if pm:
                items.append('<li class="toc-part">%s</li>' % html.escape(pm.group(1)))
            items.append('<li class="toc-cap"><a href="#%s">%s</a></li>' % (hid, title))
        elif 'class="group"' in m.group(0):
            items.append('<li class="toc-group"><a href="#%s">%s</a></li>' % (hid, title))
        elif "script-title" in m.group(0):
            items.append('<li class="toc-script"><a href="#%s">%s</a></li>' % (hid, title))
    return '<nav class="contents"><h1 class="no-run" id="contents">Contents</h1><ol>%s</ol></nav>' % "".join(items)


CSS = r"""
@page {
  size: A5;
  margin: 17mm 14mm 19mm 14mm;
  @bottom-center { content: counter(page); font: 8pt "Noto Sans", sans-serif; color: #6b6b6b; }
  @top-center { content: string(chapter); font: 7pt "Noto Sans", sans-serif; letter-spacing: .08em;
                text-transform: uppercase; color: #8a8a8a; }
}
@page :left  { margin-left: 13mm; margin-right: 16mm; }
@page :right { margin-left: 16mm; margin-right: 13mm; }
@page cover { margin: 0; @bottom-center { content: none; } @top-center { content: none; } }
@page blank { @bottom-center { content: none; } @top-center { content: none; } }
@page :blank { @bottom-center { content: none; } @top-center { content: none; } }

:root {
  --ink: #1d1d1b; --muted: #5f5f5a; --rule: #d9d6cf; --paper: #ffffff;
  --accent: #b5462a; --accent-soft: #f6e9e4; --note: #2f5d7c; --note-soft: #e7eff5;
  --tip: #3d6b3a; --tip-soft: #e9f1e6; --code-bg: #f4f2ee;
}
body { font: 9.4pt/1.45 "Noto Serif", "Liberation Serif", Georgia, serif; color: var(--ink); margin: 0;
       background: var(--paper); hyphens: auto; }
h1, h2, h3, h4, h5, .part-num, .part-name, th, .box-title, nav { font-family: "Noto Sans", "Liberation Sans", system-ui, sans-serif; }

/* --- cover --- */
.cover { page: cover; height: 210mm; width: 148mm; position: relative; background: #1f2a30; color: #f3efe7;
             break-after: page; overflow: hidden; }
.cover .band { position: absolute; left: 0; right: 0; top: 0; height: 9mm; background: var(--accent); }
.cover .brand { position: absolute; left: 16mm; top: 46mm; font: 700 44pt/1 "Noto Sans", sans-serif; letter-spacing: -.02em; }
.cover .brand span { color: var(--accent); }
.cover .title { position: absolute; left: 16mm; right: 16mm; top: 66mm; font: 400 15pt/1.3 "Noto Sans", sans-serif; }
.cover .subtitle { position: absolute; left: 16mm; right: 16mm; top: 84mm; font: 9pt/1.5 "Noto Serif", serif; color: #c9c3b6; }
.cover svg { position: absolute; left: 16mm; bottom: 34mm; width: 116mm; }
.cover .footer { position: absolute; left: 16mm; right: 16mm; bottom: 14mm; font: 8pt "Noto Sans", sans-serif;
                    color: #a9a397; display: flex; justify-content: space-between; }

.colophon { page: blank; break-after: page; padding-top: 120mm; font-size: 7.6pt; color: var(--muted); }
.colophon p { margin: .3em 0; }

/* --- parti --- */
.part-page { page: blank; break-before: right; break-after: page; padding-top: 70mm; }
.part-num { font-size: 9pt; letter-spacing: .2em; text-transform: uppercase; color: var(--accent); }
.part-name { font-size: 22pt; font-weight: 700; margin-top: 3mm; border-top: 1.2pt solid var(--ink); padding-top: 4mm; }

/* --- titoli --- */
h1 { string-set: chapter content(); break-before: page; font-size: 17pt; line-height: 1.15; margin: 0 0 6mm;
     padding-bottom: 2.5mm; border-bottom: .8pt solid var(--rule); }
.part-page + h1 { break-before: auto; }
h1.no-run { string-set: chapter ""; }
h2 { font-size: 11.5pt; margin: 6mm 0 2mm; color: var(--ink); break-after: avoid; }
h3 { font-size: 9.8pt; margin: 4.5mm 0 1.5mm; break-after: avoid; }
h4, h5 { font-size: 9pt; margin: 3.5mm 0 1mm; color: var(--muted); break-after: avoid; }
p { margin: 0 0 2.2mm; orphans: 2; widows: 2; }
.lead { font-size: 10pt; color: var(--muted); }
a { color: inherit; text-decoration: none; }
strong { font-weight: 700; }

/* --- liste numerate a "passi" --- */
ol { padding-left: 0; list-style: none; counter-reset: passo; margin: 0 0 3mm; }
ol > li { counter-increment: passo; position: relative; padding-left: 7.5mm; margin-bottom: 1.4mm; }
ol > li::before { content: counter(passo); position: absolute; left: 0; top: .05em; width: 4.6mm; height: 4.6mm;
                  border-radius: 50%; background: var(--ink); color: #fff; font: 700 6.8pt/4.6mm "Noto Sans", sans-serif;
                  text-align: center; }
ul { padding-left: 4.5mm; margin: 0 0 3mm; }
ul li { margin-bottom: .8mm; }
ul li::marker { color: var(--accent); }

/* --- tabelle --- */
table { width: 100%; border-collapse: collapse; margin: 1.5mm 0 4mm; font-size: 7.6pt; line-height: 1.35;
        break-inside: auto; }
thead { display: table-header-group; }
tr { break-inside: avoid; }
th { text-align: left; font-weight: 700; font-size: 7pt; text-transform: uppercase; letter-spacing: .04em;
     color: var(--muted); border-bottom: .9pt solid var(--ink); padding: 1.2mm 1.6mm 1mm 0; }
td { border-bottom: .4pt solid var(--rule); padding: 1.1mm 1.6mm 1.1mm 0; vertical-align: top; }
td:first-child { font-weight: 600; }
td code, th code { white-space: normal; word-break: break-word; }

/* --- codice --- */
code { font: .88em "Noto Sans Mono", "Liberation Mono", monospace; background: var(--code-bg); padding: 0 .25em;
       border-radius: 1.5pt; hyphens: none; overflow-wrap: anywhere; }
pre { background: var(--code-bg); border-left: 1.6pt solid var(--ink); padding: 2mm 2.6mm; margin: 1.5mm 0 3.5mm;
      white-space: pre-wrap; word-break: break-all; font-size: 7.2pt; line-height: 1.4; break-inside: avoid; }
pre code { background: none; padding: 0; font-size: 1em; }

/* --- riquadri --- */
.box { margin: 2mm 0 3.5mm; padding: 2.2mm 3mm; border-radius: 2pt; break-inside: avoid; border-left: 2.2pt solid; }
.box p:last-child { margin-bottom: 0; }
.box-title { display: inline; font-size: 7.4pt; text-transform: uppercase; letter-spacing: .08em; margin-right: .3em; }
.warning { background: var(--accent-soft); border-color: var(--accent); }
.warning .box-title { color: var(--accent); }
.note { background: var(--note-soft); border-color: var(--note); }
.note .box-title { color: var(--note); }
.tip { background: var(--tip-soft); border-color: var(--tip); }
.tip .box-title { color: var(--tip); }
blockquote { margin: 2mm 0 3mm; padding-left: 3mm; border-left: 1.4pt solid var(--rule); color: var(--muted); }

/* --- part III --- */
h2.group { break-before: page; font-size: 8pt; text-transform: uppercase; letter-spacing: .18em; color: var(--accent);
            margin: 0 0 1mm; }
h1#reference + p + h2.group { break-before: auto; }
section.script { margin-bottom: 6mm; }
h2.script-title { font-size: 13pt; margin-top: 2mm; padding-bottom: 1.5mm; border-bottom: .8pt solid var(--ink); }
section.script + h2.group { margin-top: 0; }
section.script > table:first-of-type td:first-child { width: 28%; }
hr { border: 0; border-top: .5pt dashed var(--rule); margin: 4mm 0; }

/* --- contents --- */
nav.contents { page: blank; break-after: page; }
nav.contents h1 { break-before: auto; }
nav.contents ol { counter-reset: none; }
nav.contents li { padding: 0; margin: 0; }
nav.contents li::before { content: none; }
nav.contents a::after { content: leader(".") " " target-counter(attr(href), page); color: var(--muted); }
.toc-part { font-size: 7pt; text-transform: uppercase; letter-spacing: .16em; color: var(--accent); margin-top: 3.5mm !important; }
.toc-cap { font-size: 9pt; font-weight: 600; margin: .9mm 0 !important; }
.toc-group { font-size: 7.4pt; font-weight: 600; margin: 1.6mm 0 .4mm 3mm !important; color: var(--muted); }
.toc-script { font-size: 7.6pt; margin-left: 6mm !important; }

/* --- schermo --- */
@media screen {
  html { background: #e9e6e0; }
  body { box-sizing: border-box; max-width: 148mm; margin: 10mm auto; padding: 0 14mm 10mm;
         box-shadow: 0 1px 12px rgba(0,0,0,.18); }
  .cover { width: auto; margin: 0 -14mm; }
  table { max-width: 100%; }
  th, td { overflow-wrap: break-word; }
  .part-page { padding-top: 30mm; padding-bottom: 20mm; }
  h1 { margin-top: 14mm; }
  .colophon { padding-top: 10mm; }
  nav.contents a::after { content: none; }
}
@media screen and (max-width: 160mm) {
  body { margin: 0; padding: 0 16px 16px; box-shadow: none; }
  .cover { margin: 0 -16px; }
  table { display: block; overflow-x: auto; }
}
"""

COVER_SVG = """<svg viewBox="0 0 116 40" xmlns="http://www.w3.org/2000/svg" aria-hidden="true">
<g fill="none" stroke="#f3efe7" stroke-width=".5">
<rect x="0.5" y="12" width="34" height="22" rx="2"/><circle cx="7" cy="23" r="1.6" fill="#b5462a" stroke="none"/>
<line x1="12" y1="20" x2="29" y2="20"/><line x1="12" y1="24" x2="25" y2="24"/><line x1="12" y1="28" x2="27" y2="28"/>
<path d="M35 23 H52"/><path d="M52 8 V38"/>
<rect x="56" y="2" width="24" height="12" rx="1.5"/><rect x="56" y="16" width="24" height="12" rx="1.5"/><rect x="56" y="30" width="24" height="9" rx="1.5" stroke-dasharray="1.4 1"/>
<path d="M52 8 H56 M52 22 H56 M52 34.5 H56"/>
<path d="M80 22 H92"/><circle cx="100" cy="22" r="8"/><path d="M97 18.5 L104 22 L97 25.5 Z" fill="#f3efe7" stroke="none"/>
</g></svg>"""


def page(body, toc):
    today = datetime.date.today().isoformat()
    cover = ('<section class="cover"><div class="band"></div>'
             '<div class="brand">Eg<span>OS</span></div>'
             '<div class="title">Instruction manual</div>'
             '<div class="subtitle">Home media centre: photos, films, music and series on Debian 13.<br>'
             'Raspberry Pi 5 &middot; PC x86-64</div>%s'
             '<div class="footer"><span>Version %s</span><span>%s</span></div></section>') % (COVER_SVG, VERSION, today)
    colophon = ('<section class="colophon"><p><strong>EgOS %s</strong> — Instruction manual</p>'
                '<p>Generated on %s from <code>docs/manual/manual.md</code> and <code>docs/scripts/*.md</code> '
                'with <code>build-manual.py</code>.</p>'
                '<p>Reference: scripts <code>EgOS4-arm64.sh</code> and <code>EgOS4-amd64.sh</code>.</p></section>') % (VERSION, today)
    return ('<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n'
            '<meta name="viewport" content="width=device-width, initial-scale=1">\n'
            '<title>EgOS manual</title>\n<style>%s</style>\n</head>\n<body>\n%s\n%s\n%s\n%s\n</body>\n</html>\n'
            % (CSS, cover, colophon, toc, body))


def impose(src, dst):
    """Booklet imposition: A4 landscape, two A5 pages per side, folding order."""
    from pypdf import PdfReader, PdfWriter, PageObject, Transformation
    r = PdfReader(src)
    pages = list(r.pages)
    w, h = float(pages[0].mediabox.width), float(pages[0].mediabox.height)
    while len(pages) % 4:
        pages.append(None)
    n = len(pages)
    out = PdfWriter()
    for i in range(n // 2):
        if i % 2 == 0:
            left, right = n - 1 - i, i
        else:
            left, right = i, n - 1 - i
        sheet = PageObject.create_blank_page(width=2 * w, height=h)
        for idx, dx in ((left, 0), (right, w)):
            p = pages[idx]
            if p is not None:
                sheet.merge_transformed_page(p, Transformation().translate(dx, 0))
        out.add_page(sheet)
    with open(dst, "wb") as f:
        out.write(f)


def main():
    body = build_body()
    toc = build_toc(body)
    doc = page(body, toc)
    out_html = os.path.join(HERE, "EgOS-manual.html")
    with open(out_html, "w", encoding="utf-8") as f:
        f.write(doc)
    print("HTML:", out_html)
    if "--no-pdf" in sys.argv:
        return
    import weasyprint
    out_pdf = os.path.join(HERE, "EgOS-manual.pdf")
    weasyprint.HTML(string=doc, base_url=HERE).write_pdf(out_pdf)
    print("PDF: ", out_pdf)
    out_book = os.path.join(HERE, "EgOS-manual-booklet.pdf")
    impose(out_pdf, out_book)
    print("PDF booklet:", out_book)


if __name__ == "__main__":
    main()
