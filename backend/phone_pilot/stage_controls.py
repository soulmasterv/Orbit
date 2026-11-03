"""Stage the phone controls on the Ubuntu host, with exact source guards and backups."""
import argparse
import ast
import hashlib
import shutil
import subprocess
import time
from pathlib import Path

HOME = Path.home()
SOURCE = Path(__file__).resolve().parent

QUEUE_ROUTES = """      if(req.url==='/internal/call-jobs/orbit-queue'){
        const jobs=controls.state.jobs.filter(j=>j.status==='pending'&&j.expires>controls.now())
          .slice(0,25).map(j=>({id:j.id,not_before:j.not_before??null,expires:j.expires}));
        return json(200,{jobs});
      }
      if(req.url==='/internal/call-jobs/orbit-cancel'){
        const job=controls.state.jobs.find(j=>j.id===m.id);
        if(!job||job.status!=='pending'||job.expires<=controls.now())return json(409,{});
        controls.cancelJob(job.id);
        return json(200,{status:'cancelled'});
      }
"""


def replace_once(source, old, new):
    if source.count(old) != 1:
        raise ValueError('Expected exactly one deployment marker: ' + old[:80])
    return source.replace(old, new, 1)


def changes():
    worker = HOME / 'jarvis-phone-integration/allowed_caller.py'
    source = worker.read_text()
    source = replace_once(source, 'def main():\n', 'from phone_controls import answering_paused\n\ndef main():\n')
    source = replace_once(
        source, '        elif armed:\n',
        '        elif answering_paused():\n            armed=False\n        elif armed:\n'
    )
    source = replace_once(
        source, "if single(snapshot,phone,'1') and single(read_precise(serial),phone,'1'):",
        "if single(snapshot,phone,'1') and single(read_precise(serial),phone,'1') and not answering_paused():"
    )
    broker = HOME / 'school-bot/jarvis_phone_alerts.py'
    broker_code = replace_once(
        broker.read_text(),
        "event_mode='web' if offline else mode",
        "event_mode='web' if offline or row['kind']=='orbit_test_web' else mode"
    )
    queue = HOME / 'jarvis/tasks-runtime.mjs'
    queue_code = replace_once(
        queue.read_text(), "      if(req.url==='/internal/call-jobs/claim')",
        QUEUE_ROUTES + "      if(req.url==='/internal/call-jobs/claim')"
    )
    gateway = HOME / 'jarvis/whatsapp-adapter/notification-http.mjs'
    gateway_code = replace_once(
        gateway.read_text(), "   if(seen[m.id])",
        "   if(m.expectedRecipient!==undefined&&m.expectedRecipient!==recipient)return reply(409,{});\n   if(seen[m.id])"
    )
    result = {worker: source, broker: broker_code, queue: queue_code, gateway: gateway_code}
    for directory in ('ios-swift-app', 'school-bot'):
        result[HOME / directory / 'orbit_phone_pilot.py'] = (SOURCE / 'orbit_phone_pilot.py').read_text()
        result[HOME / directory / 'phone_controls.py'] = (SOURCE / 'phone_controls.py').read_text()
    result[HOME / 'jarvis-phone-integration/phone_controls.py'] = (SOURCE / 'phone_controls.py').read_text()
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    files = changes()
    for path, content in files.items():
        if path.suffix == '.py':
            ast.parse(content, filename=str(path))
        else:
            subprocess.run(['node', '--input-type=module', '--check'], input=content, text=True, check=True)
        print(path.relative_to(HOME), hashlib.sha256(content.encode()).hexdigest())
    if not args.apply:
        return
    backup = HOME / ('orbit-controls-backup-' + str(time.time_ns()))
    backup.mkdir(mode=0o700)
    for path in files:
        if path.exists():
            copy = backup / path.relative_to(HOME)
            copy.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, copy)
    print('Backup:', backup, flush=True)
    for path, content in files.items():
        tmp = path.with_suffix(path.suffix + '.orbit-new')
        tmp.write_text(content)
        tmp.chmod(path.stat().st_mode & 0o777 if path.exists() else 0o600)
        tmp.replace(path)


if __name__ == '__main__':
    main()
