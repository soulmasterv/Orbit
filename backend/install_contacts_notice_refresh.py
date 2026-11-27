"""Pure AST-guarded source patch preparation. This module never installs or restarts."""
import ast


def patch_phone_history(source):
    tree = ast.parse(source); lines = source.splitlines(keepends=True)
    nodes = [n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef) and n.name == 'diaa_history']
    if len(nodes) != 1: raise ValueError('Expected one history route')
    node = nodes[0]
    if 'orbit_call_history' in ast.get_source_segment(source, node): raise ValueError('Already patched')
    indent = ' ' * node.body[0].col_offset
    replacement = indent + 'from orbit_call_history import read_history\n' + indent + "payload, status = read_history(request.args, BROKER_DB, HOME/'jarvis/whatsapp-state/allowed-callers.json')\n" + indent + 'return jsonify(payload), status\n'
    lines[node.body[0].lineno-1:node.end_lineno] = [replacement]
    result = ''.join(lines); ast.parse(result); return result


def patch_ai_notice_hook(source):
    tree = ast.parse(source); lines = source.splitlines(keepends=True)
    nodes = [n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef) and n.name == 'handle_ai_button']
    if len(nodes) != 1: raise ValueError('Expected one AI handler')
    node = nodes[0]
    if 'after_ai_request' in ast.get_source_segment(source, node): raise ValueError('Already patched')
    branches = [n for n in ast.walk(node) if isinstance(n, ast.If) and isinstance(n.test, ast.Name) and n.test.id == 'ai_sent']
    if len(branches) != 1: raise ValueError('Expected verified AI-send branch')
    at = branches[0].body[0].lineno-1; indent = ' ' * branches[0].body[0].col_offset
    hook = [
        'try:',
        '    from classera_report_notices import after_ai_request as _orbit_after_ai_notice',
        '    _orbit_after_ai_notice(message, report_class)',
        'except Exception:',
        '    print("Report notice hook unavailable; AI response continues.", flush=True)',
        '',
    ]
    lines[at:at] = [indent + line + '\n' for line in hook]
    result = ''.join(lines); ast.parse(result); return result
