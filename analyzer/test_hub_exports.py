"""Karaoke files for download and shared links, with real ffmpeg conversions of a short clip."""
import json
import os
import random
import shutil
import subprocess
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest.mock import Mock, patch
from urllib.parse import unquote, urlsplit

from fastapi import FastAPI, HTTPException
from fastapi.testclient import TestClient

from hub import Hub, create_app
from hub_core import NOT_VISIBLE, Actor, Jellyfin
from hub_exports import (KEEP_DAYS, MOST_LINKS, RECHECK_SECONDS, SHARE_SECONDS, details, file_name, label, link_owner,
    tag_key)

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
        self.jf.actor.side_effect = lambda token=None, owner=None, **kwargs: Actor(
            OTHER if token == 'other' or owner == OTHER else OWNER, 'Listener', False)

        def item(owner, value, **kwargs):
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

    def fetch_later(self, url, **headers):
        """[fetch] once what the link's page last found is no longer taken as so."""
        self.waited = getattr(self, 'waited', 0) + RECHECK_SECONDS + 1
        with patch('hub_exports.time.monotonic', return_value=time.monotonic() + self.waited):
            return self.fetch(url, **headers)

    def test_a_link_opened_by_many_at_the_same_moment_is_checked_once(self):
        self.prepared()
        made = self.link().json()
        token = urlsplit(made['url']).path.rsplit('/', 1)[1]
        self.hub.actor_cache.clear()
        self.jf.item.reset_mock()
        self.jf.actor.reset_mock()
        self.hub.karaoke.reset_mock()

        def slow(owner, value, **kwargs):
            time.sleep(0.15)
            return self.items[value]
        self.jf.item.side_effect = slow
        answers = []
        visitors = [threading.Thread(target=lambda: answers.append(self.hub.exports.shared(token).status_code))
            for _ in range(6)]
        for visitor in visitors:
            visitor.start()
        for visitor in visitors:
            visitor.join()
        self.assertEqual(answers, [200] * 6)
        # The owner's account too is looked up once for all of them.
        self.assertEqual((self.jf.actor.call_count, self.jf.item.call_count, self.hub.karaoke.call_count), (1, 1, 1))
        # Waiting on a check that doesn't answer in time, the others are told to try later.
        self.jf.item.side_effect = lambda owner, value, **kw: self.items[value]
        self.hub.karaoke.side_effect = lambda method, path, **kw: (time.sleep(2.5), {'state': 'ready',
            'revision': self.revision})[1]
        answers.clear()

        def visit():
            started = time.monotonic()
            status = self.hub.exports.shared(token).status_code
            answers.append((status, time.monotonic() - started < 1.5))
        # The others wait a little, and never past the time a page has.
        for wait, share in [(0.6, 10), (5, 1.2)]:
            answers.clear()
            with patch('hub_exports.WAIT_SECONDS', wait), patch('hub_exports.SHARE_SECONDS', share), \
                    patch('hub_exports.RECHECK_SECONDS', 0):
                self.hub.exports._found.clear()
                visitors = [threading.Thread(target=visit) for _ in range(3)]
                for visitor in visitors:
                    visitor.start()
                for visitor in visitors:
                    visitor.join()
            # The one checking answers once it knows.
            self.assertEqual(sorted(answers), [(200, False), (503, True), (503, True)])
        # Nothing kept for the checks once done.
        self.assertEqual(self.hub.exports._checks, {})

    def test_one_giving_up_on_a_check_leaves_it_to_the_others_arriving(self):
        self.prepared()
        made = self.link().json()
        token = urlsplit(made['url']).path.rsplit('/', 1)[1]
        self.hub.karaoke.reset_mock()
        self.hub.karaoke.side_effect = lambda method, path, **kw: (time.sleep(1.2), {'state': 'ready',
            'revision': self.revision})[1]
        answers = []

        def visit(after):
            time.sleep(after)
            answers.append(self.hub.exports.shared(token).status_code)
        # The first checks; the second gives up waiting; the third comes after that, while the check goes on.
        with patch('hub_exports.WAIT_SECONDS', 0.2):
            visitors = [threading.Thread(target=visit, args=(after,)) for after in (0, 0.1, 0.6)]
            for visitor in visitors:
                visitor.start()
            for visitor in visitors:
                visitor.join()
        self.assertEqual(sorted(answers), [200, 503, 503])
        self.assertEqual(self.hub.karaoke.call_count, 1, 'still checked once at a time')

    def test_those_waiting_on_a_check_that_ends_the_link_are_told_so_without_checking_again(self):
        self.prepared()
        made = self.link().json()
        token = urlsplit(made['url']).path.rsplit('/', 1)[1]
        self.hub.karaoke.reset_mock()
        self.hub.karaoke.side_effect = lambda method, path, **kw: (time.sleep(0.15), {'state': 'ready',
            'revision': NEWER})[1]
        answers = []
        visitors = [threading.Thread(target=lambda: answers.append(self.hub.exports.shared(token).body.decode()))
            for _ in range(4)]
        for visitor in visitors:
            visitor.start()
        for visitor in visitors:
            visitor.join()
        self.assertEqual(answers, ['This download is no longer available\n'] * 4)
        self.assertEqual(self.hub.karaoke.call_count, 1)

    def test_a_link_stopped_while_its_page_waited_says_so_without_the_file(self):
        self.prepared()
        made = self.link().json()
        token = urlsplit(made['url']).path.rsplit('/', 1)[1]
        stopped = threading.Event()

        def slow(method, path, **kw):
            # The owner stops the link while the first page checks it and the second waits.
            time.sleep(0.1)
            self.api('DELETE', f'/karaoke/links/{made["id"]}')
            stopped.set()
            return {'state': 'ready', 'revision': self.revision}
        self.hub.karaoke.side_effect = slow
        answers = {}

        def visit(name, after):
            time.sleep(after)
            response = self.hub.exports.shared(token)
            answers[name] = (response.status_code, getattr(response, 'body', b'').decode())
        visitors = [threading.Thread(target=visit, args=('first', 0)), threading.Thread(target=visit, args=('second', 0.05))]
        for visitor in visitors:
            visitor.start()
        for visitor in visitors:
            visitor.join()
        self.assertTrue(stopped.is_set())
        self.assertEqual(answers['second'], (410, 'This download link has expired or was stopped\n'))


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
        # Found working a moment ago, it's taken as still working for a little while.
        self.assertEqual(self.fetch(outdated['url']).status_code, 200)
        later = time.monotonic() + RECHECK_SECONDS + 1
        with patch('hub_exports.time.monotonic', return_value=later):
            self.assertEqual(self.fetch(outdated['url']).status_code, 410, 'the song was prepared again')

    def test_a_link_opened_by_many_at_once_asks_jellyfin_and_the_karaoke_server_once(self):
        self.prepared()
        made = self.link().json()
        self.hub.actor_cache.clear()
        self.jf.item.reset_mock()
        self.jf.actor.reset_mock()
        self.hub.karaoke.reset_mock()
        for _ in range(5):
            self.assertEqual(self.fetch(made['url']).status_code, 200)
        self.assertEqual((self.jf.item.call_count, self.hub.karaoke.call_count, self.jf.actor.call_count), (1, 1, 1))
        # The account check too is brief.
        connect, read = self.jf.actor.call_args.kwargs['timeout']
        self.assertLessEqual(connect, 2)
        self.assertLessEqual(connect + read, SHARE_SECONDS)
        # Stopped, it ends at once all the same.
        self.assertEqual(self.api('DELETE', f'/karaoke/links/{made["id"]}').status_code, 200)
        self.assertEqual(self.fetch(made['url']).status_code, 410)

    def test_something_else_than_jellyfins_answer_is_not_taken_for_lost_access(self):
        jellyfin = Jellyfin('http://jellyfin.invalid', 'key', None, '/music')
        with patch.object(jellyfin, 'json', return_value={'Items': []}):
            with self.assertRaises(HTTPException) as gone:
                jellyfin.item(OWNER, SONG)
        self.assertEqual((gone.exception.status_code, gone.exception.detail), (404, NOT_VISIBLE))
        for odd in [{}, {'Items': None}, None, ['x']]:
            with patch.object(jellyfin, 'json', return_value=odd), self.assertRaises(HTTPException) as failed:
                jellyfin.item(OWNER, SONG)
            self.assertEqual(failed.exception.status_code, 502, odd)

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
        response = self.fetch(made['url'])
        # Someone with the link isn't told about the owner's account.
        self.assertEqual((response.status_code, response.text.strip()), (410, 'This download link has expired or was stopped'))

    def test_a_link_does_not_name_its_owner_and_older_links_still_work(self):
        self.prepared()
        made, second = self.link().json(), self.link().json()
        owners = []
        for link in (made, second):
            payload = self.hub.caps.read(urlsplit(link['url']).path.rsplit('/', 1)[1], {'link'})
            self.assertNotIn(OWNER, json.dumps(payload))
            owners.append(payload['owner'])
        self.assertNotEqual(owners[0], owners[1], "two links can't be tied to one account")
        self.assertEqual(owners[0], link_owner(self.hub.caps.secret, made['id']))
        older = self.hub.caps.issue('link', OWNER, seconds=600, link=made['id'])
        self.assertEqual(self.client.get(f'/hub/dl/{older}').status_code, 200, 'as 1.6.97 handed them out')
        for owner in (OTHER, owners[1], link_owner(b'x' * 32, made['id'])):
            borrowed = self.hub.caps.issue('link', owner, seconds=600, link=made['id'])
            self.assertEqual(self.client.get(f'/hub/dl/{borrowed}').status_code, 410, owner)

    def test_a_song_the_owner_can_no_longer_see_ends_its_links(self):
        self.prepared()
        made, listed = self.link().json(), self.link().json()
        hidden = self.items.pop(SONG)
        response = self.fetch(made['url'])
        self.assertEqual((response.status_code, response.text.strip()), (410, 'This download is no longer available'))
        self.assertNotIn('account', response.text)
        self.assertEqual(self.api('GET', '/karaoke/links').json()['links'], [], 'nor listed, nor taking up places')
        self.items[SONG] = hidden
        self.assertEqual(self.fetch(listed['url']).status_code, 410, 'ended for good')

    def test_a_mix_not_ready_for_a_moment_keeps_its_links(self):
        self.prepared()
        made = self.link().json()
        # Being prepared again, its mix unreadable for a moment (which the worker reports as missing), or the song's own
        # file unreadable for a moment (a network drive gone, say).
        def unreadable(method, path, **kwargs):
            raise HTTPException(404, 'The server cannot read this music file')
        for answer in (lambda method, path, **kw: {'state': 'processing', 'revision': self.revision},
                lambda method, path, **kw: {'state': 'missing', 'revision': self.revision,
                    'message': 'Prepare this song again'}, unreadable):
            self.hub.karaoke.side_effect = answer
            response = self.fetch_later(made['url'])
            self.assertEqual((response.status_code, response.text.strip()),
                (503, 'This download is not available right now. Try again later.'))
            self.assertEqual(len(self.api('GET', '/karaoke/links').json()['links']), 1)
        self.hub.karaoke.side_effect = lambda method, path, **kw: {'state': 'ready', 'revision': self.revision}
        self.assertEqual(self.fetch_later(made['url']).status_code, 200)

    def test_server_trouble_says_try_later_without_details(self):
        self.prepared()
        made = self.link().json()
        self.hub.karaoke.side_effect = HTTPException(502, 'Karaoke worker at 10.0.0.5 is down')
        response = self.fetch(made['url'])
        self.assertEqual(response.status_code, 503)
        self.assertNotIn('10.0.0.5', response.text)
        self.assertEqual(len(self.api('GET', '/karaoke/links').json()['links']), 1, 'kept while the server cannot say')
        self.hub.karaoke.side_effect = lambda method, path, **kw: {'state': 'ready', 'revision': self.revision}
        self.assertEqual(self.fetch(made['url']).status_code, 503, 'not asked again at once')
        self.assertEqual(self.fetch_later(made['url']).status_code, 200, 'works again once the server is back')

    def test_listing_asks_a_struggling_karaoke_server_briefly_and_once(self):
        self.prepared()
        self.link()
        with self.hub.store.connect() as db:
            for song in ('d' * 32, 'f' * 32):
                self.items[song] = {**self.items[SONG], 'Id': song}
                db.execute("INSERT INTO links VALUES(?,?,?,?,?,?,?,?,?,?,0,?)", (song, OWNER, song, 'vocals',
                    VERSION, 0, 'mp3', 'x.mp3', time.time(), time.time() + 600, self.tags()))
        self.hub.karaoke = Mock(side_effect=HTTPException(503, 'The karaoke worker is temporarily unavailable'))
        self.assertEqual(len(self.api('GET', '/karaoke/links').json()['links']), 3, 'all kept')
        self.hub.karaoke.assert_called_once()
        connect, read = self.hub.karaoke.call_args.kwargs['timeout']
        self.assertLessEqual(connect, 2)
        self.assertLessEqual(connect + read, 6)
        # Jellyfin is asked as briefly.
        self.assertLessEqual(self.jf.item.call_args.kwargs['timeout'][1], 6)

    def test_listing_many_links_stops_checking_in_time_and_keeps_the_rest(self):
        self.prepared()
        songs = [f'{index:032x}' for index in range(1, 9)]
        with self.hub.store.connect() as db:
            for song in songs:
                self.items[song] = {**self.items[SONG], 'Id': song}
                db.execute("INSERT INTO links VALUES(?,?,?,?,?,?,?,?,?,?,0,?)", (song, OWNER, song, 'vocals',
                    VERSION, 0, 'mp3', 'x.mp3', time.time(), time.time() + 600, self.tags()))
        def slow(method, path, **kwargs):
            time.sleep(0.3)
            return {'state': 'ready', 'revision': NEWER}
        self.hub.karaoke = Mock(side_effect=slow)
        with patch('hub_exports.LIST_SECONDS', 1.0):
            started = time.monotonic()
            listed = self.api('GET', '/karaoke/links').json()['links']
        self.assertLess(time.monotonic() - started, 2)
        self.assertLess(self.hub.karaoke.call_count, len(songs))
        # Those checked had ended (a new mix); those not checked in time are kept for the next look.
        self.assertEqual(len(listed), len(songs) - self.hub.karaoke.call_count)
        self.assertGreater(len(listed), 0)

    def test_link_previews_get_the_name_without_the_file_or_a_count(self):
        self.prepared()
        made = self.link().json()
        for agent in ['WhatsApp/2.23.20.0', 'facebookexternalhit/1.1', 'Mozilla/5.0 (compatible; Discordbot/2.0)']:
            response = self.fetch(made['url'], **{'User-Agent': agent})
            self.assertEqual(response.status_code, 200)
            self.assertTrue(response.headers['content-type'].startswith('text/plain'), agent)
            self.assertIn('As The Days Go By', response.text)
        # Browsers, among them a chat app's own (Pinterest's), get the file.
        for agent in ['Mozilla/5.0 Firefox/130.0', 'Mozilla/5.0 (Linux; Android 14) Chrome/120 [Pinterest/Android]']:
            self.assertEqual(self.fetch(made['url'], **{'User-Agent': agent}).headers['content-type'], 'audio/mpeg')
        self.assertEqual(self.api('GET', '/karaoke/links').json()['links'][0]['downloads'], 2)

    def test_a_link_to_a_song_prepared_again_ends_for_good_and_frees_its_place(self):
        self.prepared()
        made = [self.link().json() for _ in range(MOST_LINKS)]
        self.assertEqual(self.link().status_code, 429)
        self.revision = NEWER
        shutil.copytree(self.mixes, self.root / 'karaoke' / NEWER)
        self.prepared()
        self.assertEqual(self.link().status_code, 200, 'the old links no longer take up places')
        self.revision = NEWER
        self.assertEqual(len(self.api('GET', '/karaoke/links').json()['links']), 1, 'only the new one is listed')
        self.revision = VERSION
        self.assertEqual(self.fetch(made[0]['url']).status_code, 410, 'the same mix coming back does not revive it')
        self.assertEqual(self.api('GET', '/karaoke/links').json()['links'], [])
        self.assertEqual(self.link().status_code, 200)

    def test_a_changed_song_or_a_lost_file_ends_its_links(self):
        self.prepared()
        changed, lost = self.link().json(), self.link(fmt='mp3').json()
        self.hub.karaoke.side_effect = lambda method, path, **kw: {
            'state': 'missing', 'changed': True, 'message': 'The original song changed; prepare it again'}
        self.assertEqual(self.fetch(changed['url']).status_code, 410)
        self.hub.karaoke.side_effect = lambda method, path, **kw: {'state': 'ready', 'revision': self.revision}
        self.assertEqual(self.fetch(changed['url']).status_code, 410, 'ended for good')
        self.exported().unlink()
        self.assertEqual(self.fetch(lost['url']).status_code, 410)
        with self.hub.store.connect() as db:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM links').fetchone()[0], 0)

    def test_a_deleted_or_replaced_mix_ends_its_links(self):
        self.prepared()
        # Deleted from the app (no job any more); replaced by one still being prepared; replaced by one that failed.
        # Or prepared again (the same mix) and that failed: nothing is making it.
        for answer in ({'state': 'missing', 'part': 'vocals'}, {'state': 'processing', 'revision': NEWER},
                {'state': 'failed', 'revision': NEWER, 'message': 'Server restarted; tap Prepare to retry'},
                {'state': 'failed', 'revision': VERSION, 'message': 'Server restarted; tap Prepare to retry'}):
            with self.subTest(answer=answer):
                self.hub.karaoke.side_effect = lambda method, path, **kw: {'state': 'ready', 'revision': VERSION}
                made = self.link().json()
                self.hub.karaoke.side_effect = lambda method, path, answer=answer, **kw: answer
                self.assertEqual(self.api('GET', '/karaoke/links').json()['links'], [])
                self.hub.karaoke.side_effect = lambda method, path, **kw: {'state': 'ready', 'revision': VERSION}
                self.assertEqual(self.fetch(made['url']).status_code, 410, 'the same mix back does not revive it')

    def test_a_404_on_the_way_to_jellyfin_is_not_lost_access(self):
        self.prepared()
        made = self.link().json()
        self.jf.item.side_effect = HTTPException(404, 'Jellyfin could not complete this request')
        self.assertEqual(self.fetch(made['url']).status_code, 503)
        self.assertEqual(len(self.api('GET', '/karaoke/links').json()['links']), 1)
        self.hub.exports.prune()
        self.jf.item.side_effect = lambda owner, value, **kw: self.items[value]
        self.assertEqual(self.fetch_later(made['url']).status_code, 200)
        # Nor on the way to the owner's account.
        self.hub.actor_cache.clear()
        self.jf.actor.side_effect = HTTPException(404, 'Jellyfin could not complete this request')
        response = self.fetch_later(made['url'])
        self.assertEqual((response.status_code, response.text.strip()), (503, 'This download is not available right now. Try again later.'))
        with self.hub.store.connect() as db:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM links').fetchone()[0], 1, 'kept')

    def test_a_file_gone_as_it_is_sent_says_so(self):
        self.prepared()
        made = self.link().json()

        def taken(path, *args):
            # The cleanup removing it after it was looked at, just before it's sent.
            os.unlink(path)
            raise FileNotFoundError(path)
        with patch('hub_exports.os.utime', side_effect=taken):
            response = self.fetch(made['url'])
        self.assertFalse(self.exported().exists())
        self.assertEqual((response.status_code, response.text.strip()), (410, 'This download is no longer available'))
        with self.hub.store.connect() as db:
            self.assertEqual(db.execute('SELECT downloads FROM links').fetchone()[0], 0, 'not counted')

    def test_odd_answers_from_jellyfin_or_the_karaoke_server_hold_nothing_up(self):
        self.prepared()
        made = self.link().json()
        # A proxy's page in place of the karaoke server's answer; an empty body in place of Jellyfin's.
        self.hub.karaoke.side_effect = ValueError('Expecting value')
        response = self.fetch(made['url'])
        self.assertEqual((response.status_code, response.text.strip()), (503, 'This download is not available right now. Try again later.'))
        asked = self.hub.karaoke.call_count
        self.assertEqual(self.fetch(made['url']).status_code, 503)
        self.assertEqual(self.hub.karaoke.call_count, asked, 'not asked again at once')
        self.assertEqual(len(self.api('GET', '/karaoke/links').json()['links']), 1)
        # Not asked again for each link after an odd answer.
        other = 'f' * 32
        self.items[other] = {**self.items[SONG], 'Id': other}
        with self.hub.store.connect() as db:
            db.execute("INSERT INTO links VALUES(?,?,?,?,?,?,?,?,?,?,0,?)", ('0' * 32, OWNER, other, 'vocals',
                VERSION, 0, 'mp3', 'x.mp3', time.time(), time.time() + 600, self.tags()))
        self.hub.karaoke.reset_mock()
        self.hub.exports.prune()
        self.assertEqual(self.hub.karaoke.call_count, 1)
        self.hub.karaoke.side_effect = lambda method, path, **kw: {'state': 'ready', 'revision': self.revision}
        self.jf.item.reset_mock()
        self.jf.item.side_effect = AttributeError("'NoneType' object has no attribute 'get'")
        self.assertEqual(self.fetch_later(made['url']).status_code, 503)
        self.jf.item.assert_called_once()
        self.hub.exports.prune()
        with self.hub.store.connect() as db:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM links').fetchone()[0], 2)
        self.jf.item.side_effect = lambda owner, value, **kw: self.items[value]
        self.assertEqual(self.fetch_later(made['url']).status_code, 200, 'works again')

    def test_the_hub_s_jobs_go_on_when_the_link_cleanup_fails(self):
        self.hub.exports.prune = Mock(side_effect=ValueError('Expecting value'))
        self.hub.jobs.schedule = Mock()
        self.hub.jobs.run_one = Mock(side_effect=lambda: self.hub.stop_event.set())
        self.hub.jobs.remove_abandoned_backups = Mock()
        self.hub.stop_event.clear()
        waits = []
        def wait(seconds=None):
            # A loop stuck on the cleanup ends here too, failing below.
            waits.append(seconds)
            if len(waits) > 5:
                self.hub.stop_event.set()
            return self.hub.stop_event.is_set()
        with patch.object(self.hub.stop_event, 'wait', side_effect=wait), patch('hub_jobs.lower_worker_priority'):
            self.hub.jobs.run()
        self.hub.exports.prune.assert_called_once()
        self.hub.jobs.schedule.assert_called_once()
        self.hub.jobs.run_one.assert_called_once()

    def test_the_hourly_cleanup_checks_in_another_order_each_time(self):
        self.prepared()
        self.link()
        other = 'f' * 32
        self.items[other] = {**self.items[SONG], 'Id': other}
        with self.hub.store.connect() as db:
            db.execute("INSERT INTO links VALUES(?,?,?,?,?,?,?,?,?,?,0,?)", ('0' * 32, OWNER, other, 'vocals',
                NEWER, 0, 'mp3', 'x.mp3', time.time(), time.time() + 600, self.tags()))
        # Time for one song an hour (its Jellyfin check, then the karaoke server's, which needs half a second left):
        # the live link's song, first in order, would take it every time.
        def item(owner, value, **kwargs):
            time.sleep(0.4)
            return self.items[value]
        self.jf.item.side_effect = item
        # Seeded for this test alone.
        self.addCleanup(random.setstate, random.getstate())
        random.seed(1)
        with patch('hub_exports.SWEEP_SECONDS', 1.2):
            for _ in range(12):
                self.hub.exports.prune()
        with self.hub.store.connect() as db:
            self.assertEqual([row[0] for row in db.execute('SELECT song FROM links')], [SONG])

    def test_the_hub_turned_down_by_jellyfin_or_the_karaoke_server_says_try_later(self):
        self.prepared()
        made = self.link().json()
        self.hub.karaoke.side_effect = HTTPException(401, 'The karaoke worker could not complete this request')
        self.assertEqual(self.fetch(made['url']).status_code, 503)
        # A proxy before the karaoke server refusing isn't the owner's account disabled.
        self.hub.karaoke.side_effect = HTTPException(403, 'Forbidden')
        self.assertEqual(self.fetch_later(made['url']).status_code, 503)
        self.hub.karaoke.side_effect = lambda method, path, **kw: {'state': 'ready', 'revision': self.revision}
        self.jf.item.reset_mock()
        self.jf.item.side_effect = HTTPException(401, 'Please sign in to Jellyfin again')
        self.assertEqual(self.fetch_later(made['url']).status_code, 503)
        self.jf.item.assert_called_once()
        # Turned down looking up the owner, too.
        self.jf.item.side_effect = lambda owner, value, **kw: self.items[value]
        self.jf.actor.reset_mock()
        self.jf.actor.side_effect = HTTPException(401, 'Please sign in to Jellyfin again')
        self.hub.actor_cache.clear()
        self.assertEqual(self.fetch_later(made['url']).status_code, 503)
        self.jf.actor.assert_called_once()
        # None of it ended the link.
        self.jf.actor.side_effect = lambda token=None, owner=None, **kwargs: Actor(OWNER, 'Listener', False)
        self.assertEqual(self.fetch_later(made['url']).status_code, 200)

    def test_the_hourly_cleanup_gets_past_a_song_it_cannot_read(self):
        self.prepared()
        self.link()
        unreadable = '0' * 31 + '1'
        self.items[unreadable] = {**self.items[SONG], 'Id': unreadable}
        with self.hub.store.connect() as db:
            db.execute("INSERT INTO links VALUES(?,?,?,?,?,?,?,?,?,?,0,?)", ('0' * 32, OWNER, unreadable, 'vocals',
                VERSION, 0, 'mp3', 'x.mp3', time.time(), time.time() + 600, self.tags()))
        def answer(method, path, **kwargs):
            if unreadable in path:
                raise HTTPException(404, 'The server cannot read this music file')
            return {'state': 'ready', 'revision': NEWER}
        self.hub.karaoke = Mock(side_effect=answer)
        with patch('hub_exports.random.shuffle', side_effect=lambda groups: groups.sort(key=lambda g: g[0]['song'])):
            self.hub.exports.prune()
        with self.hub.store.connect() as db:
            self.assertEqual([row[0] for row in db.execute('SELECT song FROM links')], [unreadable],
                "the song's ended link after it is dropped all the same")

    def test_the_hourly_cleanup_gets_past_a_link_jellyfin_fails_on(self):
        self.prepared()
        self.link()
        failing = '0' * 31 + '1'
        with self.hub.store.connect() as db:
            db.execute("INSERT INTO links VALUES(?,?,?,?,?,?,?,?,?,?,0,?)", ('0' * 32, OWNER, failing, 'vocals',
                VERSION, 0, 'mp3', 'x.mp3', time.time(), time.time() + 600, self.tags()))
        def item(owner, value, **kwargs):
            if value == failing:
                raise HTTPException(502, 'Jellyfin could not complete this request')
            return self.items[value]
        self.jf.item.side_effect = item
        self.revision = NEWER
        # The failing song first.
        with patch('hub_exports.random.shuffle', side_effect=lambda groups: groups.sort(key=lambda g: g[0]['song'])):
            self.hub.exports.prune()
        with self.hub.store.connect() as db:
            self.assertEqual([row[0] for row in db.execute('SELECT song FROM links')], [failing])

    def test_making_a_link_with_slow_servers_answers_in_time(self):
        self.prepared()
        with self.hub.store.connect() as db:
            for index in range(1, 9):
                song = f'{index:032x}'
                self.items[song] = {**self.items[SONG], 'Id': song}
                db.execute("INSERT INTO links VALUES(?,?,?,?,?,?,?,?,?,?,0,?)", (song, OWNER, song, 'vocals',
                    VERSION, 0, 'mp3', 'x.mp3', time.time(), time.time() + 600, self.tags()))
        budgets = []
        def slow_item(owner, value, timeout=None):
            budgets.append(sum(timeout))
            time.sleep(0.25)
            return self.items[value]
        self.jf.item.side_effect = slow_item
        with patch('hub_exports.LINK_SECONDS', 1.5):
            started = time.monotonic()
            made = self.link()
            elapsed = time.monotonic() - started
        self.assertEqual(made.status_code, 200, made.text)
        self.assertLess(elapsed, 2.2)
        # Each question gets only the time left, connecting and answering together.
        self.assertTrue(all(later < earlier for earlier, later in zip(budgets, budgets[1:])), budgets)
        self.assertLessEqual(budgets[0], 1.5)

    def test_a_file_taken_by_the_cleanup_just_then_is_converted_again(self):
        self.prepared()

        def taken(path, *args):
            # The cleanup removing it after it was looked at, just before it's touched.
            os.unlink(path)
            raise FileNotFoundError(path)
        with patch('hub_exports.os.utime', side_effect=taken):
            self.assertEqual(self.status()['state'], 'missing')
        self.assertFalse(self.exported().exists())
        self.assertEqual(self.ask().json()['state'], 'preparing')
        self.assertTrue(self.hub.jobs.run_one())
        self.assertTrue(self.exported().is_file(), 'converted again')
        self.assertEqual(self.status()['state'], 'ready')

    def test_a_shared_link_asks_jellyfin_and_the_karaoke_server_briefly(self):
        self.prepared()
        made = self.link().json()
        self.jf.item.reset_mock()
        self.hub.karaoke.reset_mock()
        self.assertEqual(self.fetch(made['url']).status_code, 200)
        for asked in (self.jf.item, self.hub.karaoke):
            connect, read = asked.call_args.kwargs['timeout']
            self.assertLessEqual(connect, 2)
            self.assertLessEqual(connect + read, 10)

    def test_the_hourly_cleanup_drops_ended_links_so_their_files_can_go(self):
        self.prepared()
        self.link()
        old = time.time() - (KEEP_DAYS + 1) * 86400
        os.utime(self.exported(), (old, old))
        self.revision = NEWER
        self.assertEqual(self.hub.exports.prune(), 1)
        self.assertFalse(self.exported().exists())
        with self.hub.store.connect() as db:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM links').fetchone()[0], 0)

    def test_a_dead_link_used_before_any_listing_is_dropped(self):
        self.prepared()
        made = self.link().json()
        self.revision = NEWER
        self.assertEqual(self.fetch(made['url']).status_code, 410)
        self.revision = VERSION
        with self.hub.store.connect() as db:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM links').fetchone()[0], 0)

    def test_a_ready_file_counts_as_used_when_a_ticket_is_handed_out(self):
        self.prepared()
        old = time.time() - (KEEP_DAYS + 1) * 86400
        os.utime(self.exported(), (old, old))
        self.assertEqual(self.status()['state'], 'ready')
        self.assertEqual(self.hub.exports.prune(), 0)
        self.assertTrue(self.exported().exists())

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
        # A link made while the cleanup was deciding: it goes with the mix, and the same song prepared again (same
        # revision) doesn't bring it back.
        made = self.link().json()
        exports.remove_for(VERSION)
        self.assertEqual(list(exports.folder.iterdir()), [])
        self.prepared('mp3')
        self.assertEqual(self.fetch(made['url']).status_code, 410)
        self.assertEqual(self.api('GET', '/karaoke/links').json()['links'], [])

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
