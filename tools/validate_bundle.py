"""Check branding, version, privacy strings and SideStore-compatible packaging."""
from pathlib import Path
import plistlib
import sys

app = Path(sys.argv[1])
with (app / 'Info.plist').open('rb') as source:
    info = plistlib.load(source)
assert info['CFBundleDisplayName'] == 'Orbit'
assert info['CFBundleIdentifier'] == 'com.servercontrol.app'
assert info['CFBundleShortVersionString'] == '4.0.0'
assert info.get('NSFaceIDUsageDescription')
icons = info.get('CFBundleIcons', {}).get('CFBundlePrimaryIcon', {})
assert icons.get('CFBundleIconName') == 'AppIcon', icons
assert icons.get('CFBundleIconFiles'), icons
assert list(app.glob('AppIcon*.png')), 'Missing compiled iPhone icon'
assert (app / 'Assets.car').is_file(), 'Missing compiled asset catalog'
assert 'remote-notification' not in info.get('UIBackgroundModes', [])
assert not list(app.glob('*.entitlements')), 'Unexpected entitlements'
assert b'--ui-preview' not in (app / 'Orbit').read_bytes(), 'Debug preview entry leaked into Release'
print('Validated V4 version, compiled AppIcon, Face ID description and unsigned bundle.')

