#!/usr/bin/env python3
# Renders assets/demo.gif — a terminal walkthrough of cogwake's hold/release
# loop. No terminal recorder needed: draws styled frames with PIL, so it is
# deterministic and reproducible. Run: python3 assets/make_demo.py
import os
from PIL import Image, ImageDraw, ImageFont

FONT = "/System/Library/Fonts/SFNSMono.ttf"
BOLD = "/System/Library/Fonts/SFNSMono.ttf"
COLS, ROWS = 68, 17
FS = 26
PAD = 26
TITLE_H = 44

BG      = (13, 17, 23)      # github dark
BAR     = (22, 27, 34)
FG      = (201, 209, 217)
DIM     = (110, 118, 129)
GREEN   = (63, 185, 80)
YELLOW  = (210, 153, 34)
RED     = (248, 81, 73)
BLUE    = (88, 166, 255)
CYAN    = (57, 197, 207)
PROMPT  = (126, 231, 135)

font = ImageFont.truetype(FONT, FS)
tb = font.getbbox("M")
CW = font.getlength("M")
CH = int((tb[3] - tb[1]) * 1.9)
ASC = tb[1]
W = int(PAD * 2 + CW * COLS)
H = int(TITLE_H + PAD + CH * ROWS)

frames, durs = [], []

def blank():
    img = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([0, 0, W, TITLE_H], radius=0, fill=BAR)
    for i, c in enumerate([(255, 95, 86), (255, 189, 46), (39, 201, 63)]):
        d.ellipse([PAD + i * 26, 15, PAD + i * 26 + 14, 29], fill=c)
    d.text((W / 2, TITLE_H / 2), "cogwake", font=font, fill=DIM, anchor="mm")
    return img, d

def draw(lines, cursor=None):
    img, d = blank()
    y = TITLE_H + PAD
    for segs in lines:
        x = PAD
        for text, col in segs:
            d.text((x, y - ASC + 4), text, font=font, fill=col)
            x += CW * len(text)
        y += CH
    if cursor is not None:
        cx = PAD + CW * cursor[1]
        cy = TITLE_H + PAD + CH * cursor[0]
        d.rectangle([cx, cy + 2, cx + CW, cy + CH - 6], fill=FG)
    return img

def add(lines, hold=1, cursor=None):
    frames.append(draw(lines, cursor))
    durs.append(hold)

screen = []  # committed lines, each = list of (text,color) segs

def prompt_line(typed=""):
    return [("~/train ", BLUE), ("▸ ", PROMPT), (typed, FG)]

def type_cmd(cmd):
    for i in range(len(cmd) + 1):
        line = prompt_line(cmd[:i])
        add(screen + [line], hold=2, cursor=(len(screen), len("~/train ▸ ") + i))
    screen.append(prompt_line(cmd))

def out(segs, hold=1):
    screen.append(segs)
    add(screen, hold=hold)

def pause(ms):
    if frames:
        durs[-1] += ms / 10  # durs are centiseconds; convert ms

# --- scene 1: launch an agent
add(screen, hold=60)
type_cmd("copilot -p 'refactor the auth module'")
pause(400)
out([("● ", GREEN), ("agent working — burning CPU on your machine", FG)], hold=90)
pause(500)

# --- scene 2: cogwake sees it, blocks sleep
screen.append([("", FG)])
type_cmd("cogwake status")
out([("cogwake: ", DIM), ("ON", GREEN), (" (daemon running)", DIM)])
out([("sleep:   ", DIM), ("BLOCKED", YELLOW), (" (agent active)", DIM)], hold=110)
pause(700)

# --- scene 3: close the lid on the train
screen.append([("", FG)])
out([("» ", CYAN), ("lid closed · on battery · tether up · work keeps running", CYAN)], hold=130)
pause(900)

# --- scene 4: agent finishes
out([("✓ ", GREEN), ("agent done — 30s quiet timer starts", FG)], hold=110)
pause(700)

# --- scene 5: cogwake releases, Mac sleeps
screen.append([("", FG)])
type_cmd("cogwake status")
out([("cogwake: ", DIM), ("ON", GREEN), (" (daemon running)", DIM)])
out([("sleep:   ", DIM), ("allowed", GREEN)], hold=90)
out([("» ", DIM), ("30s quiet — Mac sleeps in your bag", DIM)], hold=200)
pause(1500)

# cs (centiseconds) -> gif durations
frames[0].save(
    os.path.join(os.path.dirname(__file__), "demo.gif"),
    save_all=True, append_images=frames[1:],
    duration=[max(2, int(x)) * 10 for x in durs],
    loop=0, optimize=True, disposal=2,
)
print(f"demo.gif  {W}x{H}  frames={len(frames)}")
