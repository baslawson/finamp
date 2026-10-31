import json
import os
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from concurrent.futures import ThreadPoolExecutor
from contextlib import nullcontext
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest.mock import Mock, patch

from fastapi import HTTPException
from hub_core import Jellyfin
from server_http import HttpPool, ResultCache
from server_runtime import RuntimeGovernor, WorkDeferred, lower_worker_priority


class RequestTests(unittest.TestCase):
    def test_reuses_real_connections_without_retaining_cookies_or_account_headers(self):
        seen = []
        class Handler(BaseHTTPRequestHandler):
            protocol_version = 'HTTP/1.1'
            def do_GET(self):
                seen.append((self.client_address[1], self.headers.get('Authorization'), self.headers.get('Cookie')))
                self.send_response(200)
                self.send_header('Content-Length', '2')
                self.send_header('Set-Cookie', 'account=private')
                self.end_headers()
                self.wfile.write(b'{}')
            def log_message(self, *args):
                pass
        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        pool = HttpPool()
        try:
            url = f'http://127.0.0.1:{server.server_port}/'
            for account in ('first', 'second'):
                with pool.request('GET', url, headers={'Authorization': account}, timeout=3) as response:
                    self.assertEqual(response.json(), {})
            self.assertEqual(seen[0][0], seen[1][0])
            self.assertEqual([value[1:] for value in seen], [('first', None), ('second', None)])
            self.assertEqual(pool.status()['requests'], 2)
        finally:
            pool.close()
            server.shutdown()
            server.server_close()
            thread.join(timeout=3)

    def test_concurrent_queries_share_one_lookup_and_return_independent_data(self):
        cache, entered, release = ResultCache(), threading.Event(), threading.Event()
        calls = []
        def load():
            calls.append(True)
            entered.set()
            release.wait(3)
            return [{'name': 'original'}]
        with ThreadPoolExecutor(max_workers=20) as executor:
            futures = [executor.submit(cache.get, ('account', 'song'), load) for _ in range(20)]
            self.assertTrue(entered.wait(2))
            deadline = time.monotonic() + 2
            while cache.status()['shared'] < 19 and time.monotonic() < deadline:
                time.sleep(.005)
            release.set()
            results = [future.result(timeout=3) for future in futures]
        self.assertEqual(len(calls), 1)
        results[0][0]['name'] = 'modified'
        self.assertEqual(cache.get(('account', 'song'), load)[0]['name'], 'original')

    def test_metadata_is_account_scoped_expires_and_does_not_freeze_random_or_favourites(self):
        now = [1000]
        client = Jellyfin('http://jellyfin', 'private', [], '/music')
        client.metadata = ResultCache(clock=lambda: now[0])
        client.json = Mock(return_value={'Items': [{'Id': 'c' * 32, 'Type': 'Audio'}]})
        for owner in ('a' * 32, 'a' * 32, 'b' * 32):
            client.items(owner, ids=['c' * 32])
        self.assertEqual(client.json.call_count, 2)
        now[0] += 6
        client.items('a' * 32, ids=['c' * 32])
        self.assertEqual(client.json.call_count, 3)
        for _ in range(2):
            client.items('a' * 32, random=True)
            client.items('a' * 32, favorites=True)
        self.assertEqual(client.json.call_count, 7)
        client.http.close()

    def test_cache_is_bounded_and_failures_remain_retryable(self):
        cache = ResultCache(entries=4, items=7)
        for i in range(1000):
            cache.get(i, lambda: [1, 2, 3])
        self.assertLessEqual(cache.status()['items'], 7)
        self.assertLessEqual(cache.status()['entries'], 4)
        failing = Mock(side_effect=HTTPException(401, 'Sign in again'))
        for _ in range(2):
            with self.assertRaises(HTTPException):
                cache.get('failed-account', failing)
        self.assertEqual(failing.call_count, 2)
        self.assertEqual(cache.status()['pending'], 0)


class GovernorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.now = 1000
        self.sample = {'cpus': 4, 'load': [1, 1, 1], 'memoryTotal': 3 * 1024**3,
            'memoryAvailable': 2 * 1024**3, 'diskFree': 20 * 1024**3,
            'diskTotal': 40 * 1024**3, 'pressure': {'cpu': 0, 'memory': 0, 'io': 0}}
        self.gov = RuntimeGovernor(self.temp.name, playback=lambda: 1,
            probe=lambda _: self.sample, clock=lambda: self.now)
        self.gov.refresh()

    def test_pressure_and_low_space_defer_new_jobs_without_rejecting_healthy_playback(self):
        self.assertIsNone(self.gov.reason('analysis'))
        self.sample['pressure']['io'] = 3
        self.assertIn('disk activity', self.gov.reason('analysis'))
        self.sample['pressure']['io'] = 0
        self.sample['memoryAvailable'] = 1000 * 1024**2
        self.assertIn('memory', self.gov.reason('karaoke'))
        self.assertIsNone(self.gov.reason('analysis'))
        self.sample['diskFree'] = 1024**3
        self.assertIn('working space', self.gov.reason('analysis'))

    def test_unknown_playback_is_not_treated_as_idle_and_stale_workers_are_not_reported_running(self):
        with self.gov.slot('analysis'):
            self.assertEqual(self.gov.status()['workers'][0]['state'], 'running')
        self.now += 21
        self.assertIn('playback status', self.gov.reason('analysis'))
        self.assertEqual(self.gov.status()['workers'], [])

    def test_shared_lease_excludes_another_process_and_is_released_after_failure(self):
        descriptor, reason = self.gov.try_acquire('analysis')
        self.assertIsNone(reason)
        script = '''import json,sys
from server_runtime import RuntimeGovernor
g=RuntimeGovernor(sys.argv[1],role='karaoke',clock=lambda:1000)
g.sample=json.loads(sys.argv[2])
lease,reason=g.try_acquire('karaoke')
print(json.dumps({'acquired':lease is not None,'reason':reason}))
if lease is not None:g.release('karaoke',lease)
'''
        try:
            output = subprocess.check_output([sys.executable, '-c', script, self.temp.name, json.dumps(self.sample)], text=True, timeout=10)
            self.assertFalse(json.loads(output)['acquired'])
        finally:
            self.gov.release('analysis', descriptor)
        # The waiting karaoke must be able to take the released lease.
        worker = RuntimeGovernor(self.temp.name, role='karaoke', probe=lambda _: self.sample, clock=lambda: self.now)
        with self.assertRaises(ValueError):
            with worker.slot('karaoke'):
                raise ValueError('worker failed')
        with self.gov.slot('loudness'):
            self.assertEqual(self.gov.states['loudness']['state'], 'running')

    def test_demand_and_upcoming_priorities_are_bounded_and_do_not_reorder_album_members(self):
        a, b, c = 'a' * 32, 'b' * 32, 'c' * 32
        self.gov.priority_loader = lambda: [b]
        self.gov.request_analysis([c], 'loudness')
        self.assertEqual(self.gov.prioritize([a, b, c], lambda value: value), [c, b, a])
        albums = [[a], [a, b]]
        self.assertEqual(self.gov.prioritize(albums, lambda values: values), [[a, b], [a]])
        self.assertEqual(albums, [[a], [a, b]])
        self.gov.scan_events['loudness'].clear()
        self.gov.request_analysis([c], 'loudness')
        self.assertFalse(self.gov.scan_events['loudness'].is_set())
        for i in range(1300):
            self.gov.request_analysis([f'{i:032x}'], 'analysis')
        self.assertLessEqual(len(self.gov.demands), 1024)

    def test_stop_unblocks_deferred_work_without_publishing_a_measurement_failure(self):
        self.gov.stop.set()
        with self.assertRaises(WorkDeferred):
            with self.gov.slot('loudness'):
                self.fail('Stopped work must not start')

    def test_background_priority_leaves_the_api_thread_unchanged(self):
        original = os.getpriority(os.PRIO_PROCESS, threading.get_native_id())
        observed = []
        def background():
            lower_worker_priority()
            observed.append(os.getpriority(os.PRIO_PROCESS, threading.get_native_id()))
        thread = threading.Thread(target=background)
        thread.start()
        thread.join(timeout=3)
        self.assertEqual(observed, [10])
        self.assertEqual(os.getpriority(os.PRIO_PROCESS, threading.get_native_id()), original)

    def test_unavailable_library_retries_gradually_then_returns_to_normal_schedule(self):
        scan = Mock(side_effect=[ConnectionError(), ConnectionError(), None])
        delays = []
        def wait(group, delay):
            delays.append(delay)
            return len(delays) < 3
        self.gov.wait_scan = wait
        self.gov.run_scans('analysis', scan, 21600, Mock())
        self.assertEqual(delays, [60, 120, 21600])


