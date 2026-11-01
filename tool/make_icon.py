"""Draws the ShareBro icon: two phones leaning in until their tops touch,
one coral and one ink, each showing a photo, with a little spark where they
meet. One geometry feeds every output:

  assets/icon/app_icon.svg                 the full 108-unit adaptive layer
  android/.../drawable/ic_launcher_*.xml   adaptive foreground, background, themed
  android/.../drawable/ic_notify.xml       the one-colour status-bar icon
  android/.../mipmap-*/ic_launcher.png     legacy launcher icons
  assets/icon/app_icon_1024.png            in-app copy, app_icon_store_512.png
  windows/runner/resources/app_icon.ico

Needs Python 3 and Google Chrome (headless, to turn the SVG into PNGs).

  python tool/make_icon.py
"""
import math
import os
import pathlib
import struct
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
RES = ROOT / 'android/app/src/main/res'
CHROME = r'C:\Program Files\Google\Chrome\Application\chrome.exe'

CORAL, CORAL_L, INK, CREAM = '#E5533A', '#FF8A6B', '#141217', '#F6F3F1'

# Each phone: frame, screen, island, far hill, near hill, sun.
LEFT = (CORAL, '#FDE3DA', CORAL, '#FFC3B2', CORAL_L, CORAL_L)
RIGHT = (INK, '#3A353F', INK, '#5A5560', '#8A8590', CORAL_L)

# Drawn on a 1024 grid, then scaled into the 108-unit adaptive canvas so the
# whole mark sits inside the launcher's round safe zone.
TILT, W, H, R, CY = 22.5, 240, 428, 56, 585
FIT = 0.74 * 108 / 1024


def to_canvas(x, y):
    return (54 + (x - 512) * FIT, 54 + (y - 539) * FIT)


def placer(cx, cy, deg):
    """Maps a phone's own coordinates (centre at 0,0) onto the canvas."""
    a = math.radians(deg)
    c, s = math.cos(a), math.sin(a)
    return lambda x, y: to_canvas(cx + x * c - y * s, cy + x * s + y * c)


def f(v):
    return f'{v:.2f}'.rstrip('0').rstrip('.')


def rounded(place, x, y, w, h, r):
    k = r * FIT
    pts = [
        (x + r, y), (x + w - r, y), (x + w, y + r), (x + w, y + h - r),
        (x + w - r, y + h), (x + r, y + h), (x, y + h - r), (x, y + r),
    ]
    p = [place(*q) for q in pts]
    d = f'M{f(p[0][0])},{f(p[0][1])}'
    for i in range(1, 8):
        if i % 2:
            d += f' L{f(p[i][0])},{f(p[i][1])}'
        else:
            d += f' A{f(k)},{f(k)} 0 0 1 {f(p[i][0])},{f(p[i][1])}'
    return d + f' A{f(k)},{f(k)} 0 0 1 {f(p[0][0])},{f(p[0][1])} Z'


def polygon(place, pts):
    p = [place(*q) for q in pts]
    return 'M' + ' L'.join(f'{f(x)},{f(y)}' for x, y in p) + ' Z'


def circle(place, x, y, r):
    cx, cy = place(x, y)
    k = r * FIT
    return (f'M{f(cx - k)},{f(cy)} A{f(k)},{f(k)} 0 1 0 {f(cx + k)},{f(cy)} '
            f'A{f(k)},{f(k)} 0 1 0 {f(cx - k)},{f(cy)} Z')


def phone(cx, deg):
    """A phone's parts as (name, pathData); the photo parts sit inside the screen."""
    place = placer(cx, CY, deg)
    m = W * 0.07
    sw, sh = W - 2 * m, H - 2 * m
    x0, x1, y1 = -sw / 2, sw / 2, sh / 2
    return {
        'frame': rounded(place, -W / 2, -H / 2, W, H, R),
        'screen': rounded(place, -sw / 2, -sh / 2, sw, sh, R - m * 0.8),
        'sun': circle(place, sw * 0.2, -sh * 0.2, sw * 0.13),
        'far': polygon(place, [(x0, sh * .12), (-sw * .12, -sh * .06), (sw * .18, sh * .16), (x1, sh * .02), (x1, y1), (x0, y1)]),
        'near': polygon(place, [(x0, sh * .3), (-sw * .08, sh * .12), (sw * .2, sh * .3), (sw * .36, sh * .2), (x1, sh * .28), (x1, y1), (x0, y1)]),
        'island': rounded(place, -W * 0.13, -H / 2 + m * 1.7, W * 0.26, m * 0.95, m * 0.475),
    }


