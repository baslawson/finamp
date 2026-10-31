// Run with: node --test test/party_tv_page_test.js
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const test = require('node:test');

const source = fs.readFileSync(path.join(__dirname, '../lib/services/party_tv.dart'), 'utf8');
const script = source.match(/<script>([\s\S]*?)<\/script>/)[1];

function element() {
  const el = {
    style: {}, className: '', children: [], attributes: {}, onload: null, onerror: null, src: '',
    appendChild: child => (el.children.push(child), child),
    setAttribute: (name, value) => { el.attributes[name] = value; },
    removeAttribute: name => { delete el.attributes[name]; el.src = ''; },
    getBoundingClientRect: () => ({ left: 0, top: 0, width: 100, height: 100 }),
    getContext: () => new Proxy({}, { get: (_, name) => name === 'createRadialGradient' ? () => ({ addColorStop() {} }) : () => {} }),
  };
  let text = '';
  Object.defineProperty(el, 'textContent', {
    get: () => text + el.children.map(child => child.textContent).join(''),
    set: value => { text = String(value); el.children = []; },
  });
  return el;
}

function tvPage({ status = 200 } = {}) {
  const elements = {};
  const sources = [];
  const timers = [];
  class EventSource {
    constructor(url) { this.url = url; this.readyState = 1; this.listeners = {}; sources.push(this); }
    close() { this.readyState = 2; this.closed = true; }
    addEventListener(name, listener) { this.listeners[name] = listener; }
    emit(name, data) { this.listeners[name]({ data: typeof data === 'string' ? data : JSON.stringify(data) }); }
  }
  const sandbox = {
    URLSearchParams, location: { search: '?t=tv key' }, EventSource,
    document: {
      getElementById: id => elements[id] ??= element(),
      createElement: () => element(),
      addEventListener: () => {}, documentElement: {}, body: { className: '' }, hidden: false,
    },
    window: { innerWidth: 1920, innerHeight: 1080, addEventListener: () => {} },
    navigator: {}, performance: { now: () => 0 },
    setTimeout: (callback, ms) => (timers.push({ callback, ms }), 0), clearTimeout: () => {}, requestAnimationFrame: () => 0,
    fetch: async url => {
      assert.equal(url, '/tv?t=tv%20key');
      if (status === 0) throw new Error('offline');
      return { status };
    },
  };
  vm.runInNewContext(script, sandbox);
  return { sandbox, elements, source: sources[0], sources, timers };
}

const song = (id, extra) => ({ id, name: `Song ${id}`, artist: 'Artist', art: true, guest: null, message: null, ...extra });
const state = extra => ({
  qr: { size: 21, path: 'M0 0h7v1h-7z' }, style: 'spectrum', delay: 0, playing: true, bands: true, bpm: null,
  now: song('a'), upNext: [], ballot: [], ...extra,
});

test('the TV page never builds markup from guest text', async () => {
  assert(!script.includes('innerHTML'));
  const { source, elements } = tvPage();
  const name = '<img src=x onerror=bad>';
  source.emit('state', state({ now: song('a', { name }), upNext: [{ name, artist: '<b>', guest: '<i>' }] }));
  assert.equal(elements.title.textContent, name);
  assert.equal(elements.upnext.children[0].textContent, `${name}<b> · for <i>`);
  assert.equal(elements.upnextCard.className, 'card');
  assert.equal(elements.ballotCard.className, 'card hidden');
});

test('the TV tells guests whether they need the host Wi-Fi', () => {
  const { source, elements } = tvPage();
  source.emit('state', state({ anywhere: true }));
  assert.match(elements.scan2.textContent, /any network/);
  source.emit('state', state({ anywhere: false }));
  assert.match(elements.scan2.textContent, /Same Wi-Fi/);
});

test('the feed and cover are asked for with the TV key, and only covers that exist', () => {
  const { source, elements } = tvPage();
  assert.equal(source.url, '/tv/events?t=tv%20key');
  source.emit('state', state({ now: song('a/b') }));
  assert.equal(elements.art.src, '/tv/art?t=tv%20key&id=a%2Fb');
  source.emit('state', state({ now: song('c', { art: false }) }));
  assert.equal(elements.art.src, '');
  assert.equal(elements.qrpath.attributes.d, 'M0 0h7v1h-7z');
  assert.equal(elements.qrsvg.attributes.viewBox, '-2 -2 25 25');
});