class ApplicationTests(unittest.TestCase):
    def test_advanced_lifespan_does_not_import_torch_at_startup(self):
        import asyncio
        import builtins
        import app
        original_import = builtins.__import__
        def guarded(name, *args, **kwargs):
            if name == 'torch' or name.startswith('torch.'):
                self.fail('Startup imported PyTorch')
            return original_import(name, *args, **kwargs)
        async def startup():
            async with app.lifespan(app.app):
                pass
        with tempfile.TemporaryDirectory() as folder, \
                patch.multiple(app, DATA_DIR=folder, ADVANCED_ANALYSIS=True, HUB=Mock(), RUNTIME=Mock(), INDEX=Mock()), \
                patch('app.threading.Thread'), patch('app.LoudnessIndex'), \
                patch.object(builtins, '__import__', side_effect=guarded):
            asyncio.run(startup())
            app.DB.close()

    def test_real_lifespan_exposes_authorized_runtime_status_without_changing_existing_audio_routes(self):
        from fastapi.testclient import TestClient
        owner = 'a' * 32
        class Handler(BaseHTTPRequestHandler):
            protocol_version = 'HTTP/1.1'
            def do_GET(self):
                route = self.path.split('?')[0]
                value = [] if route == '/Sessions' else {'Items': []}
                if route == '/Users/Me':
                    value = {'Id': owner, 'Name': 'Listener', 'Policy': {'IsAdministrator': True}}
                body = json.dumps(value).encode()
                self.send_response(200)
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            def log_message(self, *args):
                pass
        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with tempfile.TemporaryDirectory() as folder, patch.dict(os.environ, {
                'DATA_DIR': folder, 'ADVANCED_ANALYSIS': 'false', 'ANALYZER_TOKEN': 'private',
                'JELLYFIN_URL': f'http://127.0.0.1:{server.server_port}', 'JELLYFIN_API_KEY': 'private',
            }):
                import importlib
                application = importlib.import_module('app')
                application.HUB.store.save_settings({'owner': owner, 'backupEnabled': False,
                    'nightlyEnabled': False, 'healthEnabled': False})
                headers = {'X-Api-Key': 'private', 'X-Jellyfin-Token': 'account'}
                with TestClient(application.app) as client:
                    self.assertEqual(client.get('/status', headers=headers).status_code, 200)
                    self.assertEqual(client.get('/hub/api/runtime').status_code, 401)
                    report = client.get('/hub/api/runtime', headers=headers)
                    self.assertEqual(report.status_code, 200, report.text)
                    self.assertIn('machine', report.json())
                    self.assertNotIn('private', report.text)
                    self.assertEqual(client.post('/loudness', headers=headers, json={'ids': []}).json(), {})
                    self.assertEqual(client.post('/analysis', headers=headers, json={'ids': []}).json(), {})
                self.assertTrue(application.RUNTIME.stop.is_set())
                application.DB.close()
                application.LOUDNESS.connection.close()
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=3)

    def test_api_refuses_requests_without_a_real_token_and_logs_no_tickets(self):
        import importlib
        import logging
        from fastapi import HTTPException
        from fastapi.testclient import TestClient
        # The settings are read on import; other tests import it again with their own.
        self.addCleanup(sys.modules.pop, 'app', None)
        with tempfile.TemporaryDirectory() as folder, patch.dict(os.environ, {'DATA_DIR': folder, 'ADVANCED_ANALYSIS': 'false'}):
            application = importlib.import_module('app')
            for token in ['', 'change-me', 'change-me-too']:
                with patch.object(application, 'ANALYZER_TOKEN', token):
                    with self.assertRaises(HTTPException): application.authorize(token)
            with patch.object(application, 'ANALYZER_TOKEN', 'a-long-private-test-secret'):
                application.authorize('a-long-private-test-secret')
                with self.assertRaises(HTTPException): application.authorize('a-long-private-test-secre')
                client = TestClient(application.app)
                self.assertEqual(client.get('/healthz').json(), {'ok': True})
                self.assertEqual(client.get('/', follow_redirects=False).headers['location'], 'hub/')
                response = client.post('/identify', headers={'X-Api-Key': 'a-long-private-test-secret'},
                    content=b'x' * (application.MAX_RECORDING_BYTES + 1))
                self.assertEqual(response.status_code, 413)
        record = logging.LogRecord('uvicorn.access', logging.INFO, '', 0, '%s "%s %s HTTP/%s" %d',
            ('10.0.0.2:5000', 'GET', '/hub/api/radio/stream/eyJrIjoxfQ.c2ln?x=1', '1.1', 200), None)
        application.HideTickets().filter(record)
        self.assertNotIn('eyJrIjoxfQ', record.getMessage())
        self.assertIn('/hub/api/radio/stream/', record.getMessage())
        record.args = ('10.0.0.2:5000', 'GET', '/hub/api/room/qr?ticket=secret&url=http://tv/%23secret', '1.1', 200)
        application.HideTickets().filter(record)
        self.assertNotIn('secret', record.getMessage())


