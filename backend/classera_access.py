"""Shared, fail-closed reply/report gate. No provider imports or credentials."""
import sqlite3
import re
DB = '/home/local/classera/shared/subscribers.sqlite3'

def can_reply(phone, path=None):
    phone=str(phone).removeprefix('+')
    if not re.fullmatch(r'[1-9][0-9]{7,14}',phone): return False
    try:
        conn = sqlite3.connect('file:'+str(path or DB)+'?mode=rw',uri=True,timeout=5)
        try:
            row = conn.execute('SELECT activity_status FROM orbit_student_controls WHERE phone=?',(phone,)).fetchone()
            return row is None or row[0] == 'allowed'
        finally: conn.close()
    except sqlite3.Error:
        return False
