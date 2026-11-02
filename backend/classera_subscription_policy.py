"""Transactional Classera class limit. No provider, network or message operations."""
import sqlite3

ERROR = 'classera_subscription_limit_reached'
MESSAGE = ('You already have a Classera class subscription. A paused class still counts. '
           'Use HELP to manage your current class, or ask the administrator about an exception.')
OCCUPIED = ('active', 'paused')

def is_limit_error(error):
    return isinstance(error, sqlite3.IntegrityError) and str(error) == ERROR

def prepare_schema(conn):
    conn.execute('''CREATE TABLE IF NOT EXISTS orbit_classera_subscription_policy (
        phone TEXT PRIMARY KEY, allow_multiple INTEGER NOT NULL CHECK(allow_multiple IN (0,1)),
        updated_at TEXT NOT NULL)''')

def install(conn):
    """Explicit approved activation only; never rewrites existing subscriber rows."""
    prepare_schema(conn)
    conn.execute('''CREATE TRIGGER IF NOT EXISTS orbit_classera_single_class_insert
        BEFORE INSERT ON subscribers
        WHEN NEW.status IN ('active','paused')
        AND NOT EXISTS (SELECT 1 FROM orbit_classera_subscription_policy
                        WHERE phone=NEW.phone AND allow_multiple=1)
        AND NOT EXISTS (SELECT 1 FROM subscribers WHERE phone=NEW.phone
                        AND UPPER(class_name)=UPPER(NEW.class_name) AND status IN ('active','paused'))
        AND EXISTS (SELECT 1 FROM subscribers WHERE phone=NEW.phone
                    AND UPPER(class_name)<>UPPER(NEW.class_name) AND status IN ('active','paused'))
        BEGIN SELECT RAISE(ABORT,'classera_subscription_limit_reached'); END''')
    conn.execute('''CREATE TRIGGER IF NOT EXISTS orbit_classera_single_class_update
        BEFORE UPDATE OF phone,class_name,status ON subscribers
        WHEN NEW.status IN ('active','paused')
        AND NOT (OLD.phone=NEW.phone AND OLD.status IN ('active','paused'))
        AND NOT EXISTS (SELECT 1 FROM orbit_classera_subscription_policy
                        WHERE phone=NEW.phone AND allow_multiple=1)
        AND NOT EXISTS (SELECT 1 FROM subscribers WHERE phone=NEW.phone
                        AND UPPER(class_name)=UPPER(NEW.class_name) AND status IN ('active','paused'))
        AND EXISTS (SELECT 1 FROM subscribers WHERE phone=NEW.phone
                    AND UPPER(class_name)<>UPPER(NEW.class_name) AND status IN ('active','paused'))
        BEGIN SELECT RAISE(ABORT,'classera_subscription_limit_reached'); END''')

def read(conn, phone):
    row = conn.execute('SELECT allow_multiple FROM orbit_classera_subscription_policy WHERE phone=?',(phone,)).fetchone()
    multiple = bool(row and row[0] == 1)
    count = conn.execute("SELECT COUNT(DISTINCT UPPER(class_name)) FROM subscribers WHERE phone=? AND status IN ('active','paused')",(phone,)).fetchone()[0]
    enforced=conn.execute("SELECT COUNT(*) FROM sqlite_master WHERE type='trigger' AND name IN ('orbit_classera_single_class_insert','orbit_classera_single_class_update')").fetchone()[0]==2
    return {'version':1, 'enforced':enforced, 'allow_multiple':multiple, 'max_classes':None if multiple else 1,
            'occupied_classes':count, 'over_limit':not multiple and count>1,
            'counted_statuses':list(OCCUPIED)}

def set_override(conn, phone, allow_multiple, updated_at):
    if type(allow_multiple) is not bool:
        raise ValueError('allow_multiple must be a boolean')
    conn.execute('''INSERT INTO orbit_classera_subscription_policy VALUES(?,?,?)
        ON CONFLICT(phone) DO UPDATE SET allow_multiple=excluded.allow_multiple,updated_at=excluded.updated_at''',
        (phone,int(allow_multiple),updated_at))
    return read(conn,phone)
