"""Per-account portable sync: IDs and playback facts, never stream URLs or keys."""
import json
import time

from fastapi import HTTPException

from hub_core import bounded_text, integer, song_id, validate_preferences, validate_station


class Sync:
    def __init__(self, store):
        self.store = store

    def read(self, owner):
        user = self.store.user(owner)
        with self.store.connect() as db:
            queue = db.execute('SELECT * FROM snapshots WHERE owner=?', (owner,)).fetchone()
            history = db.execute('SELECT payload FROM history WHERE owner=? ORDER BY started DESC LIMIT 100', (owner,)).fetchall()
        return {'revision': user['revision'], 'preferences': json.loads(user['preferences']) if user['preferences'] else None,
            'stations': list(json.loads(user['stations']).values()), 'guard': bool(user['guard']),
            'includeWarnings': bool(user['warnings']), 'history': [json.loads(row[0]) for row in history],
            'queue': None if queue is None else {**json.loads(queue['payload']), 'updated': queue['updated']}}

    def configuration(self, owner, body):
        self.store.user(owner)
        upserts, deletes = body.get('upsertStations', []), body.get('deleteStations', [])
        if not isinstance(upserts, list) or not isinstance(deletes, list) or len(upserts) > 200 or len(deletes) > 200:
            raise HTTPException(400, 'Too many station changes')
        upserts = [validate_station(station) for station in upserts]
        deletes = [bounded_text(value, 64) for value in deletes]
        preferences = validate_preferences(body['preferences']) if 'preferences' in body else None
        for field in ('guard', 'includeWarnings'):
            if field in body and type(body[field]) is not bool:
                raise HTTPException(400, 'Invalid playback guard setting')
        with self.store.lock, self.store.connect() as db:
            user = db.execute('SELECT * FROM users WHERE id=?', (owner,)).fetchone()
            stations = json.loads(user['stations'])
            for value in deletes:
                stations.pop(value, None)
            for station in upserts:
                stations[station['id']] = station
            if len(stations) > 200:
                raise HTTPException(400, 'At most 200 saved stations can be synced')
            db.execute('UPDATE users SET stations=?,preferences=?,guard=?,warnings=?,revision=revision+1 WHERE id=?',
                (json.dumps(stations), json.dumps(preferences) if preferences is not None else user['preferences'],
                    int(body.get('guard', user['guard'])), int(body.get('includeWarnings', user['warnings'])), owner))
        return self.read(owner)

    def history(self, owner, body):
        items = body.get('items')
        if not isinstance(items, list) or len(items) > 200:
            raise HTTPException(400, 'History batches are limited to 200 plays')
        validated = []
        now = int(time.time() * 1000)
        for item in items:
            if not isinstance(item, dict):
                raise HTTPException(400, 'Invalid history entry')
            value = {'id': bounded_text(item.get('id'), 120), 'song': song_id(item.get('song')),
                'startedMs': integer(item.get('startedMs'), 0, now + 86400000),
                'playedMs': integer(item.get('playedMs', 0), 0, 86400000)}
            validated.append(value)
        with self.store.lock, self.store.connect() as db:
            for value in validated:
                existing = db.execute('SELECT payload FROM history WHERE owner=? AND id=?', (owner, value['id'])).fetchone()
                if existing:
                    value['playedMs'] = max(value['playedMs'], json.loads(existing[0])['playedMs'])
                db.execute('INSERT OR REPLACE INTO history VALUES(?,?,?,?)',
                    (owner, value['id'], value['startedMs'], json.dumps(value)))
            db.execute('DELETE FROM history WHERE owner=? AND id NOT IN '
                '(SELECT id FROM history WHERE owner=? ORDER BY started DESC LIMIT 10000)', (owner, owner))
        return {'saved': len(validated)}

    def queue(self, owner, body):
        ids = body.get('ids')
        if not isinstance(ids, list) or not 1 <= len(ids) <= 2000:
            raise HTTPException(400, 'Queue snapshots need 1 to 2000 songs')
        if type(body.get('playing')) is not bool or type(body.get('claim', False)) is not bool:
            raise HTTPException(400, 'Invalid playback state')
        value = {'ids': [song_id(item) for item in ids], 'index': integer(body.get('index'), 0, len(ids) - 1),
            'positionMs': integer(body.get('positionMs'), 0, 86400000), 'playing': body['playing'],
            'device': bounded_text(body.get('device'), 100), 'name': bounded_text(body.get('name', 'Saved queue'), 100)}
        with self.store.lock, self.store.connect() as db:
            previous = db.execute('SELECT * FROM snapshots WHERE owner=?', (owner,)).fetchone()
            # Only an explicit new playback or "Resume here" transfers ownership.
            # A waking, paused or still-playing old phone cannot overwrite it.
            if previous and previous['device'] != value['device'] and not body.get('claim'):
                raise HTTPException(409, 'Another device owns the saved queue')
            db.execute('INSERT OR REPLACE INTO snapshots VALUES(?,?,?,?,?)',
                (owner, value['device'], json.dumps(value), int(value['playing']), time.time()))
        return {'saved': True}
