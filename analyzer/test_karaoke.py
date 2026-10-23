import json
import threading
from contextlib import ExitStack
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock, Mock, patch

from fastapi import HTTPException
from fastapi.testclient import TestClient
import karaoke as k


class KaraokeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.root_patch = patch.object(k, 'ROOT', self.root)
        self.root_patch.start()
        self.song = 'a' * 32
        self.revision = 'b' * 64
        with k.connect() as db:
            db.execute('CREATE TABLE jobs (id TEXT PRIMARY KEY, revision TEXT, state TEXT, progress REAL, message TEXT, queued REAL, seconds REAL)')
        self.source = patch.object(k, 'source_for', return_value=(self.root / 'music.flac', self.revision))
        self.source.start()
        k.REVISIONS.clear()

    def tearDown(self):
        self.source.stop()
        self.root_patch.stop()
        self.temp.cleanup()

    def ready(self):
        k.enqueue(self.song)
        directory = self.root / self.revision
        directory.mkdir()
        (directory / 'result.json').write_text(json.dumps({
            'mixes': {str(g): {'bytes': 4, 'version': 1, 'lufs': -14, 'truePeak': -1}
                      for g in (0, 25, 50, 75, 100)}, 'seconds': 1}))
        for guide in (0, 25, 50, 75, 100):
            (directory / f'mix-{guide}.flac').write_bytes(b'test')
        k.update(self.song, self.revision, state='ready', progress=1)

    def test_queue_is_idempotent_and_failed_jobs_can_retry(self):
        self.assertEqual(k.enqueue(self.song)['state'], 'queued')
        self.assertEqual(k.enqueue(self.song)['state'], 'queued')
        with k.connect() as db:
            self.assertEqual(db.execute('SELECT count(*) FROM jobs').fetchone()[0], 1)
        k.update(self.song, self.revision, state='failed')
        self.assertEqual(k.enqueue(self.song)['state'], 'queued')

    def test_authentication_requires_configured_matching_secret(self):
        with patch.object(k, 'TOKEN', 'secret'):
            k.authorize('secret')
            with self.assertRaises(HTTPException): k.authorize('wrong')
        for token in ['', 'change-me', 'change-me-too']:
            with self.subTest(token=token), patch.object(k, 'TOKEN', token):
                with self.assertRaises(HTTPException) as error: k.authorize(token)
                self.assertEqual(error.exception.status_code, 401)

    def test_playing_a_mix_checks_the_original_once_not_on_every_range_request(self):
        self.ready()
        k.status(self.song)
        k.source_for.reset_mock()
        for _ in range(5):
            k.audio(self.song, 0, self.revision)
        k.source_for.assert_not_called()
        # The status the app polls always looks again.
        k.status(self.song)
        k.source_for.assert_called_once()

    def test_changed_source_invalidates_ready_audio(self):
        self.ready()
        self.assertEqual(k.status(self.song)['state'], 'ready')
        with patch.object(k, 'source_for', return_value=(self.root / 'music.flac', 'c' * 64)):
            self.assertEqual(k.status(self.song)['state'], 'missing')
            with self.assertRaises(HTTPException): k.audio(self.song, 0, self.revision)

    def test_batched_status_checks_current_sources_and_cached_audio(self):
        self.ready()
        queued, missing = 'c' * 32, 'd' * 32
        k.enqueue(queued)
        request = k.StatusRequest(ids=[self.song, queued, missing, self.song])
        with patch.object(k, 'sources_for', return_value={self.song: (self.root / 'music.flac', self.revision)}) as sources:
            result = k.statuses(request)
            self.assertEqual([result[song]['state'] for song in (self.song, queued, missing)], ['ready', 'queued', 'missing'])
            sources.assert_called_once_with([self.song])
            sources.return_value = {self.song: (self.root / 'music.flac', 'e' * 64)}
            self.assertEqual(k.statuses(request)[self.song]['state'], 'missing')
            sources.return_value = {}
            self.assertEqual(k.statuses(request)[self.song]['state'], 'missing')
            sources.return_value = {self.song: (self.root / 'music.flac', self.revision)}
            (self.root / self.revision / 'mix-0.flac').unlink()
            self.assertEqual(k.statuses(request)[self.song]['state'], 'missing')

    def test_batched_status_route_is_authenticated_and_bounded(self):
        client = TestClient(k.app)
        with patch.object(k, 'TOKEN', 'private'):
            self.assertEqual(client.post('/karaoke/status', json={'ids': []}).status_code, 401)
            headers = {'X-Api-Key': 'private'}
            self.assertEqual(client.post('/karaoke/status', headers=headers, json={'ids': []}).json(), {})
            self.assertEqual(client.post('/karaoke/status', headers=headers, json={'ids': ['../bad']}).status_code, 400)
            self.assertEqual(client.post('/karaoke/status', headers=headers, json={'ids': [self.song] * 201}).status_code, 422)

    def test_batched_sources_share_one_lookup_and_restat_changed_files(self):
        music = self.root / 'music'
        music.mkdir()
        file = music / 'song.flac'
        file.write_bytes(b'music')
        other, missing = 'c' * 32, 'd' * 32
        response = MagicMock()
        response.__enter__.return_value = response
        response.json.return_value = {'Items': [
            {'Id': self.song, 'Type': 'Audio', 'Path': '/media/music/song.flac'},
            {'Id': other, 'Type': 'Audio', 'Path': '/media/music/../outside.flac'}]}
        with patch.object(k, 'PATH_MAP', [('/media/music', str(music))]), \
                patch.object(k.HTTP, 'request', return_value=response) as request:
            songs = [self.song, other, missing]
            first = k.sources_for(songs)
            self.assertEqual(set(first), {self.song})
            self.assertEqual(request.call_args.kwargs['params']['Ids'], ','.join(songs))
            self.assertEqual(request.call_count, 1)
            file.write_bytes(b'changed master')
            self.assertNotEqual(k.sources_for(songs)[self.song][1], first[self.song][1])

    def test_audio_cache_touches_are_throttled(self):
        self.ready()
        k.audio(self.song, 0, self.revision)
        marker = self.root / self.revision / '.last-used'
        modified = marker.stat().st_mtime_ns
        k.audio(self.song, 25, self.revision)
        self.assertEqual(marker.stat().st_mtime_ns, modified)

    def test_old_revision_and_unsupported_guide_cannot_serve_files(self):
        self.ready()
        with self.assertRaises(HTTPException): k.audio(self.song, 0, 'c' * 64)
        with self.assertRaises(HTTPException): k.audio(self.song, 13, self.revision)
        self.assertEqual(k.audio(self.song, 25, self.revision).path, self.root / self.revision / 'mix-25.flac')

    def test_missing_cached_mix_needs_preparation_again(self):
        self.ready()
        (self.root / self.revision / 'mix-25.flac').unlink()
        self.assertEqual(k.status(self.song)['state'], 'missing')
        self.assertEqual(k.enqueue(self.song)['state'], 'queued')

    def test_truncated_cached_mix_can_be_prepared_again(self):
        self.ready()
        (self.root / self.revision / 'mix-25.flac').write_bytes(b'bad')
        self.assertEqual(k.status(self.song)['state'], 'missing')
        with self.assertRaises(HTTPException): k.audio(self.song, 25, self.revision)
        self.assertEqual(k.enqueue(self.song)['state'], 'queued')

    def test_corrupt_manifests_can_be_prepared_again(self):
        self.ready()
        manifest = self.root / self.revision / 'result.json'
        for content in ['{', 'null', '[]', '{}', '{"mixes": null}',
                        '{"mixes": {"0": {"bytes": "4"}}}']:
            with self.subTest(content=content):
                manifest.write_text(content)
                self.assertEqual(k.status(self.song)['state'], 'missing')
                self.assertEqual(k.enqueue(self.song)['state'], 'queued')
                k.update(self.song, self.revision, state='ready')

    def test_cached_metadata_cannot_override_job_identity(self):
        self.ready()
        manifest = self.root / self.revision / 'result.json'
        result = json.loads(manifest.read_text())
        result.update(state='processing', revision='c' * 64)
        manifest.write_text(json.dumps(result))
        status = k.status(self.song)
        self.assertEqual(status['state'], 'ready')
        self.assertEqual(status['revision'], self.revision)

    def test_queue_has_a_bound(self):
        for i in range(k.MAX_QUEUED): k.enqueue(f'{i:032x}')
        with self.assertRaises(HTTPException) as caught: k.enqueue('f' * 32)
        self.assertEqual(caught.exception.status_code, 429)

    def test_invalid_ids_do_not_reach_jellyfin_or_disk(self):
        for value in ['../etc/passwd', 'x' * 32, '', 'a' * 33]:
            with self.assertRaises(HTTPException): k.enqueue(value)

    def test_catalogue_is_paginated_filtered_and_contains_only_job_metadata(self):
        for i in range(4):
            k.enqueue(f'{i:032x}')
        k.update('0' * 32, self.revision, state='processing')
        k.update(f'{1:032x}', self.revision, state='failed', message='Retry preparation')
        first = k.catalogue(offset=0, limit=2, state='')
        second = k.catalogue(offset=2, limit=2, state='')
        self.assertEqual(first['total'], 4)
        self.assertEqual(first['items'][0]['state'], 'processing')
        self.assertEqual(len({r['id'] for r in first['items'] + second['items']}), 4)
        failed = k.catalogue(offset=0, limit=50, state='failed')
        self.assertEqual(failed['total'], 1)
        self.assertEqual(failed['items'][0]['id'], f'{1:032x}')
        self.assertNotIn(str(self.root), json.dumps(first))
        self.assertEqual(k.catalogue(offset=100, limit=50, state='')['items'], [])
        with self.assertRaises(HTTPException): k.catalogue(offset=0, limit=50, state='invalid')

    def test_catalogue_does_not_report_damaged_audio_as_ready(self):
        self.ready()
        (self.root / self.revision / 'mix-0.flac').unlink()
        self.assertEqual(k.catalogue(offset=0, limit=50, state='')['items'][0]['state'], 'missing')

    def test_delete_ready_mix_removes_only_its_cache_and_is_idempotent(self):
        self.ready()
        original = self.root / 'music.flac'
        original.write_bytes(b'original')
        models = self.root / 'models'
        models.mkdir()
        (models / 'model.onnx').write_bytes(b'model')
        unrelated = self.root / ('d' * 64)
        unrelated.mkdir()
        self.assertEqual(k.delete(self.song, self.revision), {'state': 'missing'})
        self.assertFalse((self.root / self.revision).exists())
        self.assertEqual(k.catalogue(offset=0, limit=50, state='')['total'], 0)
        self.assertEqual(original.read_bytes(), b'original')
        self.assertEqual((models / 'model.onnx').read_bytes(), b'model')
        self.assertTrue(unrelated.is_dir())
        self.assertEqual(k.delete(self.song, self.revision), {'state': 'missing'})
        self.assertEqual(k.enqueue(self.song)['state'], 'queued')

    def test_delete_queued_and_failed_jobs_without_reading_original(self):
        for state in ('queued', 'failed'):
            k.enqueue(self.song)
            k.update(self.song, self.revision, state=state)
            with patch.object(k, 'source_for', side_effect=AssertionError('Must not read originals')):
                self.assertEqual(k.delete(self.song, self.revision)['state'], 'missing')
                self.assertEqual(k.status(self.song)['state'], 'missing')

    def test_delete_rejects_processing_and_stale_confirmations(self):
        self.ready()
        for state, revision in [('processing', self.revision), ('ready', 'c' * 64)]:
            k.update(self.song, self.revision, state=state)
            with self.assertRaises(HTTPException) as caught:
                k.delete(self.song, revision)
            self.assertEqual(caught.exception.status_code, 409)
            self.assertTrue((self.root / self.revision / 'mix-0.flac').is_file())
            self.assertEqual(k.catalogue(offset=0, limit=50, state='')['total'], 1)

    def test_delete_preserves_cache_shared_by_another_job(self):
        self.ready()
        other = 'c' * 32
        k.enqueue(other)
        k.delete(self.song, self.revision)
        self.assertTrue((self.root / self.revision / 'mix-0.flac').is_file())
        k.delete(other, self.revision)
        self.assertFalse((self.root / self.revision).exists())

    def test_delete_refuses_invalid_paths_and_symlinked_cache(self):
        for song in ('../music', 'z' * 32):
            with self.assertRaises(HTTPException): k.delete(song)
        k.enqueue(self.song)
        outside = self.root / 'originals'
        outside.mkdir()
        original = outside / 'song.flac'
        original.write_bytes(b'original')
        (self.root / self.revision).symlink_to(outside, target_is_directory=True)
        with self.assertRaises(HTTPException): k.delete(self.song, self.revision)
        self.assertEqual(original.read_bytes(), b'original')
        with k.connect() as db:
            db.execute('UPDATE jobs SET revision=? WHERE id=?', ('../originals', self.song))
        with self.assertRaises(HTTPException): k.delete(self.song)
        self.assertTrue(original.exists())

    def test_failed_cache_deletion_keeps_job_for_retry(self):
        self.ready()
        with patch.object(k.shutil, 'rmtree', side_effect=PermissionError):
            with self.assertRaises(HTTPException) as caught: k.delete(self.song, self.revision)
        self.assertEqual(caught.exception.status_code, 500)
        self.assertEqual(k.status(self.song)['state'], 'ready')

    def test_delete_route_and_proxy_require_authentication_and_forward_revision(self):
        route = next(r for r in k.app.routes if r.path == '/karaoke/{song}' and 'DELETE' in r.methods)
        self.assertIn(k.authorize, [d.call for d in route.dependant.dependencies])
        import karaoke_proxy
        authorize = lambda: None
        routes = karaoke_proxy.router(authorize)
        route = next(r for r in routes.routes if r.path == '/karaoke/{song}')
        self.assertIn('DELETE', route.methods)
        self.assertIn(authorize, [d.call for d in route.dependant.dependencies])
        upstream = Mock(content=b'{"state":"missing"}', status_code=200, headers={})
        request = Mock(method='DELETE', query_params={'revision': self.revision}, headers={})
        request.url.path = '/karaoke/' + self.song
        with patch.dict('os.environ', {'KARAOKE_URL': 'http://worker:8788', 'ANALYZER_TOKEN': 'test-secret'}), \
             patch.object(karaoke_proxy.requests, 'request', return_value=upstream) as send:
            response = route.endpoint(self.song, request)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(send.call_args.args, ('DELETE', 'http://worker:8788/karaoke/' + self.song))
        self.assertEqual(send.call_args.kwargs['params'], {'revision': self.revision})
        self.assertEqual(send.call_args.kwargs['headers'], {'X-Api-Key': 'test-secret'})
        upstream.close.assert_called_once()

    def test_catalogue_route_requires_authentication(self):
        route = next(r for r in k.app.routes if r.path == '/karaoke')
        self.assertIn(k.authorize, [d.call for d in route.dependant.dependencies])

    def test_catalogue_proxy_forwards_authentication_and_pagination(self):
        import karaoke_proxy
        authorize = lambda: None
        routes = karaoke_proxy.router(authorize)
        route = next(r for r in routes.routes if r.path == '/karaoke')
        self.assertIn(authorize, [d.call for d in route.dependant.dependencies])
        upstream = Mock(content=b'{"items":[],"total":0}', status_code=200)
        with patch.dict('os.environ', {'KARAOKE_URL': 'http://worker:8788', 'ANALYZER_TOKEN': 'test-secret'}), \
             patch.object(karaoke_proxy.requests, 'get', return_value=upstream) as get:
            response = route.endpoint(Mock(query_params={'offset': '50', 'limit': '50'}))
        self.assertEqual(response.status_code, 200)
        self.assertEqual(get.call_args.args[0], 'http://worker:8788/karaoke')
        self.assertEqual(get.call_args.kwargs['headers'], {'X-Api-Key': 'test-secret'})
        self.assertEqual(get.call_args.kwargs['params']['offset'], '50')
        upstream.close.assert_called_once()

    def test_path_mapping_rejects_prefix_collisions_and_symlinks(self):
        self.source.stop()
        music = self.root / 'music'
        music.mkdir()
        outside = self.root / 'outside.flac'
        outside.write_bytes(b'music')
        (music / 'escape.flac').symlink_to(outside)
        response = MagicMock()
        response.__enter__.return_value = response
        response.raise_for_status.return_value = None
        with patch.object(k, 'PATH_MAP', [('/media/music', str(music))]), patch.object(k.HTTP, 'request', return_value=response):
            for path in ['/media/music-other/outside.flac', '/media/music/escape.flac', '/media/music/../outside.flac']:
                response.json.return_value = {'Items': [{'Type': 'Audio', 'Path': path}]}
                with self.assertRaises(HTTPException): k.source_for(self.song)
            (music / 'song.flac').write_bytes(b'music')
            response.json.return_value = {'Items': [{'Type': 'Audio', 'Path': '/media/music/song.flac'}]}
            self.assertEqual(k.source_for(self.song)[0], music / 'song.flac')

    def test_deferred_preparation_keeps_its_place_and_failure_releases_the_background_lease(self):
        k.enqueue(self.song)
        runtime = Mock()
        runtime.try_acquire.return_value = (None, 'Waiting for more available memory')
        with patch.object(k, 'RUNTIME', runtime):
            with ExitStack() as leases:
                k.work_one(threading.Event(), leases)
            with k.connect() as db:
                row = db.execute('SELECT state,message FROM jobs WHERE id=?', (self.song,)).fetchone()
            self.assertEqual(row['state'], 'queued')
            self.assertIn('memory', row['message'])
            runtime.release.assert_not_called()
            runtime.try_acquire.return_value = (object(), None)
            with patch.object(k.subprocess, 'run', side_effect=RuntimeError('decoder failed')):
                with ExitStack() as leases:
                    k.work_one(threading.Event(), leases)
            runtime.release.assert_called_once()
            with k.connect() as db:
                self.assertEqual(db.execute('SELECT state FROM jobs WHERE id=?', (self.song,)).fetchone()[0], 'failed')


if __name__ == '__main__': unittest.main()
