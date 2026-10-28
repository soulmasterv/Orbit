"""Normalize receipt-only events. Never invokes an inbound handler or sends messages."""
STATES=("sent","delivered","read","failed")

def route_kapso_receipt(payload,update):
    if not isinstance(payload,dict):return False
    if payload.get("test") is True:return True
    message=payload.get("message")
    if not isinstance(message,dict):return False
    metadata=message.get("kapso")
    if not isinstance(metadata,dict) or metadata.get("direction")!="outbound":return False
    # All outbound envelopes are receipt-only, including unknown states.
    identifier=message.get("id");status=metadata.get("status")
    if isinstance(identifier,str) and identifier and status in STATES:
        update(identifier,status,event_at=None)
    return True

def advance_legacy(db,message_id,status):
    # Match the existing delivery guard table without weakening its recipient guard.
    cursor=db.execute("""UPDATE deliveries SET status=?,updated_at=CURRENT_TIMESTAMP
      WHERE message_id=? AND (
        status NOT IN ('sent','delivered','read','failed')
        OR (status='sent' AND ? IN ('sent','delivered','read','failed'))
        OR (status='failed' AND ? IN ('failed','delivered','read'))
        OR (status='delivered' AND ? IN ('delivered','read'))
        OR (status='read' AND ?='read')
      )""",(status,message_id,status,status,status,status))
    return cursor.rowcount>0

def replay_recorded_receipts(logfile,known_ids,update):
    import ast
    from collections import Counter
    # Bounded local recovery. Never executes log text, invokes inbound handlers,
    # fetches provider URLs, creates recipients or sends messages.
    with open(logfile,"rb") as handle:
        handle.seek(0,2);size=handle.tell();handle.seek(max(0,size-8*1024*1024))
        lines=handle.read(8*1024*1024).decode("utf-8",errors="replace").splitlines()
    counts=Counter();matched=set()
    for line in lines:
        if not line.startswith("{") or len(line)>1024*1024:continue
        try:payload=ast.literal_eval(line)
        except (SyntaxError,ValueError,TypeError,RecursionError):continue
        if not isinstance(payload,dict) or payload.get("test") is True:continue
        receipts=[]
        message=payload.get("message")
        if isinstance(message,dict):
            meta=message.get("kapso") or {}
            if isinstance(meta,dict) and meta.get("direction")=="outbound":
                receipts.append((message.get("id"),meta.get("status"),None))
        entries=payload.get("entry",[])
        if not isinstance(entries,list):continue
        for entry in entries:
            if not isinstance(entry,dict):continue
            changes=entry.get("changes",[])
            if not isinstance(changes,list):continue
            for change in changes:
                if not isinstance(change,dict):continue
                value=change.get("value") or {}
                if not isinstance(value,dict):continue
                statuses=value.get("statuses",[])
                if not isinstance(statuses,list):continue
                for status in statuses:
                    if isinstance(status,dict):receipts.append((status.get("id"),status.get("status"),status.get("timestamp")))
        for identifier,status,when in receipts:
            if isinstance(identifier,str) and identifier in known_ids and status in STATES:
                update(identifier,status,event_at=when)
                counts[status]+=1;matched.add(identifier)
    return {"receipt_events":dict(counts),"matched_message_count":len(matched)}