class GenreFitTests(unittest.TestCase):
    def setUp(self):
        import app
        import numpy as np
        self.app, self.np = app, np
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        with patch.object(app, 'DATA_DIR', folder.name):
            self.database = app.db()
        self.addCleanup(self.database.close)
        loud, ballad, self.folk = np.eye(3, dtype=np.float32)
        rng = np.random.default_rng(1)
        def near(direction):
            vector = direction + rng.normal(0, 0.1, 3).astype(np.float32)
            return vector / np.linalg.norm(vector)
        self.ids = [f'rock{i}' for i in range(10)] + ['ballad0', 'ballad1']
        embeddings = np.stack([near(loud) for _ in range(10)] + [near(ballad), near(ballad)])
        index = Mock(lock=threading.Lock(), ids=self.ids, embeddings=embeddings,
                     positions={track_id: i for i, track_id in enumerate(self.ids)})
        texts = {'Rock music': loud, 'a soft ballad with piano and gentle vocals': ballad}
        for patcher in (
            patch.multiple(app, INDEX=index, ADVANCED_ANALYSIS=True, DB=self.database),
            patch.object(app, 'cached_text_embedding', side_effect=lambda text: texts.get(text, self.folk)),
        ):
            patcher.start()
            self.addCleanup(patcher.stop)

    def test_scores_the_analysed_songs_and_marks_ballads_down(self):
        app = self.app
        result = app.genre_fit(app.GenreFitRequest(
            genre='Rock', ids=[*(f'rock{i}' for i in range(10)), 'ballad-0', 'ballad1', 'unknown'],
            main=[f'rock{i}' for i in range(10)],
        ))
        scores = result['scores']
        self.assertEqual(set(scores), set(self.ids))
        self.assertLess(max(scores['ballad0'], scores['ballad1']), min(scores[f'rock{i}'] for i in range(10)))
        # Too few analysed songs to compare, or no genre: nothing is scored.
        self.assertEqual(app.genre_fit(app.GenreFitRequest(genre='Rock', ids=self.ids[:3]))['scores'], {})
        self.assertEqual(app.genre_fit(app.GenreFitRequest(genre=' ', ids=self.ids))['scores'], {})
        # Without AI analysis nothing is scored, but nothing fails either.
        with patch.object(app, 'ADVANCED_ANALYSIS', False):
            self.assertEqual(app.genre_fit(app.GenreFitRequest(genre='Rock', ids=self.ids)), {'scores': {}, 'labels': {}})

    def test_answers_are_kept_by_genre_and_returned_with_the_scores(self):
        app = self.app
        app.set_genre_label(app.GenreLabelRequest(id='rock-3', genre='Rock', fits=False))
        app.set_genre_label(app.GenreLabelRequest(id='ballad0', genre=' ROCK ', fits=True))
        app.set_genre_label(app.GenreLabelRequest(id='ballad0', genre='Soft Rock', fits=True))
        self.assertEqual(app.genre_labels(id='ballad0'), {'rock': True, 'soft rock': True})
        self.assertEqual(app.genre_labels(genre='rock'), {'rock3': False, 'ballad0': True})
        # Changing and forgetting an answer.
        app.set_genre_label(app.GenreLabelRequest(id='ballad0', genre='Rock', fits=False))
        app.set_genre_label(app.GenreLabelRequest(id='ballad0', genre='Soft Rock'))
        self.assertEqual(app.genre_labels(id='ballad0'), {'rock': False})
        result = app.genre_fit(app.GenreFitRequest(genre='Rock', ids=self.ids, main=self.ids[:10]))
        self.assertEqual(result['labels'], {'rock3': False, 'ballad0': False})
        # The answers come back even without AI analysis to check the sound.
        with patch.object(app, 'ADVANCED_ANALYSIS', False):
            self.assertEqual(
                app.genre_fit(app.GenreFitRequest(genre='Rock', ids=self.ids)),
                {'scores': {}, 'labels': {'rock3': False, 'ballad0': False}},
            )
        with self.assertRaises(HTTPException):
            app.set_genre_label(app.GenreLabelRequest(id='', genre='Rock', fits=True))
        with self.assertRaises(HTTPException):
            app.genre_labels()

    def test_answers_for_different_genre_picks_are_kept_apart(self):
        app = self.app
        # Radio names its picks with " | ", which Jellyfin genre names can't contain, so these never mix.
        app.set_genre_label(app.GenreLabelRequest(id='rock3', genre='Country and Western | Rock', fits=False))
        app.set_genre_label(app.GenreLabelRequest(id='rock3', genre='Country | Rock | Western', fits=True))
        app.set_genre_label(app.GenreLabelRequest(id='rock3', genre='Country | Rock | Western'))
        self.assertEqual(app.genre_labels(genre='country and western | rock'), {'rock3': False})
        self.assertEqual(app.genre_labels(genre='Country | Rock | Western'), {})
        # Long names that start the same stay apart too.
        start = ' | '.join(f'genre {i}' for i in range(30))
        app.set_genre_label(app.GenreLabelRequest(id='rock3', genre=f'{start} | blues', fits=False))
        app.set_genre_label(app.GenreLabelRequest(id='rock3', genre=f'{start} | jazz', fits=True))
        self.assertEqual(app.genre_labels(genre=f'{start} | blues'), {'rock3': False})
        self.assertEqual(app.genre_labels(genre=f'{start} | jazz'), {'rock3': True})
        self.assertEqual(app.genre_key(' Pop   Rock '), 'pop rock')
        # Only A to Z are lowered, as the app does.
        self.assertEqual(app.genre_key('İNDIE  Rock'), 'İndie rock')
        # A long name's key, as the genre editor reads it back, changes and clears the same answer.
        (key,) = app.genre_labels(id='rock3').keys() - {'country and western | rock', app.genre_key(f'{start} | jazz')}
        self.assertEqual(app.genre_key(key), key)
        app.set_genre_label(app.GenreLabelRequest(id='rock3', genre=key, fits=True))
        self.assertEqual(app.genre_labels(genre=f'{start} | blues'), {'rock3': True})
        app.set_genre_label(app.GenreLabelRequest(id='rock3', genre=key))
        self.assertEqual(app.genre_labels(genre=f'{start} | blues'), {})
        self.assertEqual(len(app.genre_labels(id='rock3')), 2)

    def test_answers_teach_the_genre_sound(self):
        app = self.app
        request = app.GenreFitRequest(genre='Ambient Rock', ids=self.ids, main=self.ids)
        before = app.genre_fit(request)['scores']
        # The listener says the ballads are the genre and three rockers aren't.
        for track_id, fits in [('ballad0', True), ('ballad1', True), ('rock0', False), ('rock1', False), ('rock2', False)]:
            app.set_genre_label(app.GenreLabelRequest(id=track_id, genre='Ambient Rock', fits=fits))
        after = app.genre_fit(request)['scores']
        self.assertGreater(after['ballad0'] - after['rock5'], before['ballad0'] - before['rock5'])


