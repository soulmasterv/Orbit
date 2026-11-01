"""Pure, fail-closed source patch planner. Importing this module changes nothing.

Deployment tooling supplies exact approved paths, backups, expected hashes and
tests. This function never imports or runs a real report producer.
"""
import ast


def patch_sender(source):
    tree = ast.parse(source)
    functions = [n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == 'notify_all']
    if len(functions) != 1 or [a.arg for a in functions[0].args.args] != ['report_title', 'ai_summary', 'pdf_path']:
        raise RuntimeError('report_sender_layout_changed')
    function = functions[0]
    if any(isinstance(n, ast.Name) and n.id.startswith('_orbit_notice_') for n in ast.walk(function)):
        raise RuntimeError('notice_hook_already_present')
    filenames = [n for n in ast.walk(function) if isinstance(n, ast.Assign) and any(isinstance(t, ast.Name) and t.id == 'filename' for t in n.targets)]
    sends = [n for n in ast.walk(function) if isinstance(n, ast.Assign) and isinstance(n.value, ast.Call) and isinstance(n.value.func, ast.Name) and n.value.func.id == 'send_template']
    if len(filenames) != 1 or len(sends) != 1 or [t.id for t in sends[0].targets if isinstance(t, ast.Name)] != ['result']:
        raise RuntimeError('report_sender_layout_changed')
    names = {n.id for n in ast.walk(function) if isinstance(n, ast.Name)}
    if not {'single_recipient', 'force_resend', 'recipients', 'CLASSERA_CLASS', 'CLASSERA_ID', 'get_status', 'to'}.issubset(names):
        raise RuntimeError('report_sender_guards_missing')
    tries = [n for n in ast.walk(function) if isinstance(n, ast.Try) and any(sends[0] is child for statement in n.body for child in ast.walk(statement))]
    if len(tries) != 1 or len(tries[0].handlers) != 1 or not tries[0].handlers[0].body:
        raise RuntimeError('report_sender_exception_layout_changed')
    indent = ' ' * filenames[0].col_offset
    prepare = '''try:
    from classera_report_notices import prepare as _orbit_notice_prepare, after_report as _orbit_notice_after
except Exception:
    _orbit_notice_prepare = lambda *args, **kwargs: None
    _orbit_notice_after = lambda *args, **kwargs: None
_orbit_notice_batch = _orbit_notice_prepare(CLASSERA_CLASS, report_title, recipients,
    single=bool(single_recipient), forced=force_resend,
    already_started=any(get_status(report_title, recipient, CLASSERA_ID) is not None for recipient in recipients))
'''
    additions = [(filenames[0].end_lineno, ''.join(indent + line + '\n' for line in prepare.splitlines()))]
    additions.append((tries[0].body[-1].end_lineno, ' ' * sends[0].col_offset + '_orbit_notice_after(_orbit_notice_batch, to, report_accepted=bool(result))\n'))
    handler = tries[0].handlers[0]
    additions.append((handler.body[0].lineno - 1, ' ' * handler.body[0].col_offset + '_orbit_notice_after(_orbit_notice_batch, to, report_accepted=False)\n'))
    lines = source.splitlines(keepends=True)
    for index, content in sorted(additions, reverse=True): lines[index:index] = [content]
    patched = ''.join(lines)
    changed = ast.parse(patched)

    class RemoveOnlyAddedHooks(ast.NodeTransformer):
        def visit_Try(self, node):
            if any(isinstance(n, ast.ImportFrom) and n.module == 'classera_report_notices' for n in node.body): return None
            return self.generic_visit(node)
        def visit_Assign(self, node):
            if any(isinstance(t, ast.Name) and t.id == '_orbit_notice_batch' for t in node.targets): return None
            return self.generic_visit(node)
        def visit_Expr(self, node):
            if isinstance(node.value, ast.Call) and isinstance(node.value.func, ast.Name) and node.value.func.id == '_orbit_notice_after': return None
            return self.generic_visit(node)

    restored = RemoveOnlyAddedHooks().visit(changed)
    if ast.dump(restored, include_attributes=False) != ast.dump(tree, include_attributes=False):
        raise RuntimeError('unexpected_report_logic_change')
    compile(patched, '<planned report sender>', 'exec')
    return patched
