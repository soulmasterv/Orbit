"""Build Orbit's app icon and in-app logo from the approved square artwork."""
from pathlib import Path
from PIL import Image
import json

ROOT = Path(__file__).resolve().parents[1]
source = Image.open(ROOT / 'tools/orbit-logo.png').convert('RGB')
assert source.width == source.height, 'Use the approved square logo'
image = source.resize((1024, 1024), Image.Resampling.LANCZOS)
catalog = ROOT / 'ServerControl/Assets.xcassets'
icon = catalog / 'AppIcon.appiconset/AppIcon.png'
logo = catalog / 'OrbitLogo.imageset'
icon.parent.mkdir(parents=True, exist_ok=True)
logo.mkdir(parents=True, exist_ok=True)
image.save(icon)
image.save(logo / 'OrbitLogo.png')
(logo / 'Contents.json').write_text(json.dumps({
    'images': [{'filename': 'OrbitLogo.png', 'idiom': 'universal'}],
    'info': {'author': 'xcode', 'version': 1}
}, indent=2))
assert Image.open(icon).mode == 'RGB'
assert icon.read_bytes() == (logo / 'OrbitLogo.png').read_bytes()
print('Created matching edge-to-edge Orbit app icon and in-app logo.')
