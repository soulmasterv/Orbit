"""Stage/validate by default. --apply adds one read-only route, never restarts."""
import ast
import hashlib
import os
from pathlib import Path
import shutil
import time

ROOT = Path('/home/local/ios-swift-app')


def patched(source):
    tree = ast.parse(source)
    if 'register_ai_key_usage(app, SERVER_TOKEN)' in source:
        return source
    nodes = [n for n in tree.body if isinstance(n, ast.Expr) and isinstance(n.value, ast.Call)
             and isinstance(n.value.func, ast.Name) and n.value.func.id == 'register_classera_students']
    if len(nodes) != 1 or ast.unparse(nodes[0].value) != 'register_classera_students(app, SERVER_TOKEN)':
        raise RuntimeError('Owner API integration changed; inspect before applying.')
    lines = source.splitlines(keepends=True)
    lines.insert(nodes[0].end_lineno, '\nfrom ai_key_usage import register as register_ai_key_usage\nregister_ai_key_usage(app, SERVER_TOKEN)\n')
    result = ''.join(lines)
    ast.parse(result)
    return result


def main(apply=False):
    target = ROOT / 'server_control.py'
    original = target.read_text()
    updated = patched(original)
    stage = Path(__file__).parent / 'ai_key_usage.py'
    compile(stage.read_text(), str(stage), 'exec')
    print('Plan: add GET /api/classera/ai-key-usage using existing owner authentication.')
    print('No database, key configuration, report, WhatsApp, scheduler or tunnel changes.')
    print('No service restart is performed by this installer.')
    if not apply:
        print('Plan validated. Nothing installed.')
        return
    backup = Path('/home/local/.local/state/orbit-fixes') / ('ai-key-usage-' + str(time.time_ns()))
    backup.mkdir(parents=True, mode=0o700)
    shutil.copy2(target, backup / target.name)
    module = ROOT / 'ai_key_usage.py'
    if module.exists(): shutil.copy2(module, backup / module.name)
    shutil.copy2(stage, module)
    os.chmod(module, 0o600)
    # Refuse a concurrent production edit between planning and the final replacement.
    if target.read_text() != original:
        raise RuntimeError('Concurrent API edit; no source replaced.')
    temp = target.with_suffix('.ai-usage-stage')
    temp.write_text(updated)
    shutil.copymode(target, temp)
    os.replace(temp, target)
    print('Installed; backup:', backup)
    print('Requires separately approved ios-server-control restart before live verification.')


if __name__ == '__main__':
    import sys
    main('--apply' in sys.argv)
