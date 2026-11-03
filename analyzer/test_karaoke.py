import json
import threading
from contextlib import ExitStack, closing
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
            # The table as servers from before drum removal made it; every test runs on the migrated one.
            db.execute('CREATE TABLE jobs (id TEXT PRIMARY KEY, revision TEXT, state TEXT, progress REAL, message TEXT, queued REAL, seconds REAL)')
            k.migrate(db)
        self.drums = '9' * 64
        self.both = '8' * 64
        self.revisions = {'vocals': self.revision, 'drums': self.drums, 'both': self.both}
        self.source = patch.object(k, 'source_for', side_effect=lambda song, part='vocals': (
            self.root / 'music.flac', self.revisions[part]))
        self.source.start()
        k.REVISIONS.clear()

    def tearDown(self):
        self.source.stop()
        self.root_patch.stop()
        self.temp.cleanup()

    def ready(self, part='vocals'):
        revision = self.revisions[part]
        k.enqueue(self.song, part)
        directory = self.root / revision
        directory.mkdir()
        (directory / 'result.json').write_text(json.dumps({
            'mixes': {str(g): {'bytes': 4, 'version': 1, 'lufs': -14, 'truePeak': -1}
                      for g in (0, 25, 50, 75, 100)}, 'seconds': 1}))
        for guide in (0, 25, 50, 75, 100):
            (directory / f'mix-{guide}.flac').write_bytes(part.encode()[:4].ljust(4))
        k.update(self.song, revision, state='ready', progress=1)

    def test_jobs_from_before_drums_stay_vocal_karaoke(self):
        with tempfile.TemporaryDirectory() as temp, patch.object(k, 'ROOT', Path(temp)):
            with k.connect() as db:
                db.execute('CREATE TABLE jobs (id TEXT PRIMARY KEY, revision TEXT, state TEXT, progress REAL, message TEXT, queued REAL, seconds REAL)')
                db.execute("INSERT INTO jobs VALUES (?,?,?,?,?,?,?)", (self.song, self.revision, 'ready', 1, 'Ready', 5, 9))
                k.migrate(db)
                k.migrate(db)
                rows = [dict(row) for row in db.execute('SELECT * FROM jobs')]
            self.assertEqual(rows, [{'id': self.song, 'part': 'vocals', 'revision': self.revision, 'state': 'ready',
                                     'progress': 1, 'message': 'Ready', 'queued': 5, 'seconds': 9}])

    def test_removed_mashup_jobs_and_their_files_are_retired(self):
        mashup, kept = 'c' * 64, 'd' * 64
        for revision in (mashup, kept):
            (self.root / revision).mkdir()
            (self.root / revision / 'mix.flac').write_bytes(b'mix')
        with k.connect() as db:
            for song, part, revision, state in ((f"{self.song}+{'e' * 32}", 'mashup', mashup, 'queued'),
                                                (f"{'f' * 32}+{self.song}", 'mashup', kept, 'ready'),
                                                (self.song, 'vocals', kept, 'ready')):
                db.execute('INSERT INTO jobs (id,part,revision,state) VALUES (?,?,?,?)', (song, part, revision, state))
            k.migrate(db)
            rows = [tuple(row) for row in db.execute('SELECT id,part FROM jobs')]
        self.assertEqual(rows, [(self.song, 'vocals')])
        self.assertFalse((self.root / mashup).exists())
        self.assertTrue((self.root / kept / 'mix.flac').exists())

    def test_a_failed_conversion_leaves_the_old_table_whole(self):
        with tempfile.TemporaryDirectory() as temp, patch.object(k, 'ROOT', Path(temp)):
            with k.connect() as db:
                # A table the copy cannot read, so the conversion fails after renaming it.
                db.execute('CREATE TABLE jobs (id TEXT PRIMARY KEY, revision TEXT, state TEXT)')
                db.execute("INSERT INTO jobs VALUES (?,?,?)", (self.song, self.revision, 'ready'))
            with self.assertRaises(k.sqlite3.OperationalError), k.connect() as db:
                k.migrate(db)
            with k.connect() as db:
                tables = [row[0] for row in db.execute("SELECT name FROM sqlite_master WHERE type='table'")]
                self.assertEqual(tables, ['jobs'])
                self.assertEqual([tuple(row) for row in db.execute('SELECT * FROM jobs')],
                                 [(self.song, self.revision, 'ready')])

    def test_vocal_revisions_are_unchanged_and_drum_revisions_are_their_own(self):
        self.source.stop()
        music = self.root / 'music'
        music.mkdir()
        file = music / 'song.flac'
        file.write_bytes(b'music')
        item = {'Type': 'Audio', 'Path': '/music/song.flac'}
        stat = file.stat()
        with patch.object(k, 'PATH_MAP', [('/music', str(music))]):
            vocals = k.source_item(item)[1]
            drums = k.source_item(item, 'drums')[1]
            with patch.object(k, 'DRUM_MODEL', k.MODEL):
                same_model = k.source_item(item, 'drums')[1]
        self.source.start()
        import hashlib
        self.assertEqual(vocals, hashlib.sha256(
            f'{k.MODEL}:v2:{file.resolve()}:{stat.st_size}:{stat.st_mtime_ns}'.encode()).hexdigest())
        self.assertNotEqual(drums, vocals)
        self.assertNotEqual(same_model, vocals)

    def test_drum_and_vocal_preparations_of_one_song_are_separate(self):
        self.ready()
        self.assertEqual(k.status(self.song, 'drums'), {'state': 'missing', 'progress': 0, 'part': 'drums'})
        queued = k.enqueue(self.song, 'drums')
        self.assertEqual((queued['state'], queued['part'], queued['revision']), ('queued', 'drums', self.drums))
        vocals = k.status(self.song)
        self.assertEqual((vocals['state'], vocals['part'], vocals['revision']), ('ready', 'vocals', self.revision))
        with self.assertRaises(HTTPException):
            k.audio(self.song, 0, self.drums, 'drums')
        self.assertEqual(k.delete(self.song, self.drums, 'drums'), {'state': 'missing', 'part': 'drums'})
        self.assertEqual(k.status(self.song)['state'], 'ready')
        self.assertTrue((self.root / self.revision / 'mix-0.flac').is_file())

    def test_drumless_mixes_are_served_only_for_drums(self):
        self.ready()
        self.ready('drums')
        self.assertEqual(k.audio(self.song, 25, self.drums, 'drums').path, self.root / self.drums / 'mix-25.flac')
        self.assertEqual(k.audio(self.song, 25, self.revision).path, self.root / self.revision / 'mix-25.flac')
        for revision, part in [(self.revision, 'drums'), (self.drums, 'vocals')]:
            with self.subTest(part=part), self.assertRaises(HTTPException):
                k.audio(self.song, 0, revision, part)
        self.assertEqual(k.status(self.song, 'drums')['mixes']['0']['bytes'], 4)
        self.assertEqual(k.delete(self.song, self.revision), {'state': 'missing', 'part': 'vocals'})
        self.assertFalse((self.root / self.revision).exists())
        self.assertEqual(k.status(self.song, 'drums')['state'], 'ready')

    def test_unknown_parts_are_refused(self):
        self.ready()
        calls = [lambda: k.enqueue(self.song, 'bass'), lambda: k.status(self.song, 'guitar'),
                 lambda: k.audio(self.song, 0, self.revision, ''), lambda: k.delete(self.song, self.revision, 'all'),
                 lambda: k.statuses(k.StatusRequest(ids=[self.song], part='bass')),
                 lambda: k.catalogue(offset=0, limit=50, state='', part='bass')]
        for call in calls:
            with self.assertRaises(HTTPException) as caught:
                call()
            self.assertEqual(caught.exception.status_code, 400)
        self.assertEqual(k.status(self.song)['state'], 'ready')

    def test_batched_status_answers_for_the_asked_part(self):
        self.ready()
        k.enqueue(self.song, 'drums')
        with patch.object(k, 'sources_for', return_value={}) as sources:
            drums = k.statuses(k.StatusRequest(ids=[self.song], part='drums'))[self.song]
            sources.assert_called_once_with([], 'drums')
        self.assertEqual((drums['state'], drums['part']), ('queued', 'drums'))
        with patch.object(k, 'sources_for', return_value={self.song: (self.root / 'music.flac', self.revision)}):
            vocals = k.statuses(k.StatusRequest(ids=[self.song]))[self.song]
        self.assertEqual((vocals['state'], vocals['part']), ('ready', 'vocals'))

    def test_catalogue_shows_older_apps_only_vocal_jobs(self):
        self.ready()
        k.enqueue(self.song, 'drums')
        self.assertEqual([item['part'] for item in k.catalogue(offset=0, limit=50, state='')['items']], ['vocals'])
        self.assertEqual([item['part'] for item in k.catalogue(offset=0, limit=50, state='', part='drums')['items']],
                         ['drums'])
        every = k.catalogue(offset=0, limit=50, state='', part='all')
        self.assertEqual((every['total'], [item['part'] for item in every['items']]), (2, ['drums', 'vocals']))
        self.assertEqual(k.catalogue(offset=0, limit=50, state='ready', part='all')['total'], 1)

    def test_drum_preparation_runs_the_drum_model_and_says_so(self):
        k.enqueue(self.song, 'drums')
        process = Mock(returncode=1)
        process.poll.return_value = 1
        seen = []

        def start(command, **_):
            with k.connect() as db:
                seen.append(db.execute("SELECT state, message FROM jobs WHERE id=? AND part='drums'",
                                       (self.song,)).fetchone())
            return process
        with patch.object(k.subprocess, 'run', return_value=Mock(stdout='{"format": {"duration": "200"}}')), \
                patch.object(k.shutil, 'disk_usage', return_value=Mock(free=10 * 1024 ** 3)), \
                patch.object(k.subprocess, 'Popen', side_effect=start) as popen:
            with ExitStack() as leases:
                k.work_one(threading.Event(), leases)
        self.assertEqual(popen.call_args.args[0][-2:], [k.DRUM_MODEL, 'drums'])
        self.assertEqual(Path(popen.call_args.args[0][3]), self.root / self.drums)
        self.assertEqual(tuple(seen[0]), ('processing', 'Loading drum separation model'))
        with k.connect() as db:
            row = db.execute("SELECT state, message FROM jobs WHERE id=? AND part='drums'", (self.song,)).fetchone()
        self.assertEqual(tuple(row), ('failed', 'Drum separation failed; the server may need more memory'))

    def prepare_both(self, elapsed=(0,)):
        """Runs the queued vocals-and-drums job with a worker that fails, returning its command line."""
        process = Mock(returncode=1)
        process.poll.side_effect = [None] * (len(elapsed) - 1) + [1] * 9
        seen = {}

        def start(command, **_):
            source = Path(command[2])
            seen['source'] = source.read_bytes() if source != self.root / 'music.flac' else None
            return process
        clock = iter(elapsed)
        stop = Mock()
        stop.wait.return_value = False
        with patch.object(k.subprocess, 'run', return_value=Mock(stdout='{"format": {"duration": "200"}}')), \
                patch.object(k.shutil, 'disk_usage', return_value=Mock(free=10 * 1024 ** 3)), \
                patch.object(k.time, 'monotonic', side_effect=lambda: next(clock, elapsed[-1])), \
                patch.object(k.subprocess, 'Popen', side_effect=start) as popen:
            with ExitStack() as leases:
                k.work_one(stop, leases)
        with k.connect() as db:
            row = db.execute("SELECT state, message FROM jobs WHERE id=? AND part='both'", (self.song,)).fetchone()
        return popen.call_args.args[0], seen['source'], tuple(row), process

    def test_both_takes_the_drums_out_of_a_ready_karaoke_instrumental(self):
        self.ready()
        queued = k.enqueue(self.song, 'both')
        self.assertEqual((queued['part'], queued['revision']), ('both', self.both))
        command, source, row, _ = self.prepare_both()
        self.assertEqual(command[-2:], [k.DRUM_MODEL, 'both'])
        self.assertEqual(Path(command[2]), self.root / self.both / 'instrumental.flac')
        self.assertEqual(source, b'voca')
        self.assertEqual(row, ('failed', 'Vocal and drum separation failed; the server may need more memory'))
        self.assertFalse((self.root / self.both / 'instrumental.flac').exists())
        self.assertEqual(k.status(self.song)['state'], 'ready')

    def test_both_runs_both_models_without_a_current_karaoke_instrumental(self):
        for case in ['missing', 'unfinished', 'stale', 'damaged']:
            with self.subTest(case=case):
                with k.connect() as db:
                    db.execute('DELETE FROM jobs')
                k.shutil.rmtree(self.root / self.revision, ignore_errors=True)
                if case == 'unfinished':
                    k.enqueue(self.song)
                    k.update(self.song, self.revision, state='processing')
                elif case != 'missing':
                    self.ready()
                    if case == 'stale':
                        # Whole and ready, but made from the song before it changed.
                        (self.root / self.revision).rename(self.root / ('7' * 64))
                        with k.connect() as db:
                            db.execute("UPDATE jobs SET revision=? WHERE part='vocals'", ('7' * 64,))
                    else:
                        (self.root / self.revision / 'result.json').write_text('{')
                k.enqueue(self.song, 'both')
                command, source, _, _ = self.prepare_both()
                self.assertEqual(command[5:7], [f'{k.MODEL},{k.DRUM_MODEL}', 'both'])
                self.assertEqual(Path(command[2]), self.root / 'music.flac')
                self.assertIsNone(source)

    def test_a_finished_both_keeps_only_its_mixes(self):
        self.ready()
        k.enqueue(self.song, 'both')
        destination = self.root / self.both

        def start(command, **_):
            # The worker's results, as a successful run leaves them.
            (destination / 'result.json').write_text((self.root / self.revision / 'result.json').read_text())
            for guide in (0, 25, 50, 75, 100):
                (destination / f'mix-{guide}.flac').write_bytes(b'both')
            return Mock(returncode=0, poll=Mock(return_value=0))
        with patch.object(k.subprocess, 'run', return_value=Mock(stdout='{"format": {"duration": "200"}}')), \
                patch.object(k.shutil, 'disk_usage', return_value=Mock(free=10 * 1024 ** 3)), \
                patch.object(k.subprocess, 'Popen', side_effect=start):
            with ExitStack() as leases:
                k.work_one(threading.Event(), leases)
        self.assertEqual(k.status(self.song, 'both')['state'], 'ready')
        self.assertFalse((destination / 'instrumental.flac').exists())
        self.assertTrue((self.root / self.revision / 'mix-0.flac').is_file())

    def finish_both(self, returncode=0, during=lambda: None):
        """Runs the queued vocals-and-drums job with a worker that leaves both its results, returning its command."""
        destination, commands = self.root / self.both, []

        def start(command, **_):
            commands.append(command)
            folders = [destination] + ([Path(command[7])] if len(command) > 7 else [])
            for folder in folders:
                folder.mkdir(exist_ok=True)
                (folder / 'result.json').write_text(json.dumps({
                    'mixes': {str(g): {'bytes': 4, 'version': 1, 'lufs': -14, 'truePeak': -1}
                              for g in (0, 25, 50, 75, 100)}, 'seconds': 7, 'model': 'm', 'part': 'p'}))
                for guide in (0, 25, 50, 75, 100):
                    (folder / f'mix-{guide}.flac').write_bytes(b'mix!')
            during()
            return Mock(returncode=returncode, poll=Mock(return_value=returncode))
        with patch.object(k.subprocess, 'run', return_value=Mock(stdout='{"format": {"duration": "200"}}')), \
                patch.object(k.shutil, 'disk_usage', return_value=Mock(free=10 * 1024 ** 3)), \
                patch.object(k.subprocess, 'Popen', side_effect=start):
            with ExitStack() as leases:
                k.work_one(threading.Event(), leases)
        return commands[0]

    def test_both_keeps_its_vocal_pass_as_the_karaoke_when_the_song_has_none(self):
        k.enqueue(self.song, 'both')
        command = self.finish_both()
        self.assertEqual(command[5:], [f'{k.MODEL},{k.DRUM_MODEL}', 'both', str(self.root / self.both / 'vocals')])
        self.assertEqual(k.status(self.song, 'both')['state'], 'ready')
        vocals = k.status(self.song)
        self.assertEqual((vocals['state'], vocals['revision'], vocals['seconds']), ('ready', self.revision, 7))
        self.assertEqual((self.root / self.revision / 'mix-0.flac').read_bytes(), b'mix!')
        self.assertFalse((self.root / self.both / 'vocals').exists())
        # And a song waiting for its karaoke has it straight away.
        with k.connect() as db:
            db.execute('DELETE FROM jobs')
        k.enqueue(self.song)
        k.enqueue(self.song, 'both')
        with k.connect() as db:
            db.execute("UPDATE jobs SET queued=queued+100 WHERE part='vocals'")
        self.finish_both()
        self.assertEqual(k.status(self.song)['state'], 'ready')

    def test_both_leaves_a_song_with_its_own_karaoke_alone(self):
        for state in ('processing', 'stale'):
            with self.subTest(state=state):
                with k.connect() as db:
                    db.execute('DELETE FROM jobs')
                k.enqueue(self.song)
                k.update(self.song, self.revision, state='processing')
                if state == 'stale':
                    with k.connect() as db:
                        db.execute("UPDATE jobs SET revision=?, state='ready' WHERE part='vocals'", ('7' * 64,))
                k.enqueue(self.song, 'both')
                command = self.finish_both()
                self.assertEqual(len(command), 7)
                with k.connect() as db:
                    row = db.execute("SELECT state, revision FROM jobs WHERE part='vocals'").fetchone()
                self.assertEqual(tuple(row), ('processing', self.revision) if state == 'processing'
                                 else ('ready', '7' * 64))

    def test_both_does_not_take_a_karaoke_folder_another_job_claimed_meanwhile(self):
        other = 'e' * 32
        k.enqueue(self.song, 'both')

        def claim():
            # Another Jellyfin entry for the same file asks for its karaoke while the separation runs.
            with k.connect() as db:
                db.execute("INSERT INTO jobs (id,part,revision,state,queued) VALUES (?,'vocals',?,'queued',?)",
                           (other, self.revision, k.time.time()))
        self.finish_both(during=claim)
        self.assertEqual(k.status(self.song, 'both')['state'], 'ready')
        self.assertEqual(k.status(self.song)['state'], 'missing')
        self.assertEqual(k.status(other)['state'], 'queued')

    def test_deleting_a_waiting_karaoke_meanwhile_does_not_spoil_the_vocal_pass(self):
        k.enqueue(self.song, 'both')

        def change_mind():
            # Karaoke asked for and deleted again from the dashboard while the separation runs.
            k.enqueue(self.song)
            k.delete(self.song)
        self.finish_both(during=change_mind)
        self.assertEqual(k.status(self.song, 'both')['state'], 'ready')
        self.assertEqual(k.status(self.song)['state'], 'ready')
        self.assertTrue((self.root / self.revision / 'result.json').is_file())

    def test_a_failed_both_keeps_no_vocal_karaoke(self):
        k.enqueue(self.song, 'both')
        self.finish_both(returncode=1)
        self.assertEqual(k.status(self.song)['state'], 'missing')
        self.assertFalse((self.root / self.revision).exists())
        self.assertFalse((self.root / self.both / 'vocals').exists())

    def test_unchanged_progress_is_not_written_again(self):
        k.enqueue(self.song, 'drums')
        process = Mock(returncode=1)
        process.poll.side_effect = [None] * 5 + [1] * 9
        stop = Mock()
        stop.wait.return_value = False
        with patch.object(k.subprocess, 'run', return_value=Mock(stdout='{"format": {"duration": "200"}}')), \
                patch.object(k.shutil, 'disk_usage', return_value=Mock(free=10 * 1024 ** 3)), \
                patch.object(k.subprocess, 'Popen', return_value=process), \
                patch.object(k, 'update', wraps=k.update) as update:
            with ExitStack() as leases:
                k.work_one(stop, leases)
        progress = [call for call in update.call_args_list if 'state' not in call.kwargs]
        self.assertEqual(len(progress), 1)

    def test_the_queue_is_in_wal_mode_and_readable_read_only(self):
        with patch.object(k, 'RuntimeGovernor'), patch.object(k, 'work'), TestClient(k.app):
            pass
        with k.connect() as db:
            self.assertEqual(db.execute('PRAGMA journal_mode').fetchone()[0], 'wal')
            self.assertEqual(db.execute('PRAGMA synchronous').fetchone()[0], 1)
            k.enqueue(self.song)
            # As the hub reads it, while the queue has it open.
            with closing(k.sqlite3.connect((self.root / 'jobs.db').as_uri() + '?mode=ro', uri=True)) as hub:
                self.assertEqual(hub.execute('SELECT count(*) FROM jobs').fetchone()[0], 1)

    def test_both_gets_time_for_each_separation_it_runs(self):
        k.enqueue(self.song, 'both')
        *_, row, process = self.prepare_both((0, 7199, 7199))
        process.kill.assert_not_called()
        k.enqueue(self.song, 'both')
        *_, row, process = self.prepare_both((0, 7201))
        process.kill.assert_called_once()
        self.assertEqual(row, ('failed', 'Preparation interrupted; tap Prepare to retry'))
        self.ready()
        k.enqueue(self.song, 'both')
        *_, row, process = self.prepare_both((0, 3601))
        process.kill.assert_called_once()

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
            sources.assert_called_once_with([self.song], 'vocals')
            # Each later check is past the 30 seconds a checked revision is kept.
            k.REVISIONS.clear()
            sources.return_value = {self.song: (self.root / 'music.flac', 'e' * 64)}
            self.assertEqual(k.statuses(request)[self.song]['state'], 'missing')
            k.REVISIONS.clear()
            sources.return_value = {}
            self.assertEqual(k.statuses(request)[self.song]['state'], 'missing')
            k.REVISIONS.clear()
            sources.return_value = {self.song: (self.root / 'music.flac', self.revision)}
            (self.root / self.revision / 'mix-0.flac').unlink()
            self.assertEqual(k.statuses(request)[self.song]['state'], 'missing')

    def test_batched_status_asks_jellyfin_again_only_after_30_seconds(self):
        self.ready()
        request = k.StatusRequest(ids=[self.song])
        clock = [1000.0]
        with patch.object(k, 'sources_for', side_effect=lambda songs, part: {
                    song: (self.root / 'music.flac', self.revision) for song in songs}) as sources, \
                patch.object(k.time, 'monotonic', side_effect=lambda: clock[0]):
            for elapsed in (0, 10, 29):
                clock[0] = 1000.0 + elapsed
                self.assertEqual(k.statuses(request)[self.song]['state'], 'ready')
            self.assertEqual([call.args for call in sources.call_args_list if call.args[0]], [([self.song], 'vocals')])
            clock[0] = 1031.0
            k.statuses(request)
            self.assertEqual(len([call for call in sources.call_args_list if call.args[0]]), 2)
            self.assertEqual(sources.call_args.args, ([self.song], 'vocals'))

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
        self.assertEqual(k.delete(self.song, self.revision), {'state': 'missing', 'part': 'vocals'})
        self.assertFalse((self.root / self.revision).exists())
        self.assertEqual(k.catalogue(offset=0, limit=50, state='')['total'], 0)
        self.assertEqual(original.read_bytes(), b'original')
        self.assertEqual((models / 'model.onnx').read_bytes(), b'model')
        self.assertTrue(unrelated.is_dir())
        self.assertEqual(k.delete(self.song, self.revision), {'state': 'missing', 'part': 'vocals'})
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