class HealthCacheTests(unittest.TestCase):
    def test_duplicate_cache_tracks_content_changes_while_health_stays_fresh(self):
        import app
        import numpy as np
        from loudness import LoudnessIndex
        with tempfile.TemporaryDirectory() as folder, patch.object(app, 'DATA_DIR', folder):
            database = app.db()
            self.addCleanup(database.close)
            loudness = LoudnessIndex(folder, '', '', folder, lambda path: path)
            self.addCleanup(loudness.connection.close)
            index = app.Index()
            embedding = np.array([1, 0], dtype=np.float32).tobytes()
            fingerprint = np.ones(40, dtype=np.uint32).tobytes()
            database.executemany('INSERT INTO tracks(id,path,mtime,embedding,fingerprint) VALUES(?,?,?,?,?)',
                [(value, value, 1, embedding, fingerprint) for value in ('a', 'b')])
            database.commit()
            with patch.multiple(app, DB=database, INDEX=index, LOUDNESS=loudness, ADVANCED_ANALYSIS=True, JELLYFIN_URL='test'), \
                    patch.object(app, 'library_items', return_value=[]) as items, \
                    patch('structure.same_recording', wraps=app.structure.same_recording) as compare:
                index.reload()
                self.assertEqual(app.health()['duplicates'], [['a', 'b']])
                self.assertEqual(compare.call_count, 1)
                database.execute("UPDATE tracks SET bpm=120,mtime=2")
                database.commit()
                index.reload()
                app.health()
                self.assertEqual(compare.call_count, 1)
                database.execute("INSERT INTO tracks(id,path,mtime,error) VALUES('bad','bad',1,'decoder error')")
                database.commit()
                items.return_value = [{'Id': 'tags'}]
                report = app.health()
                self.assertEqual(report['broken'][0]['id'], 'bad')
                self.assertEqual(report['missingTags'][0]['id'], 'tags')
                database.execute("UPDATE tracks SET fingerprint=? WHERE id='b'", (np.zeros(40, dtype=np.uint32).tobytes(),))
                database.commit()
                index.reload()
                app.health()
                self.assertEqual(compare.call_count, 2)
                database.execute("UPDATE tracks SET embedding=? WHERE id='b'", (np.array([0, 1], dtype=np.float32).tobytes(),))
                database.commit()
                index.reload()
                self.assertEqual(app.health()['duplicates'], [])
                database.execute("INSERT INTO tracks(id,path,mtime,embedding,fingerprint) VALUES('c','c',1,?,?)", (embedding, fingerprint))
                database.commit()
                index.reload()
                self.assertEqual(app.health()['duplicates'], [['a', 'c']])
                database.execute("DELETE FROM tracks WHERE id='c'")
                database.commit()
                index.reload()
                self.assertEqual(app.health()['duplicates'], [])


