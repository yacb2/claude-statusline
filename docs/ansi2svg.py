import re, sys, html
FG = {31:'#f38ba8',32:'#a6e3a1',33:'#f9e2af',34:'#89b4fa',35:'#cba6f7',36:'#94e2d5',90:'#7f849c'}
BASE='#cdd6f4'; DIMC='#6c7086'; BG='#1e1e2e'
CW, LH, PAD, FS = 8.4, 22, 24, 14
lines = sys.stdin.read().split('\n')
out=[]; y=PAD+16; maxcols=0
def esc(t): return html.escape(t).replace(' ', ' ')
for line in lines:
    if line.startswith('# '):
        out.append(f'<text x="{PAD}" y="{y}" fill="{DIMC}" font-style="italic">{esc("— "+line[2:])}</text>'); y+=LH; continue
    if not line: y+=LH*0.6; continue
    fg=BASE; bold=False; dim=False; spans=[]; col=0
    for tok in re.split(r'(\x1b\[[0-9;]*m)', line):
        if tok.startswith('\x1b['):
            codes=[int(c) for c in tok[2:-1].split(';') if c]
            i=0
            while i<len(codes):
                c=codes[i]
                if c==0: fg=BASE; bold=dim=False
                elif c==1: bold=True
                elif c==2: dim=True
                elif c==38 and codes[i+1:i+3]==[5,208]: fg='#fab387'; i+=2
                elif c in FG: fg=FG[c]
                i+=1
        elif tok:
            style=f'fill="{DIMC if dim and fg==BASE else fg}"'+(' font-weight="bold"' if bold else '')+(' opacity="0.7"' if dim and fg!=BASE else '')
            spans.append(f'<tspan {style}>{esc(tok)}</tspan>'); col+=len(tok)
    maxcols=max(maxcols,col)
    out.append(f'<text x="{PAD}" y="{y}">{"".join(spans)}</text>'); y+=LH
W=int(PAD*2+maxcols*CW); H=int(y)
print(f'''<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" font-family="'JetBrains Mono','SF Mono',Menlo,Consolas,'DejaVu Sans Mono',monospace" font-size="{FS}">
<rect width="{W}" height="{H}" rx="10" fill="{BG}"/>
<circle cx="20" cy="18" r="6" fill="#f38ba8"/><circle cx="40" cy="18" r="6" fill="#f9e2af"/><circle cx="60" cy="18" r="6" fill="#a6e3a1"/>
<g transform="translate(0,20)">{"".join(out)}</g>
</svg>''')
