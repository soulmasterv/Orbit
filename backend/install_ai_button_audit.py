"""Pure AST-verified patch planner; never writes files or restarts a service."""
import ast


def patch_webhook(source):
    tree = ast.parse(source)
    receive = next((n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == 'receive_webhook'), None)
    if receive is None: raise ValueError('webhook_shape_changed')
    if any(isinstance(n, ast.Name) and n.id == '_orbit_observe_ai_button' for n in ast.walk(tree)):
        raise ValueError('audit_already_installed')
    calls = [n for n in ast.walk(receive) if isinstance(n, ast.Expr) and isinstance(n.value, ast.Call)
             and isinstance(n.value.func, ast.Name) and n.value.func.id == 'handle_ai_button']
    if len(calls) != 2: raise ValueError('webhook_shape_changed')
    lines = source.splitlines(keepends=True)
    for node in sorted(calls, key=lambda n: n.lineno, reverse=True):
        call = node.value
        if len(call.args) != 2 or not all(isinstance(v, ast.Name) for v in call.args) or call.keywords:
            raise ValueError('webhook_call_changed')
        indent = ' ' * node.col_offset
        hook = [indent + 'try:\n',
                indent + '    from classera_ai_activity import observe_button as _orbit_observe_ai_button\n',
                indent + '    _orbit_observe_ai_button(' + call.args[0].id + ')\n',
                indent + 'except Exception:\n', indent + '    pass  # Auditing must not interrupt existing webhook handling.\n']
        lines[node.lineno - 1:node.lineno - 1] = hook
    patched = ''.join(lines)
    new_tree = ast.parse(patched)
    # Removing only our added try statements must restore the complete original AST.
    class RemoveAudit(ast.NodeTransformer):
        def visit_Try(self, node):
            if any(isinstance(n, ast.Name) and n.id == '_orbit_observe_ai_button' for n in ast.walk(node)) and len(node.body) == 2 and isinstance(node.body[0], ast.ImportFrom) and node.body[0].module == 'classera_ai_activity':
                return None
            return self.generic_visit(node)
    if ast.dump(RemoveAudit().visit(new_tree), include_attributes=False) != ast.dump(tree, include_attributes=False):
        raise ValueError('webhook_ast_not_preserved')
    return patched
