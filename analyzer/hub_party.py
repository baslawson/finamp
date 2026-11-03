"""Party mode for guests away from the host's Wi-Fi. The party itself (voting, approvals, limits, the DJ's shout-outs)
stays on the host's phone: the hub only carries guests' requests to it and its answers back, so a guest on mobile data
reaches the party through the server's public address."""
import collections
import hashlib
import re
import secrets
import threading
import time

from fastapi import HTTPException

# What a guest's page may ask the phone: the same requests its own party page answers.
GUEST_REQUESTS = {('GET', '/api/state'), ('GET', '/api/search'), ('POST', '/api/add'), ('POST', '/api/vote')}


class Parties:
    """Open parties, in memory: a party lasts as long as its phone keeps coming back for guests' requests. After a
    restart the phone opens it again under the same id, so the links guests already have keep working.

    Waiting holds one of the server's shared worker threads, so it is bounded: one phone poll per party, and only so
    many guests waiting at once across all parties. Guests past that are told to try again, instead of the whole hub
    stalling while they wait."""
    answer_seconds = 8
    away_seconds = 45
    most_waiting = 8
    most_waiting_total = 16
    most_parties = 8

    def __init__(self):
        self.changed = threading.Condition()
        self.parties = {}
        self.waiting = 0

    @staticmethod
    def valid(value):
        if not isinstance(value, str) or not re.fullmatch('[A-Za-z0-9_-]{16}', value):
            raise HTTPException(400, 'Invalid party')
        return value

    def open(self, owner, value=None):
        with self.changed:
            if value is None:
                value = secrets.token_urlsafe(12)
            party = self.parties.get(self.valid(value))
            if party is not None and party['owner'] != owner:
                raise HTTPException(403, 'This party belongs to another account')
            if party is None:
                if len(self.parties) >= self.most_parties:
                    # Only a party whose phone went away makes room: ending one still running would have its phone
                    # open it again at once, ending another.
                    now = time.monotonic()
                    stale = [key for key, item in self.parties.items()
                        if not item['polling'] and now - item['seen'] > self.away_seconds]
                    if not stale:
                        raise HTTPException(503, 'Too many parties are running on this server right now')
                    self._end(min(stale, key=lambda key: self.parties[key]['seen']))
                party = self.parties[value] = {'owner': owner, 'inbox': collections.deque(), 'answers': {},
                    # Numbered from a random start, so a late answer from before a restart can't pass for a new one.
                    'next': secrets.randbelow(1 << 48), 'seen': time.monotonic(), 'polling': 0, 'poller': None}
            party['seen'] = time.monotonic()
            return value

    def close(self, owner, value):
        with self.changed:
            party = self.parties.get(self.valid(value))
            if party is not None and party['owner'] == owner:
                self._end(value)

    def _end(self, value):
        self.parties.pop(value, None)
        self.changed.notify_all()

    def _own(self, owner, value):
        party = self.parties.get(self.valid(value))
        if party is None or party['owner'] != owner:
            # The phone opens it again: after a hub restart, or once it was away too long.
            raise HTTPException(404, 'Open the party again')
        return party

    def take(self, owner, value, wait):
        """Guests' requests for the phone, waiting up to [wait] seconds for one to come. A newer poll (the phone
        reconnected while its old one hangs on) takes over, and the old one returns empty at once."""
        deadline = time.monotonic() + max(0, min(wait, 30))
        mine = object()
        with self.changed:
            party = self._own(owner, value)
            party['poller'] = mine
            self.changed.notify_all()
            party['polling'] += 1
            try:
                while not party['inbox'] and self.parties.get(value) is party and party['poller'] is mine:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        break
                    self.changed.wait(remaining)
            finally:
                party['polling'] -= 1
                party['seen'] = time.monotonic()
            self._own(owner, value)
            if party['poller'] is not mine:
                return []
            now = time.monotonic()
            taken = [party['inbox'].popleft() for _ in range(min(20, len(party['inbox'])))]
            # How long the guest still waits for each: past that they were told it failed, so the phone leaves it.
            return [{**{key: item for key, item in message.items() if key != 'deadline'},
                'budget': round(max(0, message['deadline'] - now), 2)} for message in taken]

    def answer(self, owner, value, answers):
        with self.changed:
            party = self._own(owner, value)
            party['seen'] = time.monotonic()
            for item in answers:
                if not isinstance(item, dict) or item.get('id') not in party['answers']:
                    continue
                status, body = item.get('status'), item.get('body')
                if isinstance(status, int) and 200 <= status < 600 and isinstance(body, str) and len(body) <= 256 * 1024:
                    party['answers'][item['id']] = (status, body)
            self.changed.notify_all()

    def ask(self, cap, guest, method, path, query, body):
        """Hands a guest's request to the phone and waits for its answer."""
        if (method, path) not in GUEST_REQUESTS:
            raise HTTPException(404)
        value = cap.get('party')
        with self.changed:
            party = self.parties.get(value) if isinstance(value, str) else None
            if party is None or party['owner'] != cap['owner']:
                raise HTTPException(410, 'This party has ended')
            if not party['polling'] and time.monotonic() - party['seen'] > self.away_seconds:
                raise HTTPException(503, "The host's phone isn't connected right now. Try again in a moment.")
            if len(party['answers']) >= self.most_waiting or self.waiting >= self.most_waiting_total:
                raise HTTPException(503, 'The party is busy. Try again in a moment.')
            ticket = party['next']
            party['next'] += 1
            party['answers'][ticket] = None
            deadline = time.monotonic() + self.answer_seconds
            message = {'id': ticket, 'method': method, 'path': path, 'query': query, 'body': body,
                'guest': 'web:' + hashlib.sha256(f'{value}:{guest}'.encode()).hexdigest()[:16], 'deadline': deadline}
            party['inbox'].append(message)
            self.changed.notify_all()
            self.waiting += 1
            try:
                while party['answers'].get(ticket) is None and self.parties.get(value) is party:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        break
                    self.changed.wait(remaining)
            finally:
                self.waiting -= 1
            answer = party['answers'].pop(ticket, None)
            if answer is None:
                # Not taken yet: it won't be acted on after the guest was told it failed.
                try:
                    party['inbox'].remove(message)
                    taken = False
                except ValueError:
                    taken = True
                if self.parties.get(value) is not party:
                    raise HTTPException(410, 'This party has ended')
                if taken and method == 'POST':
                    # The phone has it, so it may still go through just too late.
                    raise HTTPException(503, "The host's phone was slow to answer. Check Up next before asking again.")
                raise HTTPException(503, "The host's phone didn't answer. Try again in a moment.")
            return answer
