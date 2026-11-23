import os
from PIL import Image, ImageDraw, ImageFont

S = 1024
img = Image.new("RGB", (S, S), "#1F3A34")

# 竖向渐变：墨绿 → 深墨
top = (46, 84, 74)
bottom = (18, 32, 29)
d = ImageDraw.Draw(img)
for y in range(S):
    t = y / (S - 1)
    c = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
    d.line([(0, y), (S, y)], fill=c)

# 书页：白色圆角矩形 + 中缝
margin = 190
card = [margin, 150, S - margin, S - 150]
d.rounded_rectangle(card, radius=54, fill="#F6F1E7")
spine_x = S // 2
d.rectangle([spine_x - 3, card[1] + 26, spine_x + 3, card[3] - 26], fill="#D8CFBE")

# 文字：夜 / 读 分列左右
font_path = r"C:\Windows\Fonts\msyhbd.ttc"
font = ImageFont.truetype(font_path, 250)
for ch, cx in (("夜", S // 2 - 150), ("读", S // 2 + 150)):
    bbox = d.textbbox((0, 0), ch, font=font)
    w = bbox[2] - bbox[0]
    h = bbox[3] - bbox[1]
    d.text((cx - w / 2 - bbox[0], S / 2 - h / 2 - bbox[1]), ch, font=font, fill="#24403A")

out_dir = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                       "Sources", "Assets.xcassets", "AppIcon.appiconset")
os.makedirs(out_dir, exist_ok=True)
img.save(os.path.join(out_dir, "icon-1024.png"), "PNG")
print("wrote", os.path.join(out_dir, "icon-1024.png"))
