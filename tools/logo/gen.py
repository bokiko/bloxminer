import sys
from fontTools.ttLib import TTFont
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen

B = ["XXX.", "X..X", "XXA.", "X..X", "XXX."]          # 'B' as a 3x5 core grid, A = the hot core
CELL, GAP, R = 20, 3.5, 5
MARK_H = 5*CELL + 4*GAP                           # 106

def words(font_path, parts, x0, cap_h, baseline):
    f = TTFont(font_path); gs = f.getGlyphSet(); cmap = f.getBestCmap(); hm = f["hmtx"]
    upm = f["head"].unitsPerEm; capH = f["OS/2"].sCapHeight; s = cap_h / capH
    out, x = [], x0
    kern = -0.01 * upm
    for text, color in parts:
        d = []
        for ch in text:
            g = cmap[ord(ch)]; pen = SVGPathPen(gs)
            gs[g].draw(TransformPen(pen, (s, 0, 0, -s, x, baseline)))
            d.append(pen.getCommands()); x += (hm[g][0] + kern) * s
        out.append(f'<path fill="{color}" d="{" ".join(d)}"/>')
    return out, x

def svg(theme, variant):
    pal = {"dark":  dict(cell="#78716C", cell2="#78716C", hot="#F59E0B", w1="#E7E5E4", w2="#A8A29E"),
           "light": dict(cell="#A8A29E", cell2="#78716C", hot="#D97706", w1="#292524", w2="#78716C")}[theme]
    rects = []
    for r, row in enumerate(B):
        for c, ch in enumerate(row):
            if ch == ".": continue
            fill = pal["hot"] if ch == "A" else pal["cell"]
            rects.append(f'<rect x="{c*(CELL+GAP)}" y="{r*(CELL+GAP)}" width="{CELL}" height="{CELL}" rx="{R}" fill="{fill}"/>')
    mark_w = 4*CELL + 3*GAP
    if variant == "icon":
        pad = (MARK_H - mark_w) / 2 + 12
        return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="-{pad} -12 {MARK_H+24} {MARK_H+24}" width="128" height="128" role="img" aria-label="BloxMiner">'
                + "".join(rects) + "</svg>")
    cap = 64; base = MARK_H/2 + cap/2
    paths, end = words(sys.argv[1], [("Blox", pal["w1"]), ("Miner", pal["w2"])], mark_w + 30, cap, base)
    W = round(end + 4)
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {MARK_H}" width="{W*0.8:.0f}" height="{MARK_H*0.8:.0f}" role="img" aria-label="BloxMiner">'
            + "".join(rects) + "".join(paths) + "</svg>")

for theme in ("dark", "light"):
    open(f"logo-{theme}.svg", "w").write(svg(theme, "logo"))
    open(f"icon-{theme}.svg", "w").write(svg(theme, "icon"))
