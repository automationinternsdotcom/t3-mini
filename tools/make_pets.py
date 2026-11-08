#!/usr/bin/env python3
"""Generate T3 Mini's built-in pets as sprite atlases.

Every pixel is drawn procedurally here, so the art is original to this repo.
Atlas layout read by T3 Mini (pet.json with spriteVersionNumber 2):
  1536x2288 PNG, 8 cols x 11 rows, 192x208 cells, transparent background.
  rows 0-8: idle, running-right, running-left, waving, jumping, failed,
            waiting, running, review
  rows 9-10: 16 clockwise look directions starting at 000 = up.

Usage: python3 tools/make_pets.py [out_dir]   (default: assets/pets)
"""
from __future__ import annotations

import json
import math
import sys
from dataclasses import dataclass, field
from pathlib import Path

from PIL import Image, ImageDraw

CELL_W, CELL_H = 192, 208
COLS, ROWS = 8, 11
SCALE = 4  # draw on a 48x52 pixel grid, upscale 4x with nearest-neighbour
GW, GH = CELL_W // SCALE, CELL_H // SCALE  # 48 x 52
BASE = 47  # ground line on the small grid

ROW_FRAMES = [6, 8, 8, 4, 5, 8, 6, 6, 6]


@dataclass
class Palette:
    body: tuple
    shade: tuple
    light: tuple
    outline: tuple
    accent: tuple
    eye: tuple = (24, 24, 36, 255)
    cheek: tuple = (255, 140, 160, 255)
    prop: tuple = (70, 80, 110, 255)
    glow: tuple = (120, 255, 210, 255)


@dataclass
class Pet:
    id: str
    name: str
    description: str
    pal: Palette
    kind: str  # "blob" | "bot" | "cat"


PETS = [
    Pet("tee", "Tee", "A cheerful teal blob who keeps an eye on your threads.",
        Palette(body=(64, 200, 190, 255), shade=(36, 150, 150, 255), light=(150, 240, 225, 255),
                outline=(18, 60, 70, 255), accent=(255, 214, 90, 255)), "blob"),
    Pet("bit", "Bit", "A tiny terminal bot that hums while your agents work.",
        Palette(body=(150, 160, 230, 255), shade=(105, 112, 190, 255), light=(205, 212, 255, 255),
                outline=(36, 36, 80, 255), accent=(255, 120, 120, 255),
                eye=(120, 255, 210, 255), glow=(120, 255, 210, 255)), "bot"),
    Pet("mochi", "Mochi", "A sleepy orange cat who perks up when you're needed.",
        Palette(body=(250, 170, 90, 255), shade=(214, 124, 60, 255), light=(255, 214, 160, 255),
                outline=(80, 40, 24, 255), accent=(255, 245, 230, 255)), "cat"),
]


@dataclass
class Pose:
    dx: float = 0  # whole-body horizontal offset
    dy: float = 0  # whole-body vertical offset (negative = up)
    squash: float = 1.0  # body height factor
    lean: float = 0  # top-of-body horizontal shift
    arm_l: float = 0  # arm raise angle degrees (0 = down at side, 180 = straight up)
    arm_r: float = 0
    feet: tuple = (0, 0)  # per-foot lift in px
    feet_dx: tuple = (0, 0)
    eyes: str = "open"  # open | closed | x | happy | wide | half
    look: tuple = (0.0, 0.0)  # pupil direction (-1..1)
    mouth: str = "smile"  # smile | o | flat | frown | grin
    props: list = field(default_factory=list)
    ground: bool = True  # feet on the ground
    flip: bool = False


def ellipse(d: ImageDraw.ImageDraw, cx, cy, rx, ry, fill):
    d.ellipse([round(cx - rx), round(cy - ry), round(cx + rx), round(cy + ry)], fill=fill)


def outline(img: Image.Image, color) -> Image.Image:
    """Add a 1px outline around opaque pixels (on the small grid)."""
    src = img.load()
    out = img.copy()
    o = out.load()
    w, h = img.size
    for y in range(h):
        for x in range(w):
            if src[x, y][3] != 0:
                continue
            for nx, ny in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
                if 0 <= nx < w and 0 <= ny < h and src[nx, ny][3] != 0 and src[nx, ny] != (0, 0, 0, 1):
                    o[x, y] = color
                    break
    return out


