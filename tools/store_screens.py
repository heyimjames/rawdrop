#!/usr/bin/env python3
"""Compose App Store screenshots (6.9", 1320x2868) from raw iPhone captures.

Usage: store_screens.py <input dir with 01.png .. 0N.png> <output dir>
Captions live in CAPTIONS below, keyed by filename stem.
"""
import sys, os, glob
from PIL import Image, ImageDraw, ImageFont, ImageFilter

W, H = 1320, 2868
AMBER = (255, 199, 46)
CAPTIONS = {
    "01": ("The RAW, not the JPEG.", "Straight to Lightroom."),
    "02": ("Pick a shoot.", "Send fifty at a time."),
    "03": ("Every frame, with", "what the camera saw."),
    "04": ("Know what's waiting,", "from the Home Screen."),
    "05": ("Nothing leaves", "your phone."),
}

def font(size, rounded=True):
    candidates = [
        "/Library/Fonts/SF-Pro-Rounded-Bold.otf",
        os.path.expanduser("~/Library/Fonts/SF-Pro-Rounded-Bold.otf"),
        "/System/Library/Fonts/SFCompactRounded.ttf",
        "/System/Library/Fonts/SFCompact.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
    ]
    for c in candidates:
        if os.path.exists(c):
            try:
                return ImageFont.truetype(c, size)
            except Exception:
                pass
    return ImageFont.load_default()

def fitted_font(lines, max_width, start=112, floor=72):
    size = start
    while size > floor:
        f = font(size)
        if all(f.getlength(l) <= max_width for l in lines):
            return f, size
        size -= 4
    return font(floor), floor

def dark_boxes(img, region, thresh=40, min_area=20000):
    """Bounding boxes of dark connected regions inside `region` (x0,y0,x1,y1)."""
    x0, y0, x1, y1 = region
    g = img.convert("L").crop(region)
    w, h = g.size
    px = g.load()
    seen = bytearray(w * h)
    boxes = []
    for yy in range(0, h, 2):
        for xx in range(0, w, 2):
            if px[xx, yy] < thresh and not seen[yy * w + xx]:
                stack = [(xx, yy)]; seen[yy * w + xx] = 1
                minx = maxx = xx; miny = maxy = yy; n = 0
                while stack:
                    cx, cy = stack.pop(); n += 1
                    minx = min(minx, cx); maxx = max(maxx, cx); miny = min(miny, cy); maxy = max(maxy, cy)
                    for nx, ny in ((cx+2, cy), (cx-2, cy), (cx, cy+2), (cx, cy-2)):
                        if 0 <= nx < w and 0 <= ny < h and not seen[ny * w + nx] and px[nx, ny] < thresh:
                            seen[ny * w + nx] = 1; stack.append((nx, ny))
                if (maxx - minx) * (maxy - miny) >= min_area:
                    boxes.append((x0 + minx, y0 + miny, x0 + maxx + 2, y0 + maxy + 2))
    return sorted(boxes)

def rounded_mask(size, radius):
    m = Image.new("L", size, 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, size[0]-1, size[1]-1], radius=radius, fill=255)
    return m

def compose_widgets(src_path, out_path, lines):
    """Slide 4: the two Home Screen widgets, lifted off the preview screen."""
    canvas = Image.new("RGB", (W, H), (0, 0, 0))
    draw = ImageDraw.Draw(canvas)
    pad = 96
    y = 200
    draw.text((pad, y), "RAW", font=font(40), fill=AMBER)
    y += 88
    head, size = fitted_font(lines, W - pad * 2)
    for line in lines:
        draw.text((pad, y), line, font=head, fill=(255, 255, 255))
        y += int(size * 1.15)

    shot = Image.open(src_path).convert("RGB")
    # Find the two black widget cards in the first row of the preview screen.
    boxes = [b for b in dark_boxes(shot, (0, 150, W, 800)) if (b[3]-b[1]) > 200]
    boxes = sorted(boxes, key=lambda b: b[0])[:2]
    small = shot.crop(boxes[0])
    medium = shot.crop(boxes[1])
    # Medium spans the width; small sits beneath, centred, at true proportion.
    ms = (W - pad * 2) / medium.width
    medium = medium.resize((W - pad * 2, int(medium.height * ms)), Image.LANCZOS)
    small = small.resize((int(small.width * ms), int(small.height * ms)), Image.LANCZOS)
    gap = 56
    block_h = medium.height + gap + small.height
    top = y + 140 + max(0, (H - (y + 140) - block_h) // 2 - 180)
    r = int(24 * ms * 1.6)
    for img, x, ty in ((medium, pad, top), (small, (W - small.width) // 2, top + medium.height + gap)):
        glow = Image.new("RGB", (W, H), (0, 0, 0))
        ImageDraw.Draw(glow).rounded_rectangle([x-40, ty-40, x+img.width+40, ty+img.height+40], radius=r+40, fill=(120, 90, 20))
        glow = glow.filter(ImageFilter.GaussianBlur(110))
        canvas = Image.blend(canvas, glow, 0.3)
        canvas.paste(img, (x, ty), rounded_mask(img.size, r))
    canvas.save(out_path, "PNG", optimize=True)

def compose(src_path, out_path, lines):
    canvas = Image.new("RGB", (W, H), (0, 0, 0))
    draw = ImageDraw.Draw(canvas)

    # Headline group, top: kicker + two lines on an 8px grid, 96px side padding.
    pad = 96
    y = 200
    kicker = font(40)
    draw.text((pad, y), "RAW", font=kicker, fill=AMBER)
    y += 88
    head, size = fitted_font(lines, W - pad * 2)
    for line in lines:
        draw.text((pad, y), line, font=head, fill=(255, 255, 255))
        y += int(size * 1.15)

    # Device capture, bottom, bleeding off the bottom edge.
    shot = Image.open(src_path).convert("RGB")
    target_w = W - pad * 2
    scale = target_w / shot.width
    shot = shot.resize((target_w, int(shot.height * scale)), Image.LANCZOS)
    top = y + 120
    visible_h = H - top
    shot = shot.crop((0, 0, shot.width, min(shot.height, visible_h + 200)))
    radius = int(120 * scale * 2.2)
    mask = rounded_mask(shot.size, radius)

    # Soft amber glow behind the device so it sits on the black rather than floating.
    glow = Image.new("RGB", (W, H), (0, 0, 0))
    g = ImageDraw.Draw(glow)
    g.rounded_rectangle([pad-40, top-40, pad+shot.width+40, top+shot.height+40], radius=radius+40, fill=(120, 90, 20))
    glow = glow.filter(ImageFilter.GaussianBlur(120))
    canvas = Image.blend(canvas, glow, 0.35)

    canvas.paste(shot, (pad, top), mask)
    # Hairline border
    ImageDraw.Draw(canvas).rounded_rectangle([pad, top, pad+shot.width-1, top+shot.height-1], radius=radius, outline=(255,255,255,40), width=2)
    canvas = canvas.crop((0, 0, W, H))
    canvas.save(out_path, "PNG", optimize=True)

def main():
    src, out = sys.argv[1], sys.argv[2]
    os.makedirs(out, exist_ok=True)
    for path in sorted(glob.glob(os.path.join(src, "*.png"))):
        stem = os.path.splitext(os.path.basename(path))[0][:2]
        lines = CAPTIONS.get(stem, ("RawDrop", ""))
        fn = compose_widgets if stem == "04" else compose
        fn(path, os.path.join(out, f"store-{stem}.png"), [l for l in lines if l])
        print("wrote", f"store-{stem}.png")

if __name__ == "__main__":
    main()
