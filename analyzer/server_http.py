"""Bounded, account-scoped request sharing and per-thread HTTP connections."""
import copy
import threading
import time
import weakref
from collections import OrderedDict, deque
from concurrent.futures import Future

import requests
from requests.adapters import HTTPAdapter


class HttpPool:
    def __init__(self, factory=requests.Session, clock=time.monotonic):
        self.factory, self.clock = factory, clock
        self.local, self.lock = threading.local(), threading.Lock()
        self.sessions = weakref.WeakSet()
        self.times = deque(maxlen=128)
        self.requests = self.errors = 0

    def request(self, method, url, **kwargs):
        session = getattr(self.local, 'session', None)
        if session is None:
            session = self.factory()
            # Never retry POSTs automatically or retain an account's credentials.
            session.mount('http://', HTTPAdapter(pool_connections=4, pool_maxsize=4, max_retries=0))
            session.mount('https://', HTTPAdapter(pool_connections=4, pool_maxsize=4, max_retries=0))
            self.local.session = session
            with self.lock:
                self.sessions.add(session)
        session.cookies.clear()
        start, failed = self.clock(), True
        try:
            response = session.request(method, url, **kwargs)
            failed = response.status_code >= 500
            return response
        finally:
            session.cookies.clear()
            with self.lock:
                self.requests += 1
                self.errors += int(failed)
                self.times.append(max(0, (self.clock() - start) * 1000))

    def status(self):
        with self.lock:
            values = sorted(self.times)
            return {'requests': self.requests, 'errors': self.errors,
                'recentP95Ms': round(values[min(len(values) - 1, int(len(values) * .95))], 1) if values else None,
                'connections': len(self.sessions)}

    def close(self):
        with self.lock:
            sessions = list(self.sessions)
        for session in sessions:
            session.close()


class ResultCache:
    """Cache only successful metadata, with a bound on both entries and items.

    Callers include the account and complete query in the key. Misses for the
    same key share an in-flight result; unrelated requests never hold the lock.
    """
    def __init__(self, entries=128, items=512, clock=time.monotonic):
        self.maximum_entries, self.maximum_items, self.clock = entries, items, clock
        self.lock, self.values, self.pending = threading.Lock(), OrderedDict(), {}
        self.weight = self.hits = self.misses = self.shared = 0

    def get(self, key, load, seconds=5):
        with self.lock:
            now = self.clock()
            for old in list(self.values):
                if self.values[old][0] <= now:
                    self.weight -= self.values.pop(old)[2]
            cached = self.values.pop(key, None)
            if cached:
                self.values[key] = cached
                self.hits += 1
                return copy.deepcopy(cached[1])
            future = self.pending.get(key)
            if future:
                self.shared += 1
                owner = False
            else:
                future, owner = Future(), True
                self.misses += 1
                # Distinct in-flight queries must not create an unbounded map.
                if len(self.pending) < self.maximum_entries:
                    self.pending[key] = future
        if not owner:
            return copy.deepcopy(future.result(timeout=25))
        try:
            value = load()
            weight = len(value) if isinstance(value, list) else 1
            with self.lock:
                if 0 < weight <= self.maximum_items:
                    previous = self.values.pop(key, None)
                    if previous:
                        self.weight -= previous[2]
                    self.values[key] = (self.clock() + seconds, copy.deepcopy(value), weight)
                    self.weight += weight
                    while len(self.values) > self.maximum_entries or self.weight > self.maximum_items:
                        self.weight -= self.values.popitem(last=False)[1][2]
            future.set_result(value)
            return copy.deepcopy(value)
        except BaseException as error:
            future.set_exception(error)
            raise
        finally:
            with self.lock:
                if self.pending.get(key) is future:
                    del self.pending[key]

    def status(self):
        with self.lock:
            return {'entries': len(self.values), 'items': self.weight,
                'pending': len(self.pending), 'hits': self.hits, 'misses': self.misses, 'shared': self.shared}