def draw_pet(pet: Pet, pose: Pose) -> Image.Image:
    p = pet.pal
    img = Image.new("RGBA", (GW, GH), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    cx = GW / 2 + pose.dx
    body_h = 13 * pose.squash
    body_w = 16 / max(0.8, pose.squash) ** 0.5
    feet_y = BASE + pose.dy
    body_bottom = feet_y - 3
    cy = body_bottom - body_h * 1.15
    top_cx = cx + pose.lean

    # --- feet
    for i, side in enumerate((-1, 1)):
        fx = cx + side * 6 + pose.feet_dx[i]
        fy = feet_y - 1 - pose.feet[i]
        ellipse(d, fx, fy, 3.2, 2.2, p.shade)

    # --- tail (cat) behind body
    if pet.kind == "cat":
        tx = cx + 13
        for k in range(6):
            ellipse(d, tx + math.sin(k / 2 + pose.dy) * 1.2, body_bottom - 3 - k * 2, 1.8, 1.8, p.shade)

    # --- body
    if pet.kind == "bot":
        # rounded monitor-ish body
        x0, x1 = cx - body_w - 1, cx + body_w + 1
        y0, y1 = cy - 3, body_bottom
        d.rounded_rectangle([round(x0 + pose.lean), round(y0), round(x1 + pose.lean), round(y1)], radius=6, fill=p.body)
        d.rounded_rectangle([round(x0 + pose.lean + 2), round(y1 - 4), round(x1 + pose.lean - 2), round(y1)], radius=2, fill=p.shade)
    else:
        # blob / cat: smooth parametric outline; lean bends the top
        pts = []
        cyc = body_bottom - body_h
        for k in range(64):
            th = k / 64 * math.tau
            yn = math.sin(th)  # -1 top .. 1 bottom
            ry = body_h if yn < 0 else body_h * 0.92
            x = cx + body_w * 1.08 * math.cos(th) * (1 - 0.08 * max(0, -yn)) + pose.lean * (1 - yn) / 2
            y = cyc + ry * yn
            pts.append((x, y))
        d.polygon(pts, fill=p.body)
        ellipse(d, cx + pose.lean * 0.15, body_bottom - 2.5, body_w * 0.8, 3, p.shade)

    face_cx = top_cx * 0.6 + cx * 0.4
    face_cy = cy + body_h * 0.55

    # --- head decorations
    if pet.kind == "cat":
        for side in (-1, 1):
            ex = top_cx + side * 8
            ey = cy - body_h * 0.55
            d.polygon([(ex - 4, ey + 5), (ex + side * 1.5, ey - 4), (ex + 4, ey + 5)], fill=p.body)
            d.polygon([(ex - 2, ey + 4), (ex + side * 1, ey - 1), (ex + 2, ey + 4)], fill=p.cheek)
        # belly
        ellipse(d, cx + pose.lean * 0.3, body_bottom - 6, 7, 4.5, p.accent)
    elif pet.kind == "bot":
        ax = top_cx + 0.0
        d.line([(round(ax), round(cy - 1)), (round(ax), round(cy - 6))], fill=p.outline)
        ellipse(d, ax, cy - 7, 1.6, 1.6, p.accent)
        # screen
        d.rounded_rectangle([round(face_cx - 10), round(face_cy - 6), round(face_cx + 10), round(face_cy + 6)], radius=3,
                            fill=(28, 32, 58, 255))
    else:  # blob sprout
        sx = top_cx + 1
        sy = cy - body_h * 0.55
        d.line([(round(sx), round(sy + 3)), (round(sx), round(sy - 2))], fill=(60, 140, 70, 255))
        ellipse(d, sx - 2.5, sy - 3, 2.5, 1.5, (110, 210, 100, 255))
        ellipse(d, sx + 2.5, sy - 4, 2.5, 1.5, (110, 210, 100, 255))

    # highlight
    if pet.kind != "bot":
        ellipse(d, top_cx - body_w * 0.45, cy - body_h * 0.15, 2.5, 2, p.light)

    # --- arms
    for side, ang in ((-1, pose.arm_l), (1, pose.arm_r)):
        rad = math.radians(ang)
        sx = cx + side * (body_w - 1) + pose.lean * 0.5
        sy = body_bottom - body_h * 0.75
        length = 6
        ex = sx + side * math.sin(rad) * length * 0.8 + side * 1
        ey = sy + math.cos(rad) * length
        d.line([(round(sx), round(sy)), (round(ex), round(ey))], fill=p.shade, width=3)
        ellipse(d, ex, ey, 1.8, 1.8, p.body)

    # --- face
    lx, ly = pose.look
    eye_dx = 5
    ecol = p.eye
    for side in (-1, 1):
        ex = face_cx + side * eye_dx
        ey = face_cy - 1
        if pose.eyes == "open" or pose.eyes == "wide":
            h = 3 if pose.eyes == "open" else 4
            if pet.kind == "bot":
                d.rectangle([round(ex - 1 + lx * 2), round(ey - 1 + ly * 2), round(ex + 1 + lx * 2), round(ey + h - 2 + ly * 2)], fill=ecol)
            else:
                d.rectangle([round(ex - 1 + lx * 1.5), round(ey - h // 2 + ly * 1.5),
                             round(ex + 1 + lx * 1.5), round(ey + h // 2 + ly * 1.5)], fill=ecol)
                d.point((round(ex + lx * 1.5), round(ey - h // 2 + ly * 1.5)), fill=(255, 255, 255, 255))
        elif pose.eyes == "half":
            d.rectangle([round(ex - 1 + lx), round(ey + ly), round(ex + 1 + lx), round(ey + 1 + ly)], fill=ecol)
        elif pose.eyes == "closed":
            d.line([(round(ex - 2), round(ey + 1)), (round(ex + 2), round(ey + 1))], fill=ecol)
        elif pose.eyes == "happy":
            d.line([(round(ex - 2), round(ey + 1)), (round(ex), round(ey - 1)), (round(ex + 2), round(ey + 1))], fill=ecol)
        elif pose.eyes == "x":
            d.line([(round(ex - 1.5), round(ey - 1.5)), (round(ex + 1.5), round(ey + 1.5))], fill=ecol)
            d.line([(round(ex - 1.5), round(ey + 1.5)), (round(ex + 1.5), round(ey - 1.5))], fill=ecol)
    if pet.kind != "bot":
        for side in (-1, 1):
            ellipse(d, face_cx + side * 8, face_cy + 2, 1.5, 0.8, p.cheek)
    mx, my = face_cx + lx, face_cy + 3 + ly
    mcol = p.eye if pet.kind == "bot" else p.outline
    if pose.mouth == "smile":
        d.line([(round(mx - 2), round(my)), (round(mx), round(my + 1)), (round(mx + 2), round(my))], fill=mcol)
    elif pose.mouth == "grin":
        d.rectangle([round(mx - 2), round(my), round(mx + 2), round(my + 1)], fill=mcol)
    elif pose.mouth == "o":
        ellipse(d, mx, my + 0.5, 1, 1, mcol)
    elif pose.mouth == "flat":
        d.line([(round(mx - 1.5), round(my + 0.5)), (round(mx + 1.5), round(my + 0.5))], fill=mcol)
    elif pose.mouth == "frown":
        d.line([(round(mx - 2), round(my + 1)), (round(mx), round(my)), (round(mx + 2), round(my + 1))], fill=mcol)

    # --- props drawn before outline so they get outlined too
    for prop in pose.props:
        kind = prop[0]
        if kind == "laptop":
            off = prop[1]
            lx0 = cx - 8
            ly0 = body_bottom - 4
            d.polygon([(lx0, ly0), (lx0 + 16, ly0), (lx0 + 18, ly0 + 3), (lx0 - 2, ly0 + 3)], fill=p.prop)
            d.rectangle([round(lx0 + 1), round(ly0 - 7), round(lx0 + 15), round(ly0 - 1)], fill=p.prop)
            for k in range(3):
                w = 3 + ((off + k * 2) % 7)
                d.line([(round(lx0 + 3), round(ly0 - 6 + k * 2)), (round(lx0 + 3 + w), round(ly0 - 6 + k * 2))], fill=p.glow)
        elif kind == "lens":
            gx, gy = cx + 10 + prop[1], body_bottom - 12 + prop[2]
            ellipse(d, gx, gy, 4, 4, p.prop)
            ellipse(d, gx, gy, 2.5, 2.5, (200, 235, 255, 255))
            d.line([(round(gx + 3), round(gy + 3)), (round(gx + 6), round(gy + 6))], fill=p.prop, width=2)
        elif kind == "sparkle":
            sx, sy, r = prop[1], prop[2], prop[3]
            col = p.accent if pet.kind != "cat" else (255, 220, 80, 255)
            d.line([(round(sx - r), round(sy)), (round(sx + r), round(sy))], fill=col)
            d.line([(round(sx), round(sy - r)), (round(sx), round(sy + r))], fill=col)
        elif kind == "drop":
            sx, sy = prop[1], prop[2]
            d.polygon([(sx, sy - 2), (sx - 1.5, sy + 1), (sx + 1.5, sy + 1)], fill=(120, 190, 255, 255))
            ellipse(d, sx, sy + 1, 1.5, 1.2, (120, 190, 255, 255))
        elif kind == "cloud":
            sx, sy = prop[1], prop[2]
            for ox, oy, rr in ((0, 0, 2.5), (3, -1, 3), (6, 0, 2.5)):
                ellipse(d, sx + ox, sy + oy, rr, 2, (150, 150, 165, 255))
        elif kind == "bubble":  # little attention dot cluster, not text
            sx, sy, n = prop[1], prop[2], prop[3]
            for k in range(n):
                ellipse(d, sx + k * 3, sy, 1, 1, p.accent)

    img = outline(img, p.outline)
    if pose.flip:
        img = img.transpose(Image.FLIP_LEFT_RIGHT)
    return img


def frames_for(row: int, pet: Pet) -> list[Pose]:
    n = ROW_FRAMES[row] if row < 9 else 8
    out: list[Pose] = []
    if row == 0:  # idle: breathe + blink
        seq = [(0, 1.0, "open"), (0, 0.97, "open"), (0.5, 0.95, "half"), (0.5, 0.95, "closed"), (0, 0.97, "open"), (0, 1.0, "open")]
        for dy, sq, eyes in seq:
            out.append(Pose(dy=dy, squash=sq, eyes=eyes, arm_l=10, arm_r=10))
    elif row in (1, 2):  # locomotion right (left = mirrored)
        for i in range(8):
            ph = i / 8 * math.tau
            out.append(Pose(dy=-abs(math.sin(ph)) * 2, lean=2, squash=1 - 0.04 * math.cos(2 * ph),
                            feet=(max(0, math.sin(ph)) * 3, max(0, -math.sin(ph)) * 3),
                            feet_dx=(math.cos(ph) * 2, -math.cos(ph) * 2), arm_l=30 + 25 * math.sin(ph),
                            arm_r=30 - 25 * math.sin(ph), look=(1, 0), mouth="grin", flip=(row == 2)))
    elif row == 3:  # waving
        for ang, eyes in ((60, "open"), (150, "happy"), (120, "happy"), (160, "happy")):
            out.append(Pose(arm_r=ang, arm_l=10, eyes=eyes, mouth="grin", lean=-1))
    elif row == 4:  # jumping: anticipation, lift, peak, descent, settle
        for dy, sq, f in ((0, 0.82, 0), (-6, 1.12, 2), (-11, 1.05, 3), (-5, 1.08, 2), (0, 0.9, 0)):
            out.append(Pose(dy=dy, squash=sq, feet=(f, f), arm_l=140 if dy < 0 else 40, arm_r=140 if dy < 0 else 40,
                            eyes="happy" if dy < -4 else "open", mouth="o" if dy < -4 else "smile"))
    elif row == 5:  # failed: deflate, x eyes, little gray cloud
        for i in range(8):
            t = min(1.0, i / 4)
            shake = (1 if i % 2 else -1) * (1 if i in (1, 2, 3) else 0)
            props = [("cloud", GW / 2 - 4, 6 + (i % 2))] if i >= 2 else []
            if i >= 4:
                props.append(("drop", GW / 2 + 12, 22 + (i - 4)))
            out.append(Pose(dx=shake, squash=1 - 0.12 * t, dy=0, eyes="x" if i >= 2 else "wide", mouth="frown",
                            arm_l=5, arm_r=5, look=(0, 0.6 * t), props=props))
    elif row == 6:  # waiting: hand raised, looking up, dots
        for i in range(6):
            bob = [0, -0.5, -1, -1, -0.5, 0][i]
            out.append(Pose(dy=bob, arm_r=150 + (10 if i % 2 else 0), arm_l=15, look=(0.3, -1), eyes="wide",
                            mouth="o", props=[("bubble", GW / 2 + 9, 8, 1 + i % 3)]))
    elif row == 7:  # running = working: typing on a laptop
        for i in range(6):
            out.append(Pose(dy=0.5 if i % 2 else 0, squash=0.98 if i % 2 else 1.0, arm_l=70 + (15 if i % 2 else 0),
                            arm_r=70 + (0 if i % 2 else 15), look=(0, 1), eyes="open", mouth="flat",
                            props=[("laptop", i)]))
    elif row == 8:  # review: inspect with lens, sparkles
        for i in range(6):
            ox = [0, 1, 2, 2, 1, 0][i]
            out.append(Pose(arm_r=95, arm_l=15, look=(1, 0.2), eyes="open", mouth="smile" if i < 4 else "grin",
                            props=[("lens", ox, -1 if i % 2 else 0), ("sparkle", 8 + (i % 3) * 3, 10 + (i % 2) * 3, 1 + (i % 2))]))
    else:  # look directions: 16 clockwise, 000 = up
        base = 0 if row == 9 else 8
        for i in range(8):
            deg = (base + i) * 22.5
            rad = math.radians(deg)
            lx, ly = math.sin(rad), -math.cos(rad)
            out.append(Pose(look=(lx, ly), lean=lx * 1.5, dy=-0.5 if ly < 0 else 0, arm_l=10, arm_r=10,
                            mouth="smile"))
    return out[:n]


def build(pet: Pet, out_dir: Path) -> Path:
    atlas = Image.new("RGBA", (CELL_W * COLS, CELL_H * ROWS), (0, 0, 0, 0))
    for row in range(ROWS):
        for col, pose in enumerate(frames_for(row, pet)):
            cell = draw_pet(pet, pose).resize((CELL_W, CELL_H), Image.NEAREST)
            atlas.alpha_composite(cell, (col * CELL_W, row * CELL_H))
    dest = out_dir / pet.id
    dest.mkdir(parents=True, exist_ok=True)
    atlas.save(dest / "spritesheet.png", optimize=True)
    manifest = {
        "id": pet.id,
        "displayName": pet.name,
        "description": pet.description,
        "spriteVersionNumber": 2,
        "spritesheetPath": "spritesheet.png",
    }
    (dest / "pet.json").write_text(json.dumps(manifest, indent=2) + "\n")
    return dest


def contact_sheet(out_dir: Path) -> Path:
    sheets = [Image.open(out_dir / p.id / "spritesheet.png") for p in PETS]
    w = sheets[0].width // 2
    h = sheets[0].height // 2
    sheet = Image.new("RGBA", (w * len(sheets), h), (245, 245, 250, 255))
    for i, s in enumerate(sheets):
        sheet.alpha_composite(s.resize((w, h), Image.NEAREST), (i * w, 0))
    path = out_dir / "contact-sheet.png"
    sheet.save(path)
    return path


if __name__ == "__main__":
    out = Path(sys.argv[1] if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent / "assets" / "pets")
    for pet in PETS:
        print("built", build(pet, out))
    print("contact sheet", contact_sheet(out))