class LibrarySearchTests(unittest.TestCase):
    """Duplicate discovery and identification against straightforward full comparisons."""

    @staticmethod
    def library(rng, sounds=30, copies=3):
        import numpy as np

        def unit(vector):
            return (vector / np.linalg.norm(vector)).astype(np.float32)

        def flipped(fingerprint, share):
            bits = rng.random((len(fingerprint), 32)) < share
            return fingerprint ^ np.packbits(bits, axis=1, bitorder='little').view(np.uint32).ravel()

        base = [unit(rng.normal(size=512)) for _ in range(sounds)]
        prints = [rng.integers(0, 2 ** 32, size=200, dtype=np.uint32) for _ in range(sounds)]
        tracks = {}
        for k in range(sounds * copies):
            sound = k % sounds
            # Copies sound alike; most are the same recording, some another one (a different fingerprint).
            print_ = flipped(prints[sound], 0.05) if k % 7 else rng.integers(0, 2 ** 32, size=200, dtype=np.uint32)
            tracks[f't{k:03d}'] = (unit(base[sound] + rng.normal(size=512).astype(np.float32) * 0.005), print_)
        return tracks, unit, flipped, base, prints

    @staticmethod
    def load(index, tracks, revision):
        import numpy as np
        index.ids = sorted(tracks)
        index.positions = {track_id: i for i, track_id in enumerate(index.ids)}
        index.embeddings = np.stack([tracks[track_id][0] for track_id in index.ids]) if tracks \
            else np.zeros((0, 512), dtype=np.float32)
        index.fingerprints = [(track_id, tracks[track_id][1]) for track_id in index.ids if tracks[track_id][1] is not None]
        index.revision = revision

    @staticmethod
    def every_pair(tracks):
        import structure
        ids = sorted(tracks)
        return [[a, b] for i, a in enumerate(ids) for b in ids[i + 1:]
            if float(tracks[a][0] @ tracks[b][0]) > 0.97 and tracks[a][1] is not None and tracks[b][1] is not None
            and structure.same_recording(tracks[a][1], tracks[b][1])]

    def test_duplicates_are_compared_again_only_for_changed_tracks(self):
        import app
        import numpy as np
        rng = np.random.default_rng(5)
        tracks, unit, flipped, base, prints = self.library(rng)
        index = app.Index()
        with patch.object(app.Index, 'DUPLICATE_BLOCK', 7), \
                patch('structure.same_recording', wraps=app.structure.same_recording) as compare:
            self.load(index, tracks, b'1')
            expected = self.every_pair(tracks)
            compare.reset_mock()
            self.assertGreater(len(expected), 20)
            self.assertEqual(index.duplicates(), expected)
            everything = compare.call_count
            compare.reset_mock()
            self.assertEqual(index.duplicates(), expected, 'unchanged: from before')
            self.assertEqual(compare.call_count, 0)

            for step in range(4):
                ids = sorted(tracks)
                # Another sound, another recording, gone, and new.
                for track_id in rng.choice(ids, 3, replace=False):
                    tracks[track_id] = (unit(base[int(rng.integers(30))] + rng.normal(size=512).astype(np.float32) * 0.005),
                        tracks[track_id][1])
                for track_id in rng.choice(ids, 2, replace=False):
                    tracks[track_id] = (tracks[track_id][0], flipped(prints[int(rng.integers(30))], 0.05))
                for track_id in rng.choice(ids, 3, replace=False):
                    tracks.pop(track_id, None)
                for k in range(3):
                    sound = int(rng.integers(30))
                    tracks[f'n{step}{k}'] = (unit(base[sound] + rng.normal(size=512).astype(np.float32) * 0.005),
                        flipped(prints[sound], 0.05) if k else None)
                expected = self.every_pair(tracks)
                compare.reset_mock()
                self.load(index, tracks, f'{step + 2}'.encode())
                self.assertEqual(index.duplicates(), expected, f'after change {step}')
                self.assertLess(compare.call_count, everything / 3, 'only pairs with a changed track')

            # Only a change elsewhere in the library (the revision moves, the tracks' sound doesn't).
            compare.reset_mock()
            self.load(index, tracks, b'last')
            self.assertEqual(index.duplicates(), expected)
            self.assertEqual(compare.call_count, 0)
            self.load(index, {}, b'empty')
            self.assertEqual(index.duplicates(), [])

    def test_identification_finds_the_same_match_a_few_offsets_at_a_time(self):
        import app
        import numpy as np
        rng = np.random.default_rng(9)
        index = app.Index()
        index.fingerprints = [(f't{k}', rng.integers(0, 2 ** 32, size=int(rng.integers(150, 1200)), dtype=np.uint32))
            for k in range(25)]
        index.fingerprints.append(('short', rng.integers(0, 2 ** 32, size=20, dtype=np.uint32)))

        def whole(clip):
            best = (None, 1.0, 0.0)
            for track_id, track in index.fingerprints:
                if len(track) < len(clip):
                    continue
                windows = np.lib.stride_tricks.sliding_window_view(track, len(clip))
                errors = np.bitwise_count(windows ^ clip).sum(axis=1) / (32 * len(clip))
                if float(errors.min()) < best[1]:
                    best = (track_id, float(errors.min()), float(np.median(errors)) - float(errors.min()))
            return best

        with patch.object(app, 'INDEX', index):
            for track_id, track in index.fingerprints[:6]:
                start = int(rng.integers(0, len(track) - 120))
                bits = rng.random((120, 32)) < 0.2
                clip = track[start:start + 120] ^ np.packbits(bits, axis=1, bitorder='little').view(np.uint32).ravel()
                for offsets in (1, 7, 64, 512, 100000):
                    self.assertEqual(app.match_fingerprint(clip, offsets), whole(clip), f'{track_id}, {offsets} at a time')
                self.assertEqual(app.match_fingerprint(clip)[0], track_id)

    def test_duplicates_near_the_line_are_decided_alike_however_they_are_found(self):
        import app
        import numpy as np
        rng = np.random.default_rng(11)
        tracks = {}
        for k in range(150):
            a = rng.normal(size=512)
            a /= np.linalg.norm(a)
            other = rng.normal(size=512)
            other -= (other @ a) * a
            other /= np.linalg.norm(other)
            # Alike by very nearly the line, either side of it.
            alike = 0.97 + rng.uniform(-3e-7, 3e-7)
            b = alike * a + np.sqrt(1 - alike ** 2) * other
            print_ = rng.integers(0, 2 ** 32, size=200, dtype=np.uint32)
            tracks[f'a{k:03d}'] = (a.astype(np.float32), print_)
            tracks[f'b{k:03d}'] = (b.astype(np.float32), print_.copy())
        index = app.Index()
        self.load(index, tracks, b'1')
        index.duplicates()
        # One bit of each second fingerprint: the same recordings still, compared again one at a time.
        for k in range(150):
            changed = tracks[f'b{k:03d}'][1].copy()
            changed[0] ^= 1
            tracks[f'b{k:03d}'] = (tracks[f'b{k:03d}'][0], changed)
        self.load(index, tracks, b'2')
        fresh = app.Index()
        self.load(fresh, tracks, b'2')
        found = index.duplicates()
        self.assertEqual(found, fresh.duplicates())
        self.assertEqual(found, [[f'a{k:03d}', f'b{k:03d}'] for k in range(150)
            if float(tracks[f'a{k:03d}'][0].astype(np.float64) @ tracks[f'b{k:03d}'][0].astype(np.float64)) > 0.97])

    def test_identifications_beyond_two_wait_their_turn_without_holding_up_other_requests(self):
        import asyncio
        import importlib
        import httpx
        self.addCleanup(sys.modules.pop, 'app', None)
        sys.modules.pop('app', None)
        with tempfile.TemporaryDirectory() as folder, patch.dict(os.environ, {'DATA_DIR': folder, 'ADVANCED_ANALYSIS': 'false'}):
            application = importlib.import_module('app')
        searching, most, release = [0], [0], threading.Event()
        lock = threading.Lock()

        def search(_):
            with lock:
                searching[0] += 1
                most[0] = max(most[0], searching[0])
            release.wait(10)
            with lock:
                searching[0] -= 1
            return {'id': None, 'confidence': 0}

        token = 'a-long-private-test-secret'

        async def scenario():
            transport = httpx.ASGITransport(app=application.app)
            async with httpx.AsyncClient(transport=transport, base_url='http://analyzer') as client:
                # More than the worker threads every request shares.
                asked = [asyncio.create_task(client.post('/identify', headers={'X-Api-Key': token}, content=b'clip'))
                    for _ in range(50)]
                for _ in range(500):
                    if searching[0] >= 2:
                        break
                    await asyncio.sleep(0.01)
                await asyncio.sleep(0.3)
                self.assertEqual(searching[0], 2, 'two at a time')
                started = time.monotonic()
                health = await asyncio.wait_for(client.get('/healthz'), 5)
                self.assertEqual(health.json(), {'ok': True})
                self.assertLess(time.monotonic() - started, 2, 'other requests go ahead meanwhile')
                release.set()
                answers = await asyncio.wait_for(asyncio.gather(*asked), 30)
                self.assertTrue(all(answer.status_code == 200 for answer in answers))

        with patch.object(application, 'ANALYZER_TOKEN', token), patch.object(application, 'identify_recording', search):
            asyncio.run(scenario())
        self.assertEqual(most[0], 2)


