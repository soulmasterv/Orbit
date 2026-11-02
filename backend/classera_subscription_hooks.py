"""Small source transformations for private Ubuntu handlers; no source logging."""
import ast

def _wrap(source, statement, tail):
    lines=source.splitlines(keepends=True)
    first=statement.lineno-1;last=statement.end_lineno
    indent=' ' * statement.col_offset
    original=''.join(lines[first:last])
    replacement=indent+'try:\n'+''.join('    '+line for line in original.splitlines(keepends=True))
    if not replacement.endswith('\n'):replacement+='\n'
    replacement+=indent+'except Exception as orbit_limit_exception:\n'
    replacement+=indent+'    from classera_subscription_policy import is_limit_error, MESSAGE\n'
    replacement+=indent+'    if not is_limit_error(orbit_limit_exception):\n'+indent+'        raise\n'
    replacement+=''.join(indent+'    '+line+'\n' for line in tail)
    result=''.join(lines[:first])+replacement+''.join(lines[last:])
    ast.parse(result)
    return result

def patch_signup(source):
    if 'except Exception as orbit_limit_exception:' in source:raise ValueError('Signup already patched; inspect current file')
    tree=ast.parse(source)
    functions=[n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name=='handle_self_service']
    if len(functions)!=1:raise ValueError('Unexpected signup handler')
    calls=[n for n in ast.walk(functions[0]) if isinstance(n,ast.Expr) and isinstance(n.value,ast.Call) and isinstance(n.value.func,ast.Name) and n.value.func.id=='save_active']
    if len(calls)!=1:raise ValueError('Unexpected active signup write count')
    return _wrap(source,calls[0],['send_text(phone, MESSAGE, phone_number_id)','return True'])

def patch_rejoin(source):
    if 'except Exception as orbit_limit_exception:' in source:raise ValueError('Rejoin already patched; inspect current file')
    tree=ast.parse(source)
    functions=[n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name=='handle']
    if len(functions)!=1:raise ValueError('Unexpected subscription handler')
    writes=[n for n in ast.walk(functions[0]) if isinstance(n,ast.Expr) and isinstance(n.value,ast.Call) and isinstance(n.value.func,ast.Attribute) and n.value.func.attr=='execute' and n.value.args and isinstance(n.value.args[0],ast.Constant) and "SET status='active'" in str(n.value.args[0].value) and "status='opted_out'" in str(n.value.args[0].value)]
    if len(writes)!=1:raise ValueError('Unexpected rejoin write count')
    return _wrap(source,writes[0],['return MESSAGE'])