def phones():
    t = math.radians(TILT)
    corner = R * (math.cos(t) + math.sin(t) - 1)
    dx = W / 2 * math.cos(t) + H / 2 * math.sin(t) - corner
    top = H / 2 * math.cos(t) + W / 2 * math.sin(t) - corner
    return phone(512 - dx, TILT), phone(512 + dx, -TILT), CY - top - 14


def spark(y):
    """Three short rays above the point where the phones touch."""
    out = []
    for deg in (-90, -40, -140):
        a = math.radians(deg)
        p, q = (to_canvas(512 + 32 * math.cos(a), y + 32 * math.sin(a)),
                to_canvas(512 + 77 * math.cos(a), y + 77 * math.sin(a)))
        out.append(f'M{f(p[0])},{f(p[1])} L{f(q[0])},{f(q[1])}')
    return out, 16 * FIT


# ---- outputs ----

def svg():
    left, right, top = phones()
    rays, width = spark(top)
    body = f'<rect width="108" height="108" fill="{CREAM}"/>'
    for i, (ph, (frame, screen, island, far, near, sun)) in enumerate([(left, LEFT), (right, RIGHT)]):
        body += (f'<clipPath id="s{i}"><path d="{ph["screen"]}"/></clipPath>'
                 f'<path d="{ph["frame"]}" fill="{frame}"/>'
                 f'<g clip-path="url(#s{i})"><path d="{ph["screen"]}" fill="{screen}"/>'
                 f'<path d="{ph["sun"]}" fill="{sun}"/><path d="{ph["far"]}" fill="{far}"/>'
                 f'<path d="{ph["near"]}" fill="{near}"/></g>'
                 f'<path d="{ph["island"]}" fill="{island}"/>')
    for d in rays:
        body += f'<path d="{d}" stroke="{CORAL}" stroke-width="{f(width)}" stroke-linecap="round" fill="none"/>'
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 108 108">{body}</svg>\n'


def vector(comment, body, size=108, viewport=108, shift=0):
    group = f'    <group android:translateX="{f(-shift)}" android:translateY="{f(-shift)}">\n' if shift else ''
    end = '    </group>\n' if shift else ''
    return ('<?xml version="1.0" encoding="utf-8"?>\n'
            f'<!-- {comment}\n     Generated by tool/make_icon.py; edit that, not this. -->\n'
            '<vector xmlns:android="http://schemas.android.com/apk/res/android"\n'
            f'    android:width="{size}dp"\n    android:height="{size}dp"\n'
            f'    android:viewportWidth="{f(viewport)}"\n    android:viewportHeight="{f(viewport)}">\n'
            + group + body + end + '</vector>\n')


def vpath(d, fill=None, alpha=None, stroke=None, width=None, even_odd=False, indent='    '):
    a = [f'android:pathData="{d}"']
    if fill:
        a.insert(0, f'android:fillColor="{fill}"')
    if alpha is not None:
        a.insert(1, f'android:fillAlpha="{alpha}"')
    if even_odd:
        a.append('android:fillType="evenOdd"')
    if stroke:
        a += [f'android:strokeColor="{stroke}"', f'android:strokeWidth="{f(width)}"', 'android:strokeLineCap="round"']
    sep = '\n' + indent + '    '
    return f'{indent}<path{sep}' + sep.join(a) + ' />\n'


def foreground():
    left, right, top = phones()
    rays, width = spark(top)
    body = ''
    for ph, (frame, screen, island, far, near, sun) in [(left, LEFT), (right, RIGHT)]:
        body += vpath(ph['frame'], frame)
        body += '    <group>\n'
        body += f'        <clip-path android:pathData="{ph["screen"]}" />\n'
        for d, c in [(ph['screen'], screen), (ph['sun'], sun), (ph['far'], far), (ph['near'], near)]:
            body += vpath(d, c, indent='        ')
        body += '    </group>\n'
        body += vpath(ph['island'], island)
    for d in rays:
        body += vpath(d, stroke=CORAL, width=width)
    return vector('ShareBro icon: two phones leaning in until they touch, each showing a photo.', body)


