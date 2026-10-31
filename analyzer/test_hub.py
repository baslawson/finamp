import hashlib
import io
import json
import os
import sqlite3
import tarfile
import tempfile
import threading
import time
import unittest
import zipfile
from datetime import datetime
from pathlib import Path
from unittest.mock import Mock, PropertyMock, patch

from fastapi import FastAPI, HTTPException
from fastapi.testclient import TestClient

from hub import Hub, create_app
from hub_core import Actor, Jellyfin, Store, revision
from hub_jobs import Jobs
from hub_radio import Radio, scheduled_program

OWNER, OTHER, SONG, SECOND = 'a' * 32, 'b' * 32, 'c' * 32, 'd' * 32


class HubTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.music = self.root / 'music'
        self.music.mkdir()
        self.source = self.music / 'song.wav'
        self.source.write_bytes(b'music')
        self.items = [{'Id': value, 'Name': name, 'Type': 'Audio', 'Artists': [artist],
            'Path': str(self.source), 'RunTimeTicks': 300000000, 'UserData': {'PlayCount': plays}}
            for value, name, artist, plays in [(SONG, 'First', 'One', 0), (SECOND, 'Second', 'Two', 5)]]
        self.jf = Mock()
        self.jf.brief = Jellyfin.brief
        self.jf.actor.side_effect = lambda token=None, owner=None: Actor(
            OTHER if token == 'other' or owner == OTHER else OWNER, 'Listener', token != 'other' and owner != OTHER)
        self.jf.items.side_effect = lambda owner, ids=None, **kw: [item for item in self.items if ids is None or item['Id'] in ids]
        self.jf.item.side_effect = lambda owner, value: next(item for item in self.items if item['Id'] == value)
        self.jf.path.return_value = self.source
        self.jf.lyrics.return_value = [{'timeMs': 0, 'text': 'Sing'}]
        self.hub = Hub(self.root, self.jf, 'private', 'http://worker')
        self.hub.karaoke = Mock(return_value={'state': 'missing'})
        self.hub.store.save_settings({'owner': OWNER})
        self.hub.caps
        self.app = FastAPI()
        self.app.mount('/hub', create_app(self.hub))
        self.client = TestClient(self.app)
        self.headers = {'X-Api-Key': 'private', 'X-Jellyfin-Token': 'owner'}

    def api(self, method, path, body=None, headers=None):
        return self.client.request(method, '/hub/api' + path, json=body,
            headers=self.headers if headers is None else headers)

    def room(self):
        response = self.api('POST', '/rooms', {'name': '<b>TV</b>'})
        self.assertEqual(response.status_code, 200, response.text)
        return response.json()

    def role(self, room, role):
        return {'Authorization': 'Bearer ' + room[role]}

    def command(self, room, action, rev=0, **values):
        return self.api('POST', '/room/command', {'action': action, 'revision': rev, **values}, self.role(room, 'control'))

    def test_static_mount_and_security_headers(self):
        for path in ['/hub/', '/hub/tv/', '/hub/admin/', '/hub/assets/hub.js', '/hub/assets/hub.css']:
            response = self.client.get(path)
            self.assertEqual(response.status_code, 200, path)
            self.assertEqual(response.headers['referrer-policy'], 'no-referrer')
            self.assertIn("frame-ancestors 'none'", response.headers['content-security-policy'])
        self.assertEqual(self.client.get('/hub/assets/other').status_code, 404)

    def test_native_auth_requires_both_credentials(self):
        for headers in [{}, {'X-Api-Key': 'private'}, {'X-Api-Key': 'wrong', 'X-Jellyfin-Token': 'owner'}]:
            self.assertEqual(self.api('GET', '/sync', headers=headers).status_code, 401)
        self.assertEqual(self.api('GET', '/status').status_code, 200)

    def test_native_auth_refuses_empty_and_placeholder_tokens_even_when_they_match(self):
        for token in ['', 'change-me', 'change-me-too']:
            with self.subTest(token=token), patch.object(self.hub, 'token', token):
                headers = {**self.headers, 'X-Api-Key': token}
                for path in ['/status', '/session']:
                    method = 'POST' if path == '/session' else 'GET'
                    self.assertEqual(self.api(method, path, headers=headers).status_code, 401)
        self.jf.actor.assert_not_called()
        self.assertEqual(self.api('GET', '/status').status_code, 200)

    def test_browser_session_and_tampering_expiry_scope(self):
        session = self.api('POST', '/session').json()['token']
        self.assertEqual(self.api('GET', '/status', headers={'Authorization': 'Bearer ' + session}).status_code, 200)
        for token in [session + 'x', self.hub.caps.issue('session', OWNER, seconds=-1), self.hub.caps.issue('radio', OWNER), 'bad.@@']:
            self.assertEqual(self.api('GET', '/status', headers={'Authorization': 'Bearer ' + token}).status_code, 401)
        # A copied link can't make itself another hour: only Finamp's own sign-in makes a session.
        self.assertEqual(self.api('POST', '/session', headers={'Authorization': 'Bearer ' + session}).status_code, 403)

    def test_disabled_and_non_admin_accounts(self):
        headers = {**self.headers, 'X-Jellyfin-Token': 'other'}
        for path in ['/settings', '/jobs', '/backups', '/health', '/lyrics', '/radio', '/runtime']:
            self.assertEqual(self.api('GET', path, headers=headers).status_code, 403)
        self.jf.actor.side_effect = HTTPException(403, 'Disabled')
        self.hub.actor_cache.clear()
        self.assertEqual(self.api('GET', '/status').status_code, 403)

    def test_runtime_dashboard_and_background_deferral_keep_jobs_retryable(self):
        response = self.api('GET', '/runtime')
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()['jobs'], [])
        runtime = self.hub.runtime = Mock()
        runtime.try_acquire.return_value = (None, 'Playback has priority')
        value = self.hub.store.enqueue('health', 'manual-test', {'limit': 3})
        self.assertFalse(self.hub.jobs.run_one())
        with self.hub.store.connect() as db:
            row = db.execute('SELECT state,message FROM jobs WHERE id=?', (value,)).fetchone()
        self.assertEqual(tuple(row), ('queued', 'Playback has priority'))
        runtime.try_acquire.return_value = (object(), None)
        self.hub.jobs.health = Mock(return_value='Checked three songs')
        self.assertTrue(self.hub.jobs.run_one())
        runtime.release.assert_called_once()
        with self.hub.store.connect() as db:
            self.assertEqual(db.execute('SELECT state FROM jobs WHERE id=?', (value,)).fetchone()[0], 'ready')

    def test_job_processing_resolves_store_before_taking_its_lock(self):
        from server_runtime import WorkDeferred
        store = self.hub.store
        store.save_settings({'nightlyEnd': 24})
        value = store.enqueue('health', 'scheduled:health:today', {'limit': 3})
        runtime = self.hub.runtime = Mock()
        runtime.try_acquire.return_value = (object(), None)
        self.hub.jobs.health = Mock(side_effect=WorkDeferred('Waiting for memory'))
        def resolve():
            self.assertFalse(store.lock._is_owned(), 'Resolve hub.store before taking store.lock')
            return store
        with patch.object(Hub, 'store', new_callable=PropertyMock, side_effect=resolve):
            self.assertTrue(self.hub.jobs.run_one())
            with store.connect() as db:
                row = db.execute('SELECT state,message FROM jobs WHERE id=?', (value,)).fetchone()
            self.assertEqual(tuple(row), ('queued', 'Waiting for memory'))
            self.hub.jobs.health.side_effect = None
            self.hub.jobs.health.return_value = 'Checked'
            self.assertTrue(self.hub.jobs.run_one())
            self.assertFalse(self.hub.jobs.run_one())
        with store.connect() as db:
            self.assertEqual(db.execute('SELECT state FROM jobs WHERE id=?', (value,)).fetchone()[0], 'ready')

    def test_runtime_dashboard_includes_karaoke_queue_without_opening_it_for_writes(self):
        folder = self.root / 'karaoke'
        folder.mkdir()
        database = folder / 'jobs.db'
        with sqlite3.connect(database) as db:
            db.execute('CREATE TABLE jobs(state TEXT,message TEXT,queued REAL)')
            db.executemany('INSERT INTO jobs VALUES(?,?,?)', [
                ('processing', 'Separating vocals', time.time() - 2000),
                ('queued', 'Waiting for more available memory', time.time()),
                ('ready', 'Ready', time.time())])
        response = self.api('GET', '/runtime')
        self.assertEqual(response.status_code, 200)
        jobs = response.json()['jobs']
        self.assertEqual([job['state'] for job in jobs], ['processing', 'queued'])
        self.assertTrue(jobs[0]['attention'])
        self.assertEqual(jobs[1]['message'], 'Waiting for more available memory')
        with sqlite3.connect(database) as db:
            self.assertEqual(db.execute('SELECT count(*) FROM jobs').fetchone()[0], 3)
            db.execute('DROP TABLE jobs')
        response = self.api('GET', '/runtime')
        self.assertEqual(response.status_code, 200)
        self.assertIn('Karaoke queue status is temporarily unavailable', response.json()['warnings'])

    def test_health_deferral_retains_cursor_and_cleanup_is_not_blocked_by_low_storage(self):
        from server_runtime import WorkDeferred
        runtime = self.hub.runtime = Mock()
        runtime.try_acquire.return_value = (object(), None)
        value = self.hub.store.enqueue('health', 'cursor', {'limit': 3})
        def defer(args):
            args.update(_offset=12, _checked=2)
            raise WorkDeferred('Playback needs disk capacity')
        self.hub.jobs.health = Mock(side_effect=defer)
        self.hub.jobs.run_one()
        with self.hub.store.connect() as db:
            row = db.execute('SELECT state,args FROM jobs WHERE id=?', (value,)).fetchone()
        self.assertEqual(row['state'], 'queued')
        self.assertEqual(json.loads(row['args'])['_offset'], 12)
        runtime.try_acquire.return_value = (None, 'Low space')
        clean = self.hub.store.enqueue('cleanup', 'cleanup')
        self.hub.jobs.cleanup = Mock(return_value='Freed unused mixes')
        self.assertTrue(self.hub.jobs.run_one())
        with self.hub.store.connect() as db:
            self.assertEqual(db.execute('SELECT state FROM jobs WHERE id=?', (clean,)).fetchone()[0], 'ready')

    def test_request_limits_and_cross_origin(self):
        self.assertEqual(self.client.post('/hub/api/rooms', headers={**self.headers, 'Origin': 'http://evil.test'}, json={}).status_code, 403)
        self.assertEqual(self.client.post('/hub/api/rooms', headers=self.headers, content=b'x' * 262145).status_code, 413)
        # Chunked uploads must have the same bound, even without Content-Length.
        self.assertEqual(self.client.post('/hub/api/rooms', headers=self.headers, content=iter([b'x' * 150000, b'x' * 150000])).status_code, 413)

    def test_settings_validation(self):
        for value in [{'nightlyStart': 7, 'nightlyEnd': 6}, {'cacheGB': True}, {'timezone': '../../bad'}, {'radioEnabled': 1}, {'owner': OTHER}, {'radioProgram': 'missing'}]:
            self.assertEqual(self.api('PUT', '/settings', value).status_code, 400, value)
        self.assertEqual(self.api('PUT', '/settings', {'cacheGB': 10}).json()['cacheGB'], 10)

    def test_pair_code_single_use_and_rate_limit(self):
        room = self.room()
        paired = self.api('POST', '/pair', {'code': room['code']}, {})
        self.assertEqual(paired.status_code, 200)
        self.assertEqual(self.api('POST', '/pair', {'code': room['code']}, {}).status_code, 404)
        for _ in range(4):
            self.api('POST', '/pair', {'code': '000000'}, {})
        self.assertEqual(self.api('POST', '/pair', {'code': '000000'}, {}).status_code, 429)

    def test_guest_cannot_control_screen_cannot_admin(self):
        room = self.room()
        self.assertEqual(self.api('POST', '/room/command', {'action': 'pause', 'revision': 0}, self.role(room, 'guest')).status_code, 403)
        self.assertEqual(self.api('GET', '/settings', headers=self.role(room, 'screen')).status_code, 401)
        self.assertEqual(self.api('DELETE', '/rooms/' + room['id'], headers={**self.headers, 'X-Jellyfin-Token': 'other'}).status_code, 403)
        self.api('DELETE', '/rooms/' + room['id'])
        self.assertEqual(self.api('GET', '/room/state', headers=self.role(room, 'screen')).status_code, 404)

    def test_room_preparation_preserves_requests_and_report(self):
        room = self.room()
        self.command(room, 'select', song=SONG)
        def worker(*args, **kwargs):
            with self.hub.store.connect() as db:
                state = json.loads(db.execute('SELECT state FROM rooms WHERE id=?', (room['id'],)).fetchone()[0])
                state.update(queue=[SECOND], requests=[{'song': SECOND, 'guest': 'Guest', 'requester': 'private'}], positionMs=1200)
                db.execute('UPDATE rooms SET state=? WHERE id=?', (json.dumps(state), room['id']))
            return {'state': 'processing'}
        self.hub.karaoke.side_effect = worker
        self.hub.prepare_room(room['id'])
        state = self.api('GET', '/room/state', headers=self.role(room, 'screen')).json()
        self.assertEqual(state['queue'], [SECOND])
        self.assertEqual(state['positionMs'], 1200)  # No clock advancement while preparing.
        self.assertEqual(state['requests'][0]['title'], 'Second')
        self.assertNotIn('requester', state['requests'][0])

    def test_room_commands_reject_stale_and_preserve_seek(self):
        room = self.room()
        self.assertEqual(self.command(room, 'select', song=SONG).status_code, 200)
        self.assertEqual(self.command(room, 'pause').status_code, 409)
        self.assertEqual(self.command(room, 'seek', 1, positionMs=20000).status_code, 200)
        self.assertEqual(self.command(room, 'guide', 2, guide=25).status_code, 200)
        state = self.api('GET', '/room/state', headers=self.role(room, 'screen')).json()
        self.assertEqual(state['positionMs'], 20000)
        self.assertEqual(self.api('POST', '/room/report', {'revision': 1, 'positionMs': 0}, self.role(room, 'screen')).json(), {'accepted': False})
        self.assertEqual(self.command(room, 'guide', 3, guide=30).status_code, 400)

    def test_guest_requests_ready_only_and_limits(self):
        room = self.room()
        self.assertEqual(self.api('POST', '/room/request', {'song': SONG}, self.role(room, 'guest')).status_code, 409)
        self.hub.karaoke.return_value = {'state': 'ready', 'revision': 'f' * 64}
        self.assertEqual(self.api('POST', '/room/request', {'song': SONG, 'guest': '<script>'}, self.role(room, 'guest')).status_code, 200)
        self.assertEqual(self.api('POST', '/room/request', {'song': SONG}, self.role(room, 'guest')).status_code, 409)
        self.hub.karaoke.return_value = {'state': 'processing'}
        self.command(room, 'next')
        state = self.api('GET', '/room/state', headers=self.role(room, 'screen')).json()
        self.assertEqual(state['song']['id'], SONG)
        self.assertFalse(state['queue'])

    def test_a_request_starts_an_idle_tv_and_otherwise_waits_its_turn(self):
        room = self.room()
        self.hub.karaoke.return_value = {'state': 'ready', 'revision': 'f' * 64}
        self.hub.prepare_room = Mock()
        guest = self.role(room, 'guest')
        def state():
            value = json.loads(self.hub.room(room['id'])['state'])
            return value['song']['id'], value['queue'], value['playing'], value['commandRev']
        self.assertTrue(self.api('POST', '/room/request', {'song': SONG}, guest).json()['started'])
        self.assertEqual(state(), (SONG, [], True, 1))
        # A song is on, or paused by the host part way: the next request waits.
        self.assertFalse(self.api('POST', '/room/request', {'song': SECOND}, guest).json()['started'])
        self.assertEqual(self.command(room, 'pause', 1).status_code, 200)
        self.assertEqual(self.command(room, 'remove', 2, song=SECOND).status_code, 200)
        self.assertFalse(self.api('POST', '/room/request', {'song': SECOND}, guest).json()['started'])
        self.assertEqual(state(), (SONG, [SECOND], False, 3))
        self.assertEqual(self.command(room, 'remove', 3, song=SECOND).status_code, 200)
        # The song ran to its end with nothing queued: the TV is idle again, and a request starts.
        version = 'e' * 64
        with self.hub.store.connect() as db:
            value = json.loads(db.execute('SELECT state FROM rooms WHERE id=?', (room['id'],)).fetchone()[0])
            value.update(revision=version, mediaReady=True, playing=True)
            db.execute('UPDATE rooms SET state=? WHERE id=?', (json.dumps(value), room['id']))
        ended = {'revision': 4, 'mediaKey': version + ':0', 'ended': True}
        self.api('POST', '/room/report', ended, self.role(room, 'screen'))
        self.assertEqual(state(), (SONG, [], False, 5))
        # Even for the song that just ended; while it's on again, it can't be asked for twice.
        self.assertTrue(self.api('POST', '/room/request', {'song': SONG}, guest).json()['started'])
        self.assertEqual(state(), (SONG, [], True, 6))
        self.assertEqual(self.api('POST', '/room/request', {'song': SONG}, guest).status_code, 409)

    def test_a_host_command_waits_for_a_request_to_start_the_tv(self):
        room = self.room()
        self.hub.karaoke.return_value = {'state': 'ready'}
        self.hub.prepare_room = Mock()
        locks, host = self.hub.lock_for, []
        class Watched:
            """The room lock, but the host sends a command the first time a request lets go of it."""
            def __init__(self, lock):
                self.lock = lock
            def __enter__(self):
                return self.lock.__enter__()
            def __exit__(self, *error):
                self.lock.__exit__(*error)
                if not host:
                    host.append(threading.Thread(target=change))
                    host[0].start()
                    host[0].join(1)
        def change():
            try:
                host.append(self.hub.room_command(self.hub.room(room['id']), {'action': 'remove', 'revision': 0, 'song': SECOND}))
            except HTTPException as error:
                host.append(error.status_code)
        self.hub.lock_for = lambda value: Watched(locks(value))
        self.assertTrue(self.api('POST', '/room/request', {'song': SONG}, self.role(room, 'guest')).json()['started'])
        host[0].join(5)
        state = json.loads(self.hub.room(room['id'])['state'])
        self.assertEqual((state['song']['id'], state['queue'], state['commandRev']), (SONG, [], 1))
        # The host's command was made against the room before the song started, so it's refused as out of date.
        self.assertEqual(host[1], 409)

    def test_a_request_that_could_not_start_starts_when_jellyfin_is_back(self):
        room = self.room()
        self.hub.karaoke.return_value = {'state': 'ready'}
        self.hub.prepare_room = Mock()
        found = self.jf.item.side_effect
        lookups = []
        def away_second_time(owner, value):
            # The request's own check finds the song; Jellyfin is gone when the TV is started.
            lookups.append(value)
            if len(lookups) == 2:
                raise HTTPException(503, 'Jellyfin is unavailable')
            return found(owner, value)
        self.jf.item.side_effect = away_second_time
        response = self.api('POST', '/room/request', {'song': SONG}, self.role(room, 'guest'))
        self.assertEqual(response.json(), {'accepted': True, 'started': False})
        state = json.loads(self.hub.room(room['id'])['state'])
        self.assertEqual((state['song'], state['queue']), (None, [SONG]))
        self.hub.refresh_rooms()
        state = json.loads(self.hub.room(room['id'])['state'])
        self.assertEqual((state['song']['id'], state['queue'], state['playing']), (SONG, [], True))
        # A TV the host paused part way keeps its queue for "Next song".
        self.assertEqual(self.command(room, 'pause', 1).status_code, 200)
        self.assertEqual(self.api('POST', '/room/request', {'song': SECOND}, self.role(room, 'guest')).json()['started'], False)
        self.hub.refresh_rooms()
        state = json.loads(self.hub.room(room['id'])['state'])
        self.assertEqual((state['song']['id'], state['queue']), (SONG, [SECOND]))

    def test_a_requested_song_gone_from_the_library_does_not_hold_up_the_next(self):
        room = self.room()
        self.hub.karaoke.return_value = {'state': 'ready'}
        self.hub.prepare_room = Mock()
        found, lookups = self.jf.item.side_effect, []
        def removed_after_request(owner, value):
            # The first song is found when it's requested, then removed from the library.
            lookups.append(value)
            if value == SONG and len(lookups) > 1:
                raise HTTPException(404, 'This song is not available to your account')
            return found(owner, value)
        self.jf.item.side_effect = removed_after_request
        guest = self.role(room, 'guest')
        self.assertFalse(self.api('POST', '/room/request', {'song': SONG}, guest).json()['started'])
        state = json.loads(self.hub.room(room['id'])['state'])
        self.assertEqual((state['song'], state['queue'], state['requests']), (None, [], []))
        self.assertTrue(self.api('POST', '/room/request', {'song': SECOND}, guest).json()['started'])
        # Queued behind a song that's gone, "Next song" passes over it.
        self.assertEqual(self.command(room, 'pause', 2).status_code, 200)
        with self.hub.store.connect() as db:
            value = json.loads(db.execute('SELECT state FROM rooms WHERE id=?', (room['id'],)).fetchone()[0])
            value.update(queue=[SONG, SECOND])
            db.execute('UPDATE rooms SET state=? WHERE id=?', (json.dumps(value), room['id']))
        self.assertEqual(self.command(room, 'next', 3).status_code, 200)
        state = json.loads(self.hub.room(room['id'])['state'])
        self.assertEqual((state['song']['id'], state['queue'], state['playing']), (SECOND, [], True))

    def party(self):
        response = self.api('POST', '/parties', {})
        self.assertEqual(response.status_code, 200, response.text)
        return response.json()

    def guest(self, party, path, body=None, guest='guest-one-1234', method=None):
        headers = {'Authorization': 'Bearer ' + party['token'], 'X-Party-Guest': guest}
        return self.client.request(method or ('POST' if body is not None else 'GET'), '/hub/api/party/' + path,
            content=None if body is None else json.dumps(body), headers=headers)

    def phone(self, party, answer, count=1):
        """The host's phone, answering [count] guest requests the way the app does."""
        seen = []
        def run():
            while len(seen) < count:
                for message in self.hub.parties.take(OWNER, party['id'], 5):
                    seen.append(message)
                    self.hub.parties.answer(OWNER, party['id'], [{'id': message['id'], **answer(message)}])
        thread = threading.Thread(target=run, daemon=True)
        thread.start()
        return seen, thread

    def test_a_party_carries_guest_requests_to_the_phone_and_its_answers_back(self):
        party = self.party()
        self.assertIsNone(party['publicUrl'])
        self.assertEqual(self.client.get('/hub/party/').status_code, 200)
        seen, thread = self.phone(party, lambda message: {'status': 200, 'body': json.dumps({'ok': True, 'echo': message['body']})}, 4)
        added = self.guest(party, 'add', {'id': SONG, 'guest': 'Sam'})
        self.assertEqual(added.status_code, 200, added.text)
        self.assertEqual(added.json(), {'ok': True, 'echo': json.dumps({'id': SONG, 'guest': 'Sam'})})
        self.assertEqual(self.guest(party, 'search?q=queen&other=x').status_code, 200)
        self.guest(party, 'state')
        self.guest(party, 'state', guest='guest-two-1234')
        thread.join(5)
        # The phone hears how long each guest still waits, so it leaves alone what they were told failed.
        self.assertTrue(all(0 < m['budget'] <= self.hub.parties.answer_seconds for m in seen))
        self.assertTrue(all('deadline' not in m for m in seen))
        self.assertEqual([(m['method'], m['path'], m['query']) for m in seen],
            [('POST', '/api/add', {}), ('GET', '/api/search', {'q': 'queen'}), ('GET', '/api/state', {}), ('GET', '/api/state', {})])
        # Each browser is its own guest to the phone, so per-guest limits still hold.
        guests = [message['guest'] for message in seen]
        self.assertTrue(all(value.startswith('web:') for value in guests))
        self.assertEqual(len(set(guests[:3])), 1)
        self.assertNotEqual(guests[2], guests[3])
        # Only the party's own requests, from a guest with a link to it.
        self.assertEqual(self.guest(party, 'rooms').status_code, 404)
        self.assertEqual(self.guest(party, 'state', guest='x').status_code, 400)
        self.assertEqual(self.client.get('/hub/api/party/state', headers={'X-Party-Guest': 'guest-one-1234'}).status_code, 401)
        room = self.room()
        self.assertEqual(self.guest({'token': room['guest']}, 'state').status_code, 401)
        self.assertEqual(self.guest(party, 'add', 'x' * 5000).status_code, 413)

    def test_party_guests_hear_when_the_phone_is_away_or_the_party_ended(self):
        self.hub.parties.answer_seconds = 0.2
        party = self.party()
        # The phone took too long: the request is withdrawn, so it isn't acted on after the guest was told it failed.
        unanswered = self.guest(party, 'add', {'id': SONG})
        self.assertEqual(unanswered.status_code, 503)
        self.assertIn("didn't answer", unanswered.json()['detail'])
        self.assertEqual(self.api('GET', f"/parties/{party['id']}/inbox?wait=0").json(), [])
        # Taken by the phone but not answered in time, an addition may still go through, so the guest checks first.
        taker = threading.Thread(target=lambda: self.hub.parties.take(OWNER, party['id'], 5), daemon=True)
        taker.start()
        late = self.guest(party, 'add', {'id': SONG})
        taker.join(5)
        self.assertEqual(late.status_code, 503)
        self.assertIn('Check Up next', late.json()['detail'])
        self.hub.parties.parties[party['id']]['seen'] -= 100
        self.assertIn("isn't connected", self.guest(party, 'state').json()['detail'])
        # Answers to requests the hub isn't waiting for are ignored.
        self.assertEqual(self.api('POST', f"/parties/{party['id']}/answers", {'answers': [{'id': 99, 'status': 200, 'body': '{}'}]}).status_code, 200)
        other = {**self.headers, 'X-Jellyfin-Token': 'other'}
        self.assertEqual(self.api('POST', '/parties', {'id': party['id']}, other).status_code, 403)
        self.assertEqual(self.api('GET', f"/parties/{party['id']}/inbox?wait=0", headers=other).status_code, 404)
        self.api('DELETE', '/parties/' + party['id'], headers=other)
        self.assertIn(party['id'], self.hub.parties.parties)
        self.assertEqual(self.api('DELETE', '/parties/' + party['id']).status_code, 200)
        self.assertEqual(self.guest(party, 'state').status_code, 410)
        self.assertEqual(self.api('GET', f"/parties/{party['id']}/inbox?wait=0").status_code, 404)
        # Opened again under the same id, as after a restart, the links guests have work again.
        self.assertEqual(self.api('POST', '/parties', {'id': party['id']}).json()['id'], party['id'])
        self.phone(party, lambda message: {'status': 200, 'body': '{"ok":true}'})
        self.assertEqual(self.guest(party, 'state').json(), {'ok': True})
        self.assertEqual(self.api('POST', '/parties', {'id': 'bad'}).status_code, 400)

    def test_party_waits_are_bounded_so_the_hub_keeps_answering(self):
        party = self.party()
        # The phone reconnected while its old poll hung on: the old one gives way, and nothing is lost to it.
        old = []
        thread = threading.Thread(target=lambda: old.append(self.hub.parties.take(OWNER, party['id'], 10)), daemon=True)
        thread.start()
        time.sleep(0.2)
        seen, answering = self.phone(party, lambda message: {'status': 200, 'body': '{"ok":true}'})
        thread.join(2)
        self.assertEqual(old, [[]])
        self.assertEqual(self.guest(party, 'state').json(), {'ok': True})
        answering.join(5)
        self.assertEqual(len(seen), 1)
        # Too many guests waiting across the hub are told to try again at once.
        self.hub.parties.waiting = self.hub.parties.most_waiting_total
        busy = self.guest(party, 'state')
        self.assertEqual(busy.status_code, 503)
        self.assertIn('busy', busy.json()['detail'])
        self.hub.parties.waiting = 0
        # A server full of running parties turns a new one away, and one whose phone went away makes room.
        self.hub.parties.most_parties = 1
        self.assertEqual(self.api('POST', '/parties', {}).status_code, 503)
        self.assertIn(party['id'], self.hub.parties.parties)
        self.hub.parties.parties[party['id']]['seen'] -= 100
        self.assertEqual(self.api('POST', '/parties', {}).status_code, 200)
        self.assertNotIn(party['id'], self.hub.parties.parties)

    def test_a_party_opened_again_numbers_requests_afresh(self):
        party = self.party()
        first = self.hub.parties.parties[party['id']]['next']
        self.hub.parties.close(OWNER, party['id'])
        self.hub.parties.open(OWNER, party['id'])
        self.assertNotEqual(self.hub.parties.parties[party['id']]['next'], first)

    def test_a_party_ending_while_a_guest_waits_tells_them(self):
        party = self.party()
        threading.Timer(0.3, lambda: self.hub.parties.close(OWNER, party['id'])).start()
        self.assertEqual(self.guest(party, 'state').status_code, 410)

    def test_guest_links_use_the_public_address_when_the_server_has_one(self):
        room = self.room()
        self.assertIsNone(self.api('GET', '/room/state', headers=self.role(room, 'screen')).json()['publicUrl'])
        with patch.dict(os.environ, {'PUBLIC_URL': 'https://music.example.com/finamp-analyzer/'}):
            self.assertEqual(self.api('GET', '/room/state', headers=self.role(room, 'screen')).json()['publicUrl'],
                'https://music.example.com/finamp-analyzer')
            self.assertNotIn('publicUrl', self.api('GET', '/room/state', headers=self.role(room, 'guest')).json())
            self.assertEqual(self.party()['publicUrl'], 'https://music.example.com/finamp-analyzer')
            # The TV's QR code for that address is allowed, and others still aren't.
            url = 'https://music.example.com/finamp-analyzer/hub/guest/#' + room['guest']
            qr = self.client.get('/hub/api/room/qr', params={'ticket': room['guest'], 'url': url})
            self.assertEqual(qr.status_code, 200, qr.text)
            bad = url.replace('music.example.com', 'evil.test')
            self.assertEqual(self.client.get('/hub/api/room/qr', params={'ticket': room['guest'], 'url': bad}).status_code, 400)

    def test_guests_are_shown_only_prepared_songs(self):
        room = self.room()
        def worker(method, path, **kwargs):
            if path == '/karaoke/status':
                return {value: {'state': 'ready' if value == SECOND else 'missing'} for value in kwargs['json']['ids']}
            if path == '/karaoke':
                return {'items': [{'id': SECOND}]}
            return {'state': 'missing'}
        self.hub.karaoke.side_effect = worker
        for query in ['', 'o']:
            found = self.api('GET', '/room/search?q=' + query, headers=self.role(room, 'guest')).json()
            self.assertEqual([song['id'] for song in found], [SECOND], query)
        # The host can still choose any song; it's prepared when chosen.
        found = self.api('GET', '/room/search?q=o', headers=self.role(room, 'control')).json()
        self.assertEqual([song['id'] for song in found], [SONG, SECOND])

    def test_sync_owner_isolation_and_history_idempotence(self):
        event = {'id': 'play1', 'song': SONG, 'startedMs': 1, 'playedMs': 5000}
        self.api('POST', '/sync/history', {'items': [event]})
        self.api('POST', '/sync/history', {'items': [{**event, 'playedMs': 1}]})
        own = self.api('GET', '/sync').json()['history']
        self.assertEqual(len(own), 1)
        self.assertEqual(own[0]['playedMs'], 5000)
        self.assertEqual(self.api('GET', '/sync', headers={**self.headers, 'X-Jellyfin-Token': 'other'}).json()['history'], [])

    def test_sync_queue_transfer_is_explicit(self):
        body = {'ids': [SONG, SECOND], 'index': 1, 'positionMs': 12500, 'playing': True, 'device': 'phone1'}
        self.assertEqual(self.api('PUT', '/sync/queue', body).status_code, 200)
        self.assertEqual(self.api('PUT', '/sync/queue', {**body, 'device': 'phone2'}).status_code, 409)
        self.assertEqual(self.api('PUT', '/sync/queue', {**body, 'device': 'phone2', 'claim': True}).status_code, 200)
        self.assertEqual(self.api('PUT', '/sync/queue', body).status_code, 409)
        self.assertEqual(self.api('GET', '/sync').json()['queue']['positionMs'], 12500)

    def test_sync_poll_unchanged_configuration_is_short(self):
        station = {'id': 'one', 'name': 'One', 'seed': {'id': SONG}, 'mode': 'similar', 'preferences': {}}
        tag = self.api('PATCH', '/sync', {'upsertStations': [station]}).json()['configTag']
        self.api('POST', '/sync/history', {'items': [{'id': 'play1', 'song': SONG, 'startedMs': 1, 'playedMs': 5}]})
        self.assertEqual(self.api('GET', f'/sync?unless={tag}').json(), {'unchanged': True, 'configTag': tag})
        # History and the queue are not part of it; the full answer still has them.
        full = self.api('GET', '/sync').json()
        self.assertEqual(full['configTag'], tag)
        self.assertEqual(len(full['history']), 1)
        # Any change to the configuration, from another device too, gives the full answer again.
        for change in ({'upsertStations': [{**station, 'name': 'Two'}]}, {'preferences': {'discovery': 50}},
                {'guard': True}, {'includeWarnings': True}, {'deleteStations': ['one']}):
            changed = self.api('PATCH', '/sync', change).json()['configTag']
            self.assertNotEqual(changed, tag)
            answer = self.api('GET', f'/sync?unless={tag}').json()
            self.assertNotIn('unchanged', answer)
            self.assertEqual(answer['configTag'], changed)
            tag = changed
        # Another account's tag says nothing about this one.
        other = self.api('GET', '/sync', headers={**self.headers, 'X-Jellyfin-Token': 'other'}).json()['configTag']
        self.assertNotIn('unchanged', self.api('GET', f'/sync?unless={tag}',
            headers={**self.headers, 'X-Jellyfin-Token': 'other'}).json())
        self.assertNotEqual(other, tag)

    def test_sync_merges_station_changes_without_losing_other_device(self):
        station = {'id': 'one', 'name': 'One', 'seed': {'id': SONG}, 'mode': 'similar', 'preferences': {}}
        self.api('PATCH', '/sync', {'upsertStations': [station]})
        self.api('PATCH', '/sync', {'upsertStations': [{**station, 'id': 'two'}]})
        result = self.api('PATCH', '/sync', {'deleteStations': ['one']}).json()
        self.assertEqual([item['id'] for item in result['stations']], ['two'])
        self.assertEqual(self.api('PATCH', '/sync', {'preferences': {'discovery': 101}}).status_code, 400)

    def test_radio_schedule_wrap_and_artist_spacing(self):
        settings = self.hub.store.settings()
        for hour, expected in [(0, 'evening'), (7, 'morning'), (12, 'discovery'), (23, 'evening')]:
            self.assertEqual(scheduled_program(settings, datetime(2026, 10, 19, hour))['id'], expected)
        self.hub.radio.last_artist = 'one'
        for _ in range(30):
            self.assertEqual(self.hub.radio.choose(self.items, {'discovery': 100})['Id'], SECOND)
        self.assertIsNone(self.hub.radio.choose([], {}))

    def test_radio_slow_listener_bounded(self):
        self.hub.store.save_settings({'radioEnabled': True})
        generators = [self.hub.radio.listen() for _ in range(8)]
        with self.assertRaises(HTTPException): self.hub.radio.listen()
        encoder = Mock(stdout=io.BytesIO(b'x' * (4096 * 70)))
        self.hub.radio.pump(encoder)
        self.assertEqual(len(self.hub.radio.listeners), 0)
        for stream in generators: self.assertEqual(list(stream), [])

    def test_radio_loudness_requires_current_source_revision(self):
        stat = self.source.stat()
        signature = hashlib.sha256(f'1:{self.source}:{stat.st_size}:{stat.st_mtime_ns}'.encode()).hexdigest()
        with sqlite3.connect(self.root / 'loudness.db') as db:
            db.execute('CREATE TABLE tracks(id TEXT,lufs REAL,true_peak REAL,signature TEXT,version INTEGER,error TEXT)')
            db.execute('INSERT INTO tracks VALUES(?,?,?,?,?,NULL)', (SONG, -20, -8, signature, 1))
        self.assertEqual(self.hub.radio.gain(self.items[0], self.source), 6)
        self.source.write_bytes(b'new music')
        self.assertEqual(self.hub.radio.gain(self.items[0], self.source), 0)

    def test_schedule_deduplicates_daily_and_quiet_window(self):
        self.hub.jobs.schedule(datetime(2026, 10, 19, 3, 30))
        self.hub.jobs.schedule(datetime(2026, 10, 19, 3, 35))
        with self.hub.store.connect() as db:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM jobs').fetchone()[0], 4)
        self.hub.jobs.schedule(datetime(2026, 10, 20, 12))
        with self.hub.store.connect() as db:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM jobs').fetchone()[0], 5)

    def test_nightly_skips_existing_and_caps_new_jobs(self):
        self.hub.store.save_settings({'nightlySongs': [SONG, SECOND], 'nightlyLimit': 1, 'nightlyFavorites': False})
        self.hub.karaoke.side_effect = lambda method, path, **kw: {
            SONG: {'state': 'ready'}, SECOND: {'state': 'missing'}} if path == '/karaoke/status' else {'state': 'queued'}
        self.assertEqual(self.hub.jobs.nightly({}), 'Queued 1 songs for overnight preparation')
        self.assertEqual([call.args[1] for call in self.hub.karaoke.call_args_list], ['/karaoke/status', '/karaoke/' + SECOND])
        self.jf.item.assert_not_called()
        self.jf.items.assert_called_once_with(OWNER, ids=[SONG, SECOND], limit=200)

    def test_nightly_checks_large_lists_in_account_scoped_batches(self):
        songs = [f'{i:032x}' for i in range(405)]
        hidden = songs[201]
        self.hub.store.save_settings({'owner': OTHER, 'nightlySongs': songs,
            'nightlyFavorites': False, 'nightlyLimit': 1})
        self.jf.items.side_effect = lambda owner, ids, **kw: [{'Id': value} for value in ids if value != hidden]
        def worker(method, path, **kw):
            if path == '/karaoke/status':
                return {value: {'state': 'missing' if value == songs[-1] else 'ready'} for value in kw['json']['ids']}
            return {'state': 'queued'}
        self.hub.karaoke.side_effect = worker
        self.assertIn('Queued 1 songs', self.hub.jobs.nightly({}))
        self.assertEqual([len(call.kwargs['ids']) for call in self.jf.items.call_args_list], [200, 200, 5])
        self.assertTrue(all(call.args[0] == OTHER for call in self.jf.items.call_args_list))
        self.jf.item.assert_not_called()
        for call in self.hub.karaoke.call_args_list:
            if call.args[1] == '/karaoke/status':
                self.assertNotIn(hidden, call.kwargs['json']['ids'])

    def test_health_catches_decode_warnings_even_when_exit_zero(self):
        def process(*args, **kwargs):
            kwargs['stderr'].write(b'MP3 decoder warning\n')
            return Mock(wait=Mock(return_value=0))
        self.hub.karaoke_busy = lambda: False
        with patch('hub_jobs.subprocess.Popen', side_effect=process):
            self.hub.jobs.health({'limit': 1})
        with self.hub.store.connect() as db:
            row = db.execute('SELECT * FROM health').fetchone()
        self.assertEqual(row['state'], 'warning')
        self.assertEqual(row['warnings'], 1)
        self.api('PATCH', '/sync', {'guard': True, 'includeWarnings': True})
        self.assertEqual(self.api('GET', '/blocked').json()['ids'], [SONG])
        self.source.write_bytes(b'changed')
        self.assertEqual(self.api('GET', '/blocked').json()['ids'], [])

    def test_paths_cannot_escape_music_or_cache(self):
        jf = Jellyfin('', '', [('/media', str(self.music))], '')
        self.assertEqual(jf.path({'Path': '/media/song.wav'}), self.source)
        for path in ['/media/../outside', '/medias/song.wav', '/etc/passwd']:
            with self.assertRaises(HTTPException): jf.path({'Path': path})
        for version in ['../outside', 'e' * 63, 'E' * 64]:
            with self.assertRaises(HTTPException): self.hub.karaoke_file(version, 0)

    def test_cleanup_preserves_selected_favourites_rooms_and_originals(self):
        root = self.root / 'karaoke'
        root.mkdir()
        self.hub.store.save_settings({'nightlySongs': [SONG], 'nightlyFavorites': False, 'cacheDays': 1})
        with sqlite3.connect(root / 'jobs.db') as db:
            db.execute('CREATE TABLE jobs(id TEXT,revision TEXT,state TEXT,queued REAL)')
            for value, version in [(SONG, 'e' * 64), (SECOND, 'f' * 64)]:
                directory = root / version
                directory.mkdir()
                (directory / 'mix-0.flac').write_bytes(b'cache')
                marker = directory / '.last-used'
                marker.touch()
                os.utime(marker, (1, 1))
                db.execute('INSERT INTO jobs VALUES(?,?,?,?)', (value, version, 'ready', 1))
        self.hub.jobs.cleanup({})
        deleted = [call for call in self.hub.karaoke.call_args_list if call.args[0] == 'DELETE']
        self.assertEqual(len(deleted), 1)
        self.assertEqual(deleted[0].args[1], '/karaoke/' + SECOND)
        self.assertEqual(self.source.read_bytes(), b'music')
        self.assertTrue((root / ('e' * 64)).is_dir())
        self.assertEqual(deleted[0].kwargs['params'], {'revision': 'f' * 64})

    def test_cleanup_expires_drumless_mixes_by_their_part(self):
        root = self.root / 'karaoke'
        root.mkdir()
        self.hub.store.save_settings({'nightlySongs': [], 'nightlyFavorites': False, 'cacheDays': 1})
        with sqlite3.connect(root / 'jobs.db') as db:
            db.execute('CREATE TABLE jobs(id TEXT,part TEXT,revision TEXT,state TEXT,progress REAL,message TEXT,'
                       'queued REAL,seconds REAL)')
            # A removed mashup, used longest ago, left by a karaoke server that hasn't been updated yet.
            for song, part, version, used in [(f'{SECOND}+{SECOND}', 'mashup', 'd' * 64, 0),
                                              (SECOND, 'vocals', 'e' * 64, 1), (SECOND, 'drums', 'f' * 64, 1)]:
                directory = root / version
                directory.mkdir()
                (directory / 'mix-0.flac').write_bytes(b'cache')
                marker = directory / '.last-used'
                marker.touch()
                os.utime(marker, (used, used))
                db.execute('INSERT INTO jobs VALUES(?,?,?,?,?,?,?,?)', (song, part, version, 'ready', 1, '', 1, 1))
        self.hub.jobs.cleanup({})
        deleted = sorted(call.kwargs['params']['revision'] + ' ' + call.kwargs['params'].get('part', '-')
                         for call in self.hub.karaoke.call_args_list if call.args[0] == 'DELETE')
        self.assertEqual(deleted, ['e' * 64 + ' -', 'f' * 64 + ' drums'])

    def test_backup_round_trip_and_corruption_rejected(self):
        native = self.root / 'native'
        native.mkdir()
        path = native / 'jellyfin-backup-test.zip'
        with zipfile.ZipFile(path, 'w') as archive: archive.writestr('config.xml', '<config/>')
        self.jf.json.return_value = {'Path': '/config/backups/' + path.name}
        with patch.dict(os.environ, {'JELLYFIN_BACKUP_DIR': str(native)}):
            self.hub.jobs.backup({'reason': 'test'})
        with self.hub.store.connect() as db: backup = db.execute('SELECT * FROM backups').fetchone()
        self.assertIsNotNone(backup['verified'])
        target = self.hub.store.root / 'backups' / backup['name']
        Jobs.verify_archive(target)
        target.write_bytes(b'corrupted')
        with self.assertRaises(tarfile.ReadError): Jobs.verify_archive(target)

    def test_restore_rejects_path_traversal_and_links(self):
        for name, symlink in [('../escape', False), ('files/link', True)]:
            target = self.root / 'malicious.tar.gz'
            with tarfile.open(target, 'w:gz') as archive:
                member = tarfile.TarInfo(name)
                if symlink: member.type, member.linkname = tarfile.SYMTYPE, '/etc/passwd'
                archive.addfile(member)
            with self.assertRaises(HTTPException): Jobs.verify_archive(target)

    def test_on_demand_lyrics_require_artist_title_duration_and_sync(self):
        self.jf.lyrics.return_value = []
        def match(value, **metadata):
            return {'Id': value, 'Lyrics': {'Metadata': {'Artist': 'One', 'Title': 'First',
                'Length': 300000000, 'IsSynced': True, **metadata}}}
        self.jf.json.return_value = [match('wrong-artist', Artist='Other'), match('wrong-title', Title='Live'),
            match('wrong-length', Length=500000000), match('not-timed', IsSynced=False),
            match('near', Length=330000000), match('best', Length=310000000)]
        self.assertEqual(self.hub.jobs.lyrics({'song': SONG, 'owner': OWNER}), 'Timed lyrics downloaded for the TV')
        self.assertEqual(self.jf.request.call_args.args, ('POST', f'/Audio/{SONG}/RemoteSearch/Lyrics/best'))

    def test_existing_timed_lyrics_are_preserved(self):
        self.hub.jobs.lyrics({'song': SONG, 'owner': OWNER})
        self.jf.json.assert_not_called()
        self.jf.request.assert_not_called()

    def test_lyrics_no_match_is_a_completed_job(self):
        self.jf.lyrics.return_value = []
        self.jf.json.return_value = []
        self.assertIn('No timed lyrics', self.hub.jobs.lyrics({'song': SONG, 'owner': OWNER}))
        self.jf.request.assert_not_called()

    def test_old_tv_audio_cannot_report_position_for_a_new_mix(self):
        room = self.room()
        version = 'e' * 64
        with self.hub.store.connect() as db:
            state = json.loads(db.execute('SELECT state FROM rooms WHERE id=?', (room['id'],)).fetchone()[0])
            state.update(song=Jellyfin.brief(self.items[0]), revision=version, mediaReady=True)
            db.execute('UPDATE rooms SET state=? WHERE id=?', (json.dumps(state), room['id']))
        headers = self.role(room, 'screen')
        good = {'revision': 0, 'mediaKey': version + ':0', 'positionMs': 4500}
        self.assertTrue(self.api('POST', '/room/report', good, headers).json()['accepted'])
        self.assertFalse(self.api('POST', '/room/report', {**good, 'mediaKey': 'old:25', 'positionMs': 20000}, headers).json()['accepted'])
        self.assertEqual(json.loads(self.hub.room(room['id'])['state'])['positionMs'], 4500)
        self.command(room, 'select', song=SECOND)
        self.assertFalse(self.api('POST', '/room/report', {**good, 'revision': 1, 'ended': True}, headers).json()['accepted'])

    def test_announcement_upload_enqueues_after_releasing_hub_lock(self):
        store = self.hub.store
        enqueue = store.enqueue
        body = b'RIFF' + b'\0' * 4 + b'WAVE' + b'\0' * 32
        version = hashlib.sha256(body).hexdigest()
        def checked_enqueue(*args):
            self.assertFalse(self.hub.lock._is_owned(), 'Enqueue outside hub.lock')
            return enqueue(*args)
        with patch.object(store, 'enqueue', side_effect=checked_enqueue) as queued:
            response = self.client.post('/hub/api/radio/announcement', content=body,
                headers={**self.headers, 'Content-Type': 'audio/wav', 'X-Program': 'morning'})
        self.assertEqual(response.status_code, 200, response.text)
        queued.assert_called_once_with('announcement', f'morning:{version}', {'program': 'morning', 'version': version})
        self.assertEqual((store.root / 'announcements' / 'morning.wav').read_bytes(), body)
        with store.connect() as db:
            row = db.execute('SELECT state,args FROM jobs WHERE id=?', (response.json()['id'],)).fetchone()
        self.assertEqual(row['state'], 'queued')
        self.assertEqual(json.loads(row['args']), {'program': 'morning', 'version': version})

    def test_deleted_or_replaced_introduction_does_not_reappear(self):
        directory = self.hub.store.root / 'announcements'
        directory.mkdir()
        source = directory / 'morning.wav'
        for removed in [True, False]:
            with self.subTest(removed=removed):
                source.write_bytes(b'old')
                def finish(*args, **kwargs):
                    (directory / '.morning.partial.mp3').write_bytes(b'encoded')
                    if removed: source.unlink()
                    else: source.write_bytes(b'new')
                    return 0
                with patch('hub_jobs.subprocess.Popen', return_value=Mock(wait=finish, poll=Mock(return_value=0))):
                    result = self.hub.jobs.announcement({'program': 'morning', 'version': hashlib.sha256(b'old').hexdigest()})
                self.assertIn('removed or replaced', result)
                self.assertFalse((directory / 'morning.mp3').exists())

    def test_nightly_skips_unavailable_songs_and_keeps_going(self):
        missing = 'e' * 32
        self.hub.store.save_settings({'nightlySongs': [missing, SECOND], 'nightlyLimit': 3, 'nightlyFavorites': False})
        def item(owner, value):
            if value == missing:
                raise HTTPException(404, 'This song is not available to your account')
            return self.items[1]
        self.jf.item.side_effect = item
        self.assertIn('Queued 1 songs', self.hub.jobs.nightly({}))
        self.assertEqual([call.args[1] for call in self.hub.karaoke.call_args_list], ['/karaoke/status', '/karaoke/' + SECOND])
        self.assertEqual(self.hub.karaoke.call_args_list[0].kwargs, {'json': {'ids': [SECOND]}})
        # A worker that fails outright still fails the job, so it shows in the dashboard.
        def failing_worker(method, path, **kw):
            if path != '/karaoke/status':
                raise HTTPException(502, 'Worker failed')
            return {SECOND: {'state': 'missing'}}
        self.hub.karaoke.side_effect = failing_worker
        with self.assertRaises(HTTPException): self.hub.jobs.nightly({})

    def test_tv_audio_job_finishes_with_an_open_room_that_has_no_song(self):
        self.room()
        version = 'e' * 64
        self.hub.karaoke.return_value = {'state': 'ready', 'revision': version}
        self.hub.karaoke_file = Mock(return_value=self.source)
        media = self.hub.store.root / 'media'
        media.mkdir()
        (media / f'{version}-0.mp3').write_bytes(b'ready')
        self.assertEqual(self.hub.jobs.media({'song': SONG, 'guide': 0, 'revision': version}), 'Browser karaoke audio is ready')

    def test_radio_rests_without_listeners_and_wakes_for_one(self):
        self.assertTrue(self.hub.radio.idle(), 'nothing is broadcast before anyone listens')
        stream = self.hub.radio.listen()
        self.assertFalse(self.hub.radio.idle())
        self.assertTrue(self.hub.radio.wake.is_set())
        self.hub.store.save_settings({'radioEnabled': False})
        self.assertEqual(list(stream), [])
        self.assertFalse(self.hub.radio.idle(), 'keeps playing for a moment for a reconnecting phone')
        self.hub.radio.idle_since -= Radio.IDLE_SECONDS
        self.assertTrue(self.hub.radio.idle())

    def test_reverse_proxy_host_is_accepted_but_other_sites_are_not(self):
        proxied = {**self.headers, 'Origin': 'https://music.example.com', 'X-Forwarded-Host': 'music.example.com'}
        self.assertEqual(self.client.post('/hub/api/rooms', headers=proxied, json={}).status_code, 200)
        self.assertEqual(self.client.post('/hub/api/rooms', headers={**proxied, 'Origin': 'https://evil.test'}, json={}).status_code, 403)
        with patch.dict(os.environ, {'PUBLIC_URL': 'https://tv.example.com'}):
            self.assertEqual(self.client.post('/hub/api/rooms', headers={**self.headers, 'Origin': 'https://tv.example.com'}, json={}).status_code, 200)

    def test_pairing_is_limited_across_addresses(self):
        now = time.time()
        self.hub.pair_attempts = {f'10.0.0.{value}': (now, 5) for value in range(6)}
        self.assertEqual(self.api('POST', '/pair', {'code': '000000'}, {}).status_code, 429)

    def test_a_slow_room_does_not_hold_up_another(self):
        first, second = self.room(), self.room()
        entered, release = threading.Event(), threading.Event()
        def slow_item(owner, value):
            entered.set()
            release.wait(5)
            return self.items[0]
        self.jf.item.side_effect = slow_item
        worker = threading.Thread(target=self.command, args=(first, 'select'), kwargs={'song': SONG})
        worker.start()
        try:
            self.assertTrue(entered.wait(5))
            started = time.monotonic()
            self.assertEqual(self.command(second, 'pause').status_code, 200)
            self.assertLess(time.monotonic() - started, 2)
        finally:
            release.set()
            worker.join(5)

    def test_settings_cache_refreshes_and_save_is_immediate_and_isolated(self):
        store = self.hub.store
        store.settings()
        with patch.object(store, 'connect', wraps=store.connect) as connect:
            for _ in range(100):
                self.assertFalse(store.settings()['radioEnabled'])
            connect.assert_not_called()
        settings = store.settings()
        settings['radioPrograms'][0]['name'] = 'Changed'
        self.assertNotEqual(store.settings()['radioPrograms'][0]['name'], 'Changed')
        store.save_settings({'radioEnabled': True})
        self.assertTrue(store.settings()['radioEnabled'])
        other = Store(store.root)
        other.save_settings({'radioEnabled': False})
        self.assertTrue(store.settings()['radioEnabled'])
        store._settings_checked -= 6
        self.assertFalse(store.settings()['radioEnabled'])
        store.save_settings({'cacheGB': 30})
        self.assertFalse(store.settings()['radioEnabled'])

    def test_radio_listener_stops_immediately_after_settings_save(self):
        self.hub.store.save_settings({'radioEnabled': True})
        chunks = self.hub.radio.listen()
        self.hub.store.save_settings({'radioEnabled': False})
        self.assertEqual(list(chunks), [])
        self.assertEqual(len(self.hub.radio.listeners), 0)

    def test_existing_database_gets_job_indexes_idempotently(self):
        store = self.hub.store
        with store.connect() as db:
            for name in ('jobs_state_created', 'jobs_jobkey', 'jobs_created'):
                db.execute(f'DROP INDEX {name}')
        for _ in range(2):
            Store(store.root)
        with store.connect() as db:
            for name, columns in [('jobs_state_created', ['state', 'created']),
                                  ('jobs_jobkey', ['jobkey']), ('jobs_created', ['created'])]:
                self.assertEqual([row[2] for row in db.execute(f'PRAGMA index_info({name})')], columns)

    def test_lyrics_are_separate_screen_only_cached_and_retried(self):
        room = self.room()
        self.command(room, 'select', song=SONG)
        self.jf.lyrics.reset_mock()
        for role in ('screen', 'control', 'guest'):
            state = self.api('GET', '/room/state', headers=self.role(room, role)).json()
            self.assertNotIn('lyrics', state)
            self.assertEqual('lyricsRevision' in state, role == 'screen')
        self.jf.lyrics.assert_not_called()
        for role in ('control', 'guest'):
            self.assertEqual(self.api('GET', '/room/lyrics', headers=self.role(room, role)).status_code, 403)
        self.jf.lyrics.return_value = []
        response = self.api('GET', '/room/lyrics', headers=self.role(room, 'screen')).json()
        self.assertEqual(response['lyrics'], [])
        self.api('GET', '/room/lyrics', headers=self.role(room, 'screen'))
        self.jf.lyrics.assert_called_once_with(SONG)
        cached = self.hub.lyric_cache[SONG]
        self.hub.lyric_cache[SONG] = (cached[0] - 16, *cached[1:])
        state = self.api('GET', '/room/state', headers=self.role(room, 'screen')).json()
        self.assertEqual(state['lyricsRevision'], 'refresh')
        self.jf.lyrics.return_value = [{'timeMs': 0, 'text': 'Arrived later'}]
        refreshed = self.api('GET', '/room/lyrics', headers=self.role(room, 'screen')).json()
        self.assertNotEqual(refreshed['revision'], response['revision'])
        state = self.api('GET', '/room/state', headers=self.role(room, 'screen')).json()
        self.assertEqual(state['lyricsRevision'], refreshed['revision'])
        self.assertEqual(self.jf.lyrics.call_count, 2)
        self.command(room, 'select', 1, song=SECOND)
        self.assertEqual(self.api('GET', '/room/lyrics', headers=self.role(room, 'screen')).json()['song'], SECOND)

    def test_cache_touches_are_throttled_but_resume_after_a_minute(self):
        version = 'f' * 64
        directory = self.root / 'karaoke' / version
        directory.mkdir(parents=True)
        marker = directory / '.last-used'
        self.hub.touch_cache(version)
        modified = marker.stat().st_mtime_ns
        self.hub.touch_cache(version)
        self.assertEqual(marker.stat().st_mtime_ns, modified)
        os.utime(marker, (time.time() - 61, time.time() - 61))
        self.hub.touch_cache(version)
        self.assertGreater(marker.stat().st_mtime, time.time() - 2)

    def test_backup_json_is_streamed_and_checked_through_eof(self):
        import ijson
        native = self.root / 'native'
        native.mkdir()
        path = native / 'jellyfin-backup-test.zip'
        self.jf.json.return_value = {'Path': '/config/backups/' + path.name}
        # Cross the parser's buffer boundary, including multibyte text.
        valid = json.dumps({'rows': [{'name': 'caf\u00e9', 'n': i} for i in range(4000)]}, ensure_ascii=False).encode()
        for contents in (valid, valid[:-1], valid + b' garbage', b'{"rows":[1,]}'):
            with self.subTest(tail=contents[-20:]):
                with zipfile.ZipFile(path, 'w') as archive:
                    archive.writestr('database.json', contents)
                with patch.dict(os.environ, {'JELLYFIN_BACKUP_DIR': str(native)}):
                    if contents == valid:
                        with patch('hub_jobs.json.load', side_effect=AssertionError('Must stream JSON')):
                            self.hub.jobs.backup({'reason': 'test'})
                    else:
                        with self.assertRaises(ijson.JSONError):
                            self.hub.jobs.backup({'reason': 'test'})

    def test_unfinished_backup_folders_are_removed_at_start(self):
        stage = self.hub.store.root / '.backup-abc123'
        (stage / 'files').mkdir(parents=True)
        (stage / 'files' / 'analyzer-settings.json').write_text('{"ANALYZER_TOKEN": "secret"}')
        self.hub.jobs.remove_abandoned_backups()
        self.assertFalse(stage.exists())
        self.assertTrue((self.hub.store.root / 'hub.db').exists())


    def report(self, files=None):
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, 'w') as archive:
            for name, data in (files or {'logs.txt': 'Finamp+ logs'}).items():
                archive.writestr(name, data)
        return buffer.getvalue()

    def upload(self, kind, body, headers=None):
        return self.client.post(f'/hub/api/reports/{kind}', content=body,
            headers={**(self.headers if headers is None else headers), 'Content-Type': 'application/zip'})

    def test_uploaded_logs_keep_only_the_newest_five_for_each_user(self):
        for _ in range(7):
            response = self.upload('logs', self.report())
            self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(self.upload('logs', self.report(), {'X-Api-Key': 'private', 'X-Jellyfin-Token': 'other'}).status_code, 200)
        mine = self.api('GET', '/reports').json()
        self.assertEqual([report['kind'] for report in mine], ['logs'] * 5)
        self.assertEqual(len(list((self.hub.store.root / 'reports' / OWNER).iterdir())), 5)
        self.assertEqual(len(list((self.hub.store.root / 'reports' / OTHER).iterdir())), 1)
        stored = self.hub.store.root / 'reports' / OWNER / mine[0]['name']
        with zipfile.ZipFile(stored) as archive:
            self.assertEqual(archive.read('logs.txt'), b'Finamp+ logs')

    def test_uploads_must_be_a_signed_in_users_zip(self):
        self.assertEqual(self.upload('logs', self.report(), {'X-Api-Key': 'wrong', 'X-Jellyfin-Token': 'owner'}).status_code, 401)
        self.assertEqual(self.upload('logs', b'not a zip').status_code, 400)
        self.assertEqual(self.upload('photos', self.report()).status_code, 400)
        bomb = io.BytesIO()
        with zipfile.ZipFile(bomb, 'w', zipfile.ZIP_DEFLATED) as archive:
            archive.writestr('logs.txt', b'0' * (65 * 1024 * 1024))
        self.assertEqual(self.upload('logs', bomb.getvalue()).status_code, 400)
        self.assertEqual(self.api('GET', '/reports').json(), [])

    def test_report_uploads_may_be_larger_than_other_requests_but_not_unlimited(self):
        large = self.report({'logs.txt': os.urandom(3 * 1024 * 1024)})
        self.assertEqual(self.upload('bug', large).status_code, 200)
        self.assertEqual(self.upload('bug', b'x' * (16 * 1024 * 1024 + 1)).status_code, 413)
        self.assertEqual(self.client.post('/hub/api/rooms', headers=self.headers, content=large).status_code, 413)

    def test_bug_reports_are_removed_after_a_week(self):
        reports = self.hub.reports
        start = time.time()
        old = reports.save(OWNER, 'bug', self.report(), now=start - 8 * 86400)
        recent = reports.save(OWNER, 'bug', self.report(), now=start - 6 * 86400)
        logs = reports.save(OWNER, 'logs', self.report(), now=start - 30 * 86400)
        folder = self.hub.store.root / 'reports' / OWNER
        leftover = folder / '.bug-x.upload'
        leftover.write_bytes(b'half')
        os.utime(leftover, (start - 7200, start - 7200))
        reports.prune(now=start)
        self.assertEqual(sorted(path.name for path in folder.iterdir()), sorted([recent, logs]))
        self.assertNotIn(old, [path.name for path in folder.iterdir()])
        # At most every 10 minutes.
        reports.save(OWNER, 'bug', self.report(), now=start - 9 * 86400)
        reports.prune(now=start + 60)
        self.assertEqual(len(list(folder.iterdir())), 3)
        reports.prune(now=start + 601)
        self.assertEqual(len(list(folder.iterdir())), 2)

    def test_uploads_in_the_same_second_keep_the_newest(self):
        start = time.time()
        names = [self.hub.reports.save(OWNER, 'logs', self.report(), now=start) for _ in range(7)]
        self.assertEqual(sorted(report['name'] for report in self.hub.reports.listing(OWNER)), sorted(names[2:]))

    def test_a_report_removed_while_listing_is_left_out(self):
        kept = self.hub.reports.save(OWNER, 'logs', self.report())
        gone = self.hub.reports.save(OWNER, 'logs', self.report())
        real_stat = Path.stat

        def stat(path, *args, **kwargs):
            if path.name == gone:
                raise FileNotFoundError(path)
            return real_stat(path, *args, **kwargs)

        with patch.object(Path, 'stat', stat):
            self.assertEqual([report['name'] for report in self.hub.reports.listing(OWNER)], [kept])

    def test_at_most_twenty_bug_reports_are_kept(self):
        start = time.time()
        for index in range(22):
            self.hub.reports.save(OWNER, 'bug', self.report(), now=start - 22 + index)
        self.assertEqual(len(self.hub.reports.listing(OWNER)), 20)

    def test_the_job_loop_prunes_reports(self):
        self.hub.reports.prune = Mock()
        self.hub.stop_event.set()
        self.hub.stop_event.wait = Mock(side_effect=[False, True])
        self.hub.jobs.schedule = Mock()
        self.hub.jobs.run_one = Mock(return_value=False)
        self.hub.jobs.run()
        self.hub.reports.prune.assert_called_once()

    def test_the_job_loop_prunes_old_jobs_and_expired_rooms_hourly(self):
        old, recent = time.time() - 31 * 86400, time.time() - 29 * 86400
        with self.hub.store.connect() as db:
            for value, state, updated in [('a', 'ready', old), ('b', 'failed', old), ('c', 'ready', recent),
                                          ('d', 'queued', old), ('e', 'processing', old)]:
                db.execute('INSERT INTO jobs VALUES(?,?,?,?,?,?,?,?)', (value, 'health', value, '{}', state, '', old, updated))
            db.execute('INSERT INTO rooms VALUES(?,?,?,?,?)', ('1' * 32, OWNER, 'n', '{}', time.time() - 1))
            db.execute('INSERT INTO rooms VALUES(?,?,?,?,?)', ('2' * 32, OWNER, 'n', '{}', time.time() + 60))
        self.hub.reports.prune = Mock()
        self.hub.store.prune = Mock(wraps=self.hub.store.prune)
        self.hub.stop_event.wait = Mock(side_effect=[False, False, True])
        self.hub.jobs.schedule = Mock()
        self.hub.jobs.run_one = Mock(return_value=False)
        self.hub.jobs.run()
        self.hub.store.prune.assert_called_once()
        with self.hub.store.connect() as db:
            self.assertEqual(sorted(row[0] for row in db.execute('SELECT id FROM jobs')), ['c', 'd', 'e'])
            self.assertEqual([row[0] for row in db.execute('SELECT id FROM rooms')], ['2' * 32])

    def test_store_connections_close_at_the_end_of_their_block(self):
        with self.hub.store.connect() as db:
            db.execute("INSERT OR REPLACE INTO settings VALUES('probe','1')")
        with self.assertRaises(sqlite3.ProgrammingError):
            db.execute('SELECT 1')
        with self.hub.store.connect() as db:
            self.assertEqual(db.execute("SELECT value FROM settings WHERE key='probe'").fetchone()[0], '1')
        with self.assertRaises(ValueError), self.hub.store.connect() as db:
            db.execute("INSERT OR REPLACE INTO settings VALUES('probe','2')")
            raise ValueError()
        with self.assertRaises(sqlite3.ProgrammingError):
            db.execute('SELECT 1')
        with self.hub.store.connect() as db:
            self.assertEqual(db.execute("SELECT value FROM settings WHERE key='probe'").fetchone()[0], '1')

    def test_sync_polls_of_a_known_account_only_read(self):
        self.hub.sync.read(OWNER)
        with patch.object(Store, 'user', side_effect=AssertionError('wrote')):
            self.assertIn('configTag', self.hub.sync.read(OWNER))
        # A new account is still created on first sight.
        self.assertEqual(self.hub.sync.read(SECOND)['revision'], 0)

    def test_a_tv_waiting_for_its_song_asks_the_worker_every_15_seconds(self):
        room = self.room()
        self.command(room, 'select', song=SONG)
        self.hub.karaoke.reset_mock()
        self.hub.karaoke.return_value = {'state': 'processing'}
        clock = [1000.0]
        with patch('hub.time.monotonic', side_effect=lambda: clock[0]):
            for elapsed in (0, 2, 4, 14):
                clock[0] = 1000.0 + elapsed
                self.hub.refresh_rooms()
            self.assertEqual(self.hub.karaoke.call_count, 1)
            clock[0] = 1016.0
            self.hub.refresh_rooms()
            self.assertEqual(self.hub.karaoke.call_count, 2)
            # Another song is asked about at once.
            self.command(room, 'select', 1, song=SECOND)
            self.hub.karaoke.reset_mock()
            self.hub.refresh_rooms()
            self.assertEqual(self.hub.karaoke.call_count, 1)
            # A worker that can't be reached is asked again on the next round.
            self.hub.karaoke.side_effect = HTTPException(503, 'away')
            clock[0] = 1040.0
            self.hub.refresh_rooms()
            self.hub.refresh_rooms()
            self.assertEqual(self.hub.karaoke.call_count, 3)

    def test_room_preparation_writes_the_room_only_when_it_changes(self):
        room = self.room()
        self.command(room, 'select', song=SONG)
        self.hub.karaoke.return_value = {'state': 'processing'}
        self.hub.prepare_room(room['id'])
        statements, connect = [], self.hub.store.connect
        def traced():
            db = connect()
            db.set_trace_callback(statements.append)
            return db
        with patch.object(self.hub.store, 'connect', side_effect=traced):
            self.hub.prepare_room(room['id'])
            self.assertFalse([text for text in statements if text.startswith('UPDATE rooms')])
            self.hub.karaoke.return_value = {'state': 'failed'}
            self.hub.prepare_room(room['id'])
            self.assertTrue([text for text in statements if text.startswith('UPDATE rooms')])

    def test_backups_use_fast_compression(self):
        native = self.root / 'native'
        native.mkdir()
        path = native / 'jellyfin-backup-test.zip'
        with zipfile.ZipFile(path, 'w') as archive: archive.writestr('config.xml', '<config/>')
        self.jf.json.return_value = {'Path': '/config/backups/' + path.name}
        with patch.dict(os.environ, {'JELLYFIN_BACKUP_DIR': str(native)}):
            self.hub.jobs.backup({'reason': 'test'})
        with self.hub.store.connect() as db: backup = db.execute('SELECT * FROM backups').fetchone()
        self.assertIsNotNone(backup['verified'])
        # Gzip's header says which level wrote it: 4 is the fastest, 2 the smallest.
        self.assertEqual((self.hub.store.root / 'backups' / backup['name']).read_bytes()[8], 4)

    def test_cleanup_counts_tv_audio_towards_the_budget_and_removes_it_with_its_mixes(self):
        root = self.root / 'karaoke'
        root.mkdir()
        media = self.hub.store.root / 'media'
        media.mkdir()
        self.hub.store.save_settings({'nightlySongs': [], 'nightlyFavorites': False, 'cacheDays': 365, 'cacheGB': 1})
        with sqlite3.connect(root / 'jobs.db') as db:
            db.execute('CREATE TABLE jobs(id TEXT,revision TEXT,state TEXT,queued REAL)')
            for value, version, used in [(SONG, 'e' * 64, 1000), (SECOND, 'f' * 64, 2000)]:
                directory = root / version
                directory.mkdir()
                (directory / 'mix-0.flac').write_bytes(b'cache')
                marker = directory / '.last-used'
                marker.touch()
                os.utime(marker, (time.time() - used, time.time() - used))
                db.execute('INSERT INTO jobs VALUES(?,?,?,?)', (value, version, 'ready', 1))
        # Only the TV audio takes the cache past its gigabyte.
        with open(media / f'{"f" * 64}-0.mp3', 'wb') as audio:
            audio.truncate(1024 ** 3)
        def delete(method, path, **kwargs):
            if method == 'DELETE':
                k = root / kwargs['params']['revision']
                for file in k.iterdir():
                    file.unlink()
                k.rmdir()
            return {}
        self.hub.karaoke.side_effect = delete
        self.hub.jobs.cleanup({})
        deleted = [call.kwargs['params']['revision'] for call in self.hub.karaoke.call_args_list if call.args[0] == 'DELETE']
        # The least recently used goes first, and with it gone the cache is within budget.
        self.assertEqual(deleted, ['f' * 64])
        self.assertEqual(list(media.iterdir()), [])
        self.assertTrue((root / ('e' * 64)).is_dir())


if __name__ == '__main__':
    unittest.main()