test('a guest gets a shout-out when their song starts, not for what was already playing', () => {
  const { source, elements } = tvPage();
  source.emit('state', state({ now: song('a', { guest: 'Sam' }) }));
  assert.equal(elements.toast?.className ?? '', '');
  source.emit('state', state({ now: song('b', { guest: 'Ana', message: 'Happy birthday Tom' }) }));
  assert.equal(elements.toast.className, 'on');
  assert.equal(elements.toastWho.textContent, '🎤 Requested by Ana');
  assert.equal(elements.toastMsg.textContent, '“Happy birthday Tom”');
});

test('band levels wait out the host delay, then rise at once and fall slowly', () => {
  const { sandbox, source } = tvPage();
  assert.deepEqual(Array.from(sandbox.decode('00ff80')).slice(0, 4), [0, 1, 128 / 255, 0]);
  source.emit('state', state({ delay: 200 }));
  sandbox.onBands('ff'.repeat(32), 1000);
  assert(sandbox.advance(1100)[0] < 1);
  assert.equal(sandbox.advance(1200)[0], 1);
  sandbox.onBands('00'.repeat(32), 1210);
  const falling = sandbox.advance(1410)[0];
  assert(falling > 0.5 && falling < 1);
});

test('a quiet or paused phone leaves the TV gently moving instead of frozen', () => {
  const { sandbox, source } = tvPage();
  source.emit('state', state({ playing: false }));
  const idle = Array.from(sandbox.advance(5000));
  assert(idle.every(level => level > 0 && level < 0.2));
  // Playing on a phone that can't measure the music: the TV pulses to the beat instead.
  source.emit('state', state({ bands: false, bpm: 120 }));
  const onBeat = sandbox.advance(10000)[0];
  const offBeat = sandbox.advance(10400)[0];
  assert(onBeat > offBeat);
});

test('the TV says when the party ended, waits for the next one, and spots an old link', async () => {
  const { source, elements } = tvPage({ status: 403 });
  source.emit('state', state());
  source.emit('end', {});
  assert.equal(elements.overlayTitle.textContent, 'The party has ended');
  source.readyState = 0;
  source.onerror();
  assert.equal(elements.overlayTitle.textContent, 'The party has ended');
  source.emit('state', state());
  assert.equal(elements.overlay.className, '');
  source.onerror();
  assert.equal(elements.overlayTitle.textContent, 'Reconnecting…');
  source.readyState = 2;
  source.onerror();
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(elements.overlayTitle.textContent, 'This TV link has expired');
});

test('a TV pushed off by a newer one stays off instead of pushing another off', () => {
  const { source, elements, timers } = tvPage();
  source.emit('state', state());
  source.emit('replaced', {});
  assert.equal(source.closed, true);
  assert.equal(elements.overlayTitle.textContent, "Another screen took this one's place");
  assert(!timers.some(timer => timer.ms === 3000 && timer.callback.name === 'connect'));
});

for (const status of [200, 429, 0]) {
  test(`a refused feed whose link still works (${status || 'no answer'}) is tried again, not called expired`, async () => {
    const { sandbox, source, sources, elements, timers } = tvPage({ status });
    source.readyState = 2;
    source.onerror();
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(elements.overlayTitle.textContent, 'Reconnecting…');
    const retry = timers.find(timer => timer.callback === sandbox.connect);
    retry.callback();
    assert.equal(sources.length, 2);
  });
}

test('the colours come from the cover, ignoring grey', () => {
  const { sandbox } = tvPage();
  const pixels = (r, g, b) => [].concat(...Array.from({ length: 16 }, () => [r, g, b, 255]));
  assert.deepEqual(sandbox.pickPalette(pixels(128, 128, 128)), sandbox.DEFAULT);
  const red = sandbox.pickPalette(pixels(200, 20, 20));
  assert.equal(red.length, 3);
  assert(red[0][0] > red[0][1] * 3);
});