def monochrome(comment, size=108, viewport=108, shift=0):
    """One colour for themed icons and the status bar: frames as outlines,
    the photos in fainter tints."""
    left, right, top = phones()
    rays, width = spark(top)
    body = ''
    for ph in (left, right):
        body += vpath(ph['frame'] + ' ' + ph['screen'], '#FFFFFFFF', even_odd=True)
        body += '    <group>\n'
        body += f'        <clip-path android:pathData="{ph["screen"]}" />\n'
        body += vpath(ph['sun'], '#FFFFFFFF', alpha='0.6', indent='        ')
        body += vpath(ph['far'], '#FFFFFFFF', alpha='0.3', indent='        ')
        body += vpath(ph['near'], '#FFFFFFFF', alpha='0.6', indent='        ')
        body += '    </group>\n'
        body += vpath(ph['island'], '#FFFFFFFF')
    for d in rays:
        body += vpath(d, stroke='#FFFFFFFF', width=width)
    return vector(comment, body, size, viewport, shift)


def background():
    return vector('App icon background: warm off-white.', vpath('M0,0h108v108h-108z', CREAM))


def render(svg_text, size, crop=(18, 72), radius=0.22):
    """PNG bytes of the icon: [crop] of the canvas, rounded by [radius]."""
    x, span = crop
    inner = svg_text.split('>', 1)[1].rsplit('</svg>', 1)[0]
    mask = (f'<clipPath id="m"><rect x="{x}" y="{x}" width="{span}" height="{span}" rx="{span * radius}"/></clipPath>'
            if radius else '')
    doc = (f'<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512" viewBox="{x} {x} {span} {span}">'
           + mask + (f'<g clip-path="url(#m)">{inner}</g>' if radius else inner) + '</svg>')
    with tempfile.TemporaryDirectory() as tmp:
        src, out = pathlib.Path(tmp, 'icon.svg'), pathlib.Path(tmp, 'icon.png')
        src.write_text(doc, encoding='utf8')
        subprocess.run([CHROME, '--headless=new', '--disable-gpu', '--hide-scrollbars',
                        '--default-background-color=00000000', '--window-size=512,512',
                        f'--force-device-scale-factor={size / 512}', f'--screenshot={out}', src.as_uri()],
                       check=True, capture_output=True)
        return out.read_bytes()


def ico(pngs):
    """A Windows .ico holding PNG images (Vista and later read these)."""
    head = struct.pack('<HHH', 0, 1, len(pngs))
    offset = 6 + 16 * len(pngs)
    entries, data = b'', b''
    for size, png in pngs:
        entries += struct.pack('<BBBBHHII', size % 256, size % 256, 0, 0, 1, 32, len(png), offset + len(data))
        data += png
    return head + entries + data


def main():
    art = svg()
    (ROOT / 'assets/icon/app_icon.svg').write_text(art, encoding='utf8', newline='\n')
    drawable = RES / 'drawable'
    for name, text in [
        ('ic_launcher_foreground.xml', foreground()),
        ('ic_launcher_background.xml', background()),
        ('ic_launcher_monochrome.xml', monochrome('Themed (one-colour) launcher icon.')),
        # The status bar wants 24dp: show just the mark.
        ('ic_notify.xml', monochrome('Status-bar icon: the ShareBro mark in one flat colour, as Android requires.',
                                     size=24, viewport=60, shift=24)),
    ]:
        (drawable / name).write_text(text, encoding='utf8', newline='\n')
    for density, size in {'mdpi': 48, 'hdpi': 72, 'xhdpi': 96, 'xxhdpi': 144, 'xxxhdpi': 192}.items():
        (RES / f'mipmap-{density}/ic_launcher.png').write_bytes(render(art, size))
    (ROOT / 'assets/icon/app_icon_1024.png').write_bytes(render(art, 1024))
    # Full-bleed square for app stores (they apply their own mask).
    (ROOT / 'assets/icon/app_icon_store_512.png').write_bytes(render(art, 512, crop=(14, 80), radius=0))
    (ROOT / 'windows/runner/resources/app_icon.ico').write_bytes(
        ico([(s, render(art, s)) for s in (16, 24, 32, 48, 64, 128, 256)]))
    print('icon written')


if __name__ == '__main__':
    os.chdir(ROOT)
    main()
