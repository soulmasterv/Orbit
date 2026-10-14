"""Build the Orbit iOS icon from the supplied logo (requires Pillow)."""
from pathlib import Path
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
source = Image.open(ROOT / 'tools/orbit-logo.png').convert('RGB')
# iOS app icons must be square and opaque. Preserve the supplied artwork.
canvas = Image.new('RGB', (1024, 1024), 'black')
scale = 960 / max(source.size)
source = source.resize((round(source.width * scale), round(source.height * scale)), Image.Resampling.LANCZOS)
canvas.paste(source, ((1024-source.width)//2, (1024-source.height)//2))
destination = ROOT / 'ServerControl/Assets.xcassets/AppIcon.appiconset/AppIcon.png'
destination.parent.mkdir(parents=True, exist_ok=True)
canvas.save(destination)
assert Image.open(destination).mode == 'RGB'
print('Created opaque 1024x1024 Orbit AppIcon.png')
