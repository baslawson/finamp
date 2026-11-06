"""Karaoke files for download and shared links, with real ffmpeg conversions of a short clip."""
import json
import os
import subprocess
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import Mock, patch
from urllib.parse import unquote, urlsplit

from fastapi import FastAPI, HTTPException
from fastapi.testclient import TestClient

from hub import Hub, create_app
from hub_core import Actor, Jellyfin
from hub_exports import KEEP_DAYS, MOST_LINKS, details, file_name, label, tag_key

OWNER, OTHER, SONG, HIDDEN = 'a' * 32, 'b' * 32, 'c' * 32, 'e' * 32
VERSION, NEWER = '1' * 64, '2' * 64


def probe(path):
    result = subprocess.run(['ffprobe', '-v', 'error', '-show_entries', 'format=format_name,bit_rate:format_tags:stream=codec_name,sample_rate,channels',
        '-of', 'json', str(path)], check=True, capture_output=True, text=True)
    return json.loads(result.stdout)


class ExportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.items = {SONG: {'Id': SONG, 'Name': 'As The Days Go By', 'Type': 'Audio', 'Artists': ['Daryl Braithwaite'],
            'Album': 'Edge', 'AlbumArtist': 'Daryl Braithwaite'}}
        self.jf = Mock()
        self.jf.brief = Jellyfin.brief
        self.jf.actor.side_effect = lambda token=None, owner=None: Actor(
            OTHER if token == 'other' or owner == OTHER else OWNER, 'Listener', False)

        def item(owner, value):
            if value not in self.items:
                raise HTTPException(404, 'This song is not available to your account')
            return self.items[value]
        self.jf.item.side_effect = item
        self.hub = Hub(self.root, self.jf, 'private', 'http://worker')
        self.revision = VERSION
        self.hub.karaoke = Mock(side_effect=lambda method, path, **kw: {'state': 'ready', 'revision': self.revision})
        self.hub.caps
        self.mixes = self.root / 'karaoke' / VERSION
        self.mixes.mkdir(parents=True)
        for guide in (0, 25):
            subprocess.run(['ffmpeg', '-v', 'error', '-nostdin', '-f', 'lavfi', '-i', 'sine=frequency=440:duration=2',
                '-ar', '44100', '-ac', '2', '-c:a', 'flac', '-sample_fmt', 's16', '-y', str(self.mixes / f'mix-{guide}.flac')],
                check=True)
        app = FastAPI()
        app.mount('/hub', create_app(self.hub))
        self.client = TestClient(app)
        self.headers = {'X-Api-Key': 'private', 'X-Jellyfin-Token': 'owner'}
        self.other = {**self.headers, 'X-Jellyfin-Token': 'other'}

    def api(self, method, path, body=None, headers=None, **kwargs):
        return self.client.request(method, '/hub/api' + path, json=body,
            headers=self.headers if headers is None else headers, **kwargs)

    def ask(self, fmt='mp3', guide=0, part='vocals', headers=None):
        return self.api('POST', '/karaoke/exports', {'song': SONG, 'part': part, 'guide': guide, 'format': fmt}, headers)

    def status(self, fmt='mp3', guide=0, part='vocals'):
        return self.api('GET', f'/karaoke/exports?song={SONG}&part={part}&guide={guide}&format={fmt}').json()

    def tags(self, guide=0, part='vocals'):
        return tag_key(details(self.items[SONG], part, guide, 'mp3'))

    def exported(self, fmt='mp3', guide=0):
        """Where the song's converted file is kept."""
        return self.hub.exports.folder / f'{VERSION}-{guide}-{self.tags(guide)}.{fmt}'

    def prepared(self, fmt='mp3', guide=0):
        self.assertEqual(self.ask(fmt, guide).json()['state'], 'preparing')
        self.assertTrue(self.hub.jobs.run_one())
        answer = self.status(fmt, guide)
        self.assertEqual(answer['state'], 'ready', answer)
        return answer

    def test_labels_and_names(self):
        self.assertEqual(label('vocals', 0), 'No vocals')
        self.assertEqual(label('vocals', 25), 'No vocals, guide 25%')
        self.assertEqual(label('drums', 50), 'No drums, guide 50%')
        self.assertEqual(label('both', 0), 'No vocals or drums')
        self.assertEqual(label('both', 75), 'No vocals or drums, guide drums 75%')
        self.assertEqual(file_name('AC/DC', 'Live: Who? "Me"', 'vocals', 0, 'mp3'), 'AC DC - Live Who Me (No vocals).mp3')
        self.assertEqual(file_name('', 'Solo\nline', 'drums', 25, 'wav'), 'Solo line (No drums, guide 25%).wav')
        self.assertEqual(file_name('', '...', 'vocals', 0, 'flac'), 'Karaoke (No vocals).flac')
        # Names fit a file system's 255 bytes with the phone's ".partial", in any script, without a broken character.
        for artist in ['A' * 300, '日本語' * 100, '🎤' * 100]:
            long = file_name(artist, 'B', 'both', 100, 'flac')
            self.assertLessEqual(len((long + '.partial').encode()), 255, long)
            self.assertTrue(long.endswith(' (No vocals or drums, guide drums 100%).flac'), long)
            self.assertNotIn('�', long)

    def test_each_format_converts_with_tags_and_downloads_with_its_name(self):
        expected = {'mp3': ('mp3', 'mp3', 'audio/mpeg'), 'wav': ('wav', 'pcm_s16le', 'audio/wav'),
            'flac': ('flac', 'flac', 'audio/flac')}
        for fmt, (container, codec, media) in expected.items():
            with self.subTest(fmt=fmt):
                answer = self.prepared(fmt)
                self.assertEqual(answer['name'], f'Daryl Braithwaite - As The Days Go By (No vocals).{fmt}')
                response = self.api('GET', f'/karaoke/exports/file/{answer["ticket"]}', headers={})
                self.assertEqual(response.status_code, 200, response.text)
                self.assertEqual(response.headers['content-type'], media)
                self.assertIn(answer['name'], unquote(response.headers['content-disposition']))
                self.assertTrue(response.headers['content-disposition'].startswith('attachment;'))
                self.assertEqual(len(response.content), answer['bytes'])
                path = self.root / f'download.{fmt}'
                path.write_bytes(response.content)
                info = probe(path)
                self.assertIn(container, info['format']['format_name'])
                stream = info['streams'][0]
                self.assertEqual((stream['codec_name'], stream['sample_rate'], stream['channels']), (codec, '44100', 2))
                tags = {key.lower(): value for key, value in info['format'].get('tags', {}).items()}
                self.assertEqual(tags.get('title'), 'As The Days Go By (No vocals)')
                self.assertEqual(tags.get('artist'), 'Daryl Braithwaite')
                if fmt != 'wav':
                    self.assertEqual(tags.get('album'), 'Edge')
                if fmt == 'mp3':
                    self.assertGreater(int(info['format']['bit_rate']), 300000)

    def test_a_guide_level_has_its_own_file_and_name(self):
        quiet, plain = self.prepared('mp3', 25), self.prepared('mp3', 0)
        self.assertIn('guide 25%', quiet['name'])
        self.assertNotEqual(quiet['ticket'], plain['ticket'])
        self.assertEqual(sorted(path.name for path in (self.hub.store.root / 'exports').iterdir()),
            sorted([self.exported('mp3', 0).name, self.exported('mp3', 25).name]))

    def test_asking_again_shares_the_job_and_a_converted_file_comes_at_once(self):
        first, second = self.ask().json(), self.ask().json()
        self.assertEqual(first['job'], second['job'])
        self.assertEqual(self.status()['state'], 'preparing')
        self.hub.jobs.run_one()
        again = self.ask().json()
        self.assertEqual(again['state'], 'ready')
        self.assertFalse(self.hub.jobs.run_one(), 'nothing more to convert')

    def test_changed_song_details_get_a_file_with_the_new_tags(self):
        first = self.prepared()
        self.items[SONG] = {**self.items[SONG], 'Name': 'Renamed'}
        self.assertEqual(self.ask().json()['state'], 'preparing', 'the old file has the old tags')
        self.hub.jobs.run_one()
        answer = self.status()
        self.assertEqual(answer['name'], 'Daryl Braithwaite - Renamed (No vocals).mp3')
        response = self.api('GET', f'/karaoke/exports/file/{answer["ticket"]}', headers={})
        path = self.root / 'renamed.mp3'
        path.write_bytes(response.content)
        self.assertEqual(probe(path)['format']['tags']['title'], 'Renamed (No vocals)')
        self.assertEqual(self.api('GET', f'/karaoke/exports/file/{first["ticket"]}', headers={}).status_code, 200,
            'a ticket handed out before still gets its file')

    def test_a_conversion_waits_its_turn_with_the_server_s_other_work(self):
        runtime = self.hub.runtime = Mock()
        runtime.try_acquire.return_value = (None, 'Playback has priority')
        self.ask()
        self.assertFalse(self.hub.jobs.run_one())
        runtime.try_acquire.assert_called_with('export')
        self.assertEqual(self.status()['state'], 'preparing', 'still waiting, not failed')
        runtime.try_acquire.return_value = (object(), None)
        self.assertTrue(self.hub.jobs.run_one())
        runtime.release.assert_called_once()
        self.assertEqual(self.status()['state'], 'ready')

    def test_requests_are_checked(self):
        for body in [{'song': SONG, 'format': 'ogg'}, {'song': SONG, 'format': 'mp3', 'guide': 30},
                {'song': SONG, 'format': 'mp3', 'guide': '0'}, {'song': SONG, 'format': 'mp3', 'part': 'bass'},
                {'song': 'nope', 'format': 'mp3'}]:
            with self.subTest(body=body):
                self.assertEqual(self.api('POST', '/karaoke/exports', body).status_code, 400)
        hidden = self.api('POST', '/karaoke/exports', {'song': HIDDEN, 'format': 'mp3'})
        self.assertEqual(hidden.status_code, 404, 'a song the listener cannot see in Jellyfin')
        self.hub.karaoke.side_effect = lambda method, path, **kw: {'state': 'processing'}
        self.assertEqual(self.ask().status_code, 409)
        self.assertEqual(self.api('POST', '/karaoke/exports', {'song': SONG, 'format': 'mp3'}, headers={}).status_code, 401)

    def test_the_part_asked_for_is_the_one_looked_up(self):
        self.ask('mp3', 0, 'drums')
        self.assertEqual(self.hub.karaoke.call_args.kwargs, {'params': {'part': 'drums'}})

    def test_a_failed_conversion_is_reported_and_can_be_asked_again(self):
        (self.mixes / 'mix-0.flac').write_bytes(b'not audio at all' * 20)
        self.ask()
        self.hub.jobs.run_one()
        answer = self.status()
        self.assertEqual(answer, {'state': 'failed', 'message': 'The server could not convert this mix'})
        self.assertEqual(list((self.hub.store.root / 'exports').iterdir()), [], 'no partial file is left')
        self.assertEqual(self.ask().json()['state'], 'preparing', 'a new request tries again')

    def test_a_song_prepared_again_meanwhile_is_not_converted_from_its_old_mix(self):
        self.ask()
        import shutil
        shutil.copytree(self.mixes, self.root / 'karaoke' / NEWER)
        self.revision = NEWER
        self.hub.jobs.run_one()
        self.assertEqual(self.status()['state'], 'missing', 'the new mix has not been asked for yet')
        with self.hub.store.connect() as db:
            row = db.execute("SELECT state,message FROM jobs WHERE kind='export'").fetchone()
        self.assertEqual(tuple(row), ('failed', 'The song was prepared again; ask for the file again'))
        self.assertFalse(self.exported().exists())

    def test_tickets_are_checked(self):
        answer = self.prepared()
        caps = self.hub.caps
        for ticket in [answer['ticket'] + 'x', caps.issue('export', OWNER, seconds=-1, revision=VERSION, guide=0, format='mp3'),
                caps.issue('media', OWNER, revision=VERSION, guide=0, format='mp3')]:
            self.assertEqual(self.api('GET', f'/karaoke/exports/file/{ticket}', headers={}).status_code, 401)
        bad = caps.issue('export', OWNER, revision='../' + VERSION, guide=0, format='mp3')
        self.assertEqual(self.api('GET', f'/karaoke/exports/file/{bad}', headers={}).status_code, 400)
        missing = caps.issue('export', OWNER, revision=VERSION, guide=0, format='wav', tags='0' * 16, name='x.wav')
        self.assertEqual(self.api('GET', f'/karaoke/exports/file/{missing}', headers={}).status_code, 404)
        self.jf.actor.side_effect = HTTPException(403, 'Disabled')
        self.hub.actor_cache.clear()
        self.assertEqual(self.api('GET', f'/karaoke/exports/file/{answer["ticket"]}', headers={}).status_code, 403)

    def link(self, hours=24, fmt='mp3', headers=None):
        return self.api('POST', '/karaoke/links', {'song': SONG, 'format': fmt, 'hours': hours}, headers)

    def fetch(self, url, **headers):
        return self.client.get(urlsplit(url).path, headers=headers)

    def test_a_shared_link_downloads_the_file_without_signing_in_and_counts_downloads(self):
        self.assertEqual(self.link().status_code, 409, 'the file is prepared before it is shared')
        self.prepared()
        for hours in [0, 2, '24', None]:
            self.assertEqual(self.link(hours).status_code, 400)
        made = self.link(1).json()
        self.assertTrue(made['url'].startswith('http://testserver/hub/dl/'), made['url'])
        self.assertFalse(made['public'])
        self.assertAlmostEqual(made['expires'] - time.time(), 3600, delta=5)
        response = self.fetch(made['url'])
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(response.headers['content-type'], 'audio/mpeg')
        self.assertIn('As The Days Go By (No vocals).mp3', unquote(response.headers['content-disposition']))
        self.fetch(made['url'], Range='bytes=100-')
        self.fetch(made['url'], Range='bytes=0-')
        listed = self.api('GET', '/karaoke/links').json()
        self.assertEqual([(link['id'], link['downloads']) for link in listed['links']], [(made['id'], 2)])
        # The link handed out again is just as good: same link, same end.
        self.assertEqual(self.fetch(listed['links'][0]['url']).status_code, 200)

    def test_links_use_the_public_address_when_there_is_one(self):
        self.prepared()
        with patch.dict(os.environ, {'PUBLIC_URL': 'https://example.net/finamp-analyzer/'}):
            made = self.link().json()
        self.assertTrue(made['url'].startswith('https://example.net/finamp-analyzer/hub/dl/'), made['url'])
        self.assertTrue(made['public'])

    def test_a_stopped_expired_or_outdated_link_says_so_in_plain_text(self):
        self.prepared()
        stopped, expired, outdated = self.link().json(), self.link().json(), self.link().json()
        self.assertEqual(self.api('DELETE', f'/karaoke/links/{stopped["id"]}', headers=self.other).status_code, 404,
            'only its owner stops a link')
        self.assertEqual(self.api('DELETE', f'/karaoke/links/{stopped["id"]}').status_code, 200)
        self.assertEqual(self.api('DELETE', f'/karaoke/links/{stopped["id"]}').status_code, 404)
        with self.hub.store.connect() as db:
            db.execute('UPDATE links SET expires=? WHERE id=?', (time.time() - 1, expired['id']))
        for made in [stopped, expired]:
            response = self.fetch(made['url'])
            self.assertEqual(response.status_code, 410)
            self.assertTrue(response.headers['content-type'].startswith('text/plain'))
            self.assertIn('expired or was stopped', response.text)
        tampered = self.fetch(outdated['url'] + 'x')
        self.assertEqual((tampered.status_code, tampered.text.strip()), (410, 'This download link has expired or was stopped'))
        self.assertEqual(self.fetch(outdated['url']).status_code, 200)
        self.revision = NEWER
        self.assertEqual(self.fetch(outdated['url']).status_code, 410, 'the song was prepared again')

    def test_links_belong_to_their_owner_and_are_limited(self):
        self.prepared()
        made = self.link().json()
        self.assertEqual(self.api('GET', '/karaoke/links', headers=self.other).json()['links'], [])
        # A signed link for one account can't be turned into another account's link.
        borrowed = self.hub.caps.issue('link', OTHER, seconds=600, link=made['id'])
        self.assertEqual(self.client.get(f'/hub/dl/{borrowed}').status_code, 410)
        for _ in range(MOST_LINKS - 1):
            self.assertEqual(self.link().status_code, 200)
        self.assertEqual(self.link().status_code, 429)
        self.api('DELETE', f'/karaoke/links/{made["id"]}')
        self.assertEqual(self.link().status_code, 200, 'a stopped link frees its place')
        with self.hub.store.connect() as db:
            db.execute('UPDATE links SET expires=?', (time.time() - 1,))
        self.assertEqual(self.link().status_code, 200, 'expired links free theirs')

    def test_a_disabled_owner_s_links_stop_working(self):
        self.prepared()
        made = self.link().json()
        self.jf.actor.side_effect = HTTPException(403, 'Disabled')
        self.hub.actor_cache.clear()
        self.assertEqual(self.fetch(made['url']).status_code, 403)

    def test_unused_files_are_pruned_unless_a_link_offers_them(self):
        exports = self.hub.exports.folder
        old = time.time() - (KEEP_DAYS + 1) * 86400
        for path in [self.exported('mp3'), self.exported('wav'), self.exported('mp3', 25), exports / '.leftover.partial.mp3']:
            path.write_bytes(b'x' * 200)
            os.utime(path, (old, old))
        fresh = exports / f'{NEWER}-0-{"0" * 16}.mp3'
        fresh.write_bytes(b'x' * 200)
        self.prepared('flac')
        os.utime(self.exported('flac'), (old, old))
        self.link(fmt='flac')
        with self.hub.store.connect() as db:
            db.execute("INSERT INTO links VALUES('f'||hex(randomblob(15)),?,?,?,?,?,?,?,?,?,0,?)",
                (OWNER, SONG, 'vocals', VERSION, 0, 'wav', 'x.wav', time.time(), time.time() - 1, self.tags()))
        self.assertEqual(self.hub.exports.prune(), 4)
        self.assertEqual(sorted(path.name for path in exports.iterdir()), sorted([self.exported('flac').name, fresh.name]))
        with self.hub.store.connect() as db:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM links').fetchone()[0], 1, 'the expired link is gone')

    def test_converted_files_are_counted_and_removed_with_their_mix(self):
        self.prepared('mp3')
        self.prepared('wav')
        exports = self.hub.exports
        self.assertEqual(exports.size_of(VERSION), sum(path.stat().st_size for path in exports.folder.iterdir()))
        exports.remove_for(VERSION)
        self.assertEqual(list(exports.folder.iterdir()), [])

    def test_cleanup_removes_converted_files_with_the_mix(self):
        self.prepared('mp3')
        self.hub.store.save_settings({'cacheDays': 0, 'nightlyFavorites': False})
        database = self.root / 'karaoke' / 'jobs.db'
        import sqlite3
        with sqlite3.connect(database) as db:
            db.execute('CREATE TABLE jobs(id TEXT, part TEXT, revision TEXT, state TEXT)')
            db.execute("INSERT INTO jobs VALUES(?,?,?,'ready')", (SONG, 'vocals', VERSION))
        marker = self.mixes / '.last-used'
        marker.touch()
        os.utime(marker, (time.time() - 86400, time.time() - 86400))

        def worker(method, path, **kw):
            if method == 'DELETE':
                import shutil
                shutil.rmtree(self.mixes)
                return {'state': 'missing'}
            return {'state': 'ready', 'revision': self.revision}
        made = self.link().json()
        self.hub.karaoke.side_effect = worker
        self.assertEqual(self.hub.jobs.cleanup({}), 'Removed 0 unused server mixes', 'a live link keeps its mix')
        self.assertEqual(self.fetch(made['url']).status_code, 200)
        self.api('DELETE', f'/karaoke/links/{made["id"]}')
        self.assertEqual(self.hub.jobs.cleanup({}), 'Removed 1 unused server mixes')
        self.assertEqual(list(self.hub.exports.folder.iterdir()), [])


if __name__ == '__main__':
    unittest.main()