class ClapTests(unittest.TestCase):
    def setUp(self):
        import app
        self.application = app
        self.model, self.processor = Mock(), Mock(return_value={})
        self.clap = (self.model, self.processor)
        self.clock = Mock()
        self.clock.monotonic.return_value = 100
        state = patch.multiple(app, _clap=self.clap, _clap_used=0, _clap_users=0,
            CLAP_IDLE_SECONDS=10, time=self.clock)
        state.start()
        self.addCleanup(state.stop)
        torch = Mock()
        torch.no_grad.return_value = nullcontext()
        modules = patch.dict(sys.modules, {'torch': torch})
        modules.start()
        self.addCleanup(modules.stop)

    def test_idle_model_is_released_while_scan_waits_for_memory(self):
        app = self.application
        with tempfile.TemporaryDirectory() as folder, patch.object(app, 'DATA_DIR', folder):
            source = Path(folder) / 'song.wav'
            source.write_bytes(b'music')
            database = app.db()
            runtime = RuntimeGovernor(folder)
            runtime.sample = {'diskFree': 20 * 1024**3, 'memoryAvailable': 0}
            ticks = iter([False, True])
            def wait(seconds):
                if seconds == 300:
                    return next(ticks)
                self.assertEqual(seconds, 1)
                self.assertTrue(app.INDEX.scanning)
                self.assertEqual(runtime.states['analysis']['state'], 'waiting')
                self.assertIn('memory', runtime.states['analysis']['message'])
                app.clap_loop()
                runtime.stop.set()
                return True
            try:
                with patch.multiple(app, DB=database, INDEX=app.Index(), RUNTIME=runtime), \
                        patch.object(app, 'library_tracks', return_value={'a' * 32: str(source)}), \
                        patch.object(app, 'analyze') as analyze, patch.object(runtime.stop, 'wait', side_effect=wait):
                    app.scan()
                    # scan() catches per-track errors; check eviction after it returns.
                    self.assertIsNone(app._clap)
                    self.assertFalse(app.INDEX.scanning)
                    analyze.assert_not_called()
                self.assertTrue(runtime.stop.is_set())
            finally:
                database.close()

    def test_audio_and_text_inference_keep_model_loaded_until_they_finish(self):
        app = self.application
        def features(**inputs):
            self.clock.monotonic.return_value = 200
            app.release_idle_clap()
            self.assertIs(app._clap, self.clap)
            return Mock(numpy=Mock(return_value=app.np.array([[3., 4.]])))
        self.model.get_audio_features.side_effect = features
        self.model.get_text_features.side_effect = features
        for embed, value in [(app.audio_embedding, app.np.zeros(app.SAMPLE_RATE)), (app.text_embedding, 'quiet music')]:
            with self.subTest(inference=embed.__name__):
                app._clap, app._clap_used = self.clap, 0
                self.clock.monotonic.return_value = 100
                app.np.testing.assert_allclose(embed(value), [.6, .8])
                self.assertEqual(app._clap_users, 0)
                self.assertEqual(app._clap_used, 200)
                app.release_idle_clap()
                self.assertIs(app._clap, self.clap)
                self.clock.monotonic.return_value = 211
                app.release_idle_clap()
                self.assertIsNone(app._clap)

    def test_first_model_load_sets_one_thread_before_loading_or_inference(self):
        app = self.application
        app._clap = None
        torch = sys.modules['torch']
        transformers = Mock()
        def load(_):
            torch.set_num_threads.assert_called_once_with(1)
            return self.model
        transformers.ClapModel.from_pretrained.side_effect = load
        with patch.dict(sys.modules, {'transformers': transformers}):
            with app.clap():
                self.assertEqual(app._clap_users, 1)
            with app.clap():
                pass
        torch.set_num_threads.assert_called_once_with(1)
        transformers.ClapModel.from_pretrained.assert_called_once()

    def test_failed_inference_does_not_prevent_later_eviction(self):
        app = self.application
        self.model.get_text_features.side_effect = RuntimeError('Inference failed')
        with self.assertRaises(RuntimeError):
            app.text_embedding('quiet music')
        self.assertEqual(app._clap_users, 0)
        self.assertEqual(app._clap_used, 100)
        self.clock.monotonic.return_value = 111
        app.release_idle_clap()
        self.assertIsNone(app._clap)

    def test_releasing_the_model_hands_its_memory_back_after_collecting_it(self):
        app = self.application
        app._clap, app._clap_used = self.clap, 0
        self.clock.monotonic.return_value = 10 ** 6
        order = []
        libc = Mock()
        libc.malloc_trim.side_effect = lambda pad: order.append(('trim', pad, app._clap))
        with patch.object(app.gc, 'collect', side_effect=lambda: order.append(('collect',))), \
                patch.object(app.ctypes, 'CDLL', return_value=libc) as cdll:
            app.release_idle_clap()
        cdll.assert_called_once_with('libc.so.6')
        self.assertEqual(order, [('collect',), ('trim', 0, None)])

    def test_a_model_still_in_use_is_kept_and_nothing_is_handed_back(self):
        app = self.application
        app._clap, app._clap_used = self.clap, 0
        self.clock.monotonic.return_value = 10 ** 6
        app._clap_users = 1
        try:
            with patch.object(app.ctypes, 'CDLL') as cdll:
                app.release_idle_clap()
        finally:
            app._clap_users = 0
        self.assertIs(app._clap, self.clap)
        cdll.assert_not_called()

    def test_without_glibc_the_model_is_still_released(self):
        app = self.application
        for error in (OSError('libc.so.6: cannot open shared object file'), AttributeError('malloc_trim')):
            with self.subTest(error=type(error).__name__):
                app._clap, app._clap_used = self.clap, 0
                self.clock.monotonic.return_value = 10 ** 6
                with patch.object(app.ctypes, 'CDLL', side_effect=error):
                    app.release_idle_clap()
                self.assertIsNone(app._clap)


if __name__ == '__main__':
    unittest.main()
