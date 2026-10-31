// Run with: node --test test/hub_tv_page_test.js
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const test = require('node:test');

const script = fs.readFileSync(path.join(__dirname, '../analyzer/hub_web/hub.js'), 'utf8');

function element(tag) {
  const el = {
    tag, style: {}, className: '', children: [], attributes: {}, src: '', paused: true, readyState: 0, currentTime: 0,
    classList: { add() {}, remove() {} },
    append: (...children) => el.children.push(...children),
    replaceChildren: (...children) => { el.children = children; },
    setAttribute: (name, value) => { el.attributes[name] = value; },
    removeAttribute: name => { delete el.attributes[name]; if (name === 'src') el.src = ''; },
    addEventListener() {}, load() {}, pause() { el.paused = true; },
    play: async () => { el.paused = false; },
  };
  let text = '';
  Object.defineProperty(el, 'textContent', {
    get: () => text + el.children.map(child => child.textContent).join(''),
    set: value => { text = String(value); el.children = []; },
  });
  return el;
}

function hubPage(pageName, answers) {
  const elements = {}, timers = [], stored = {}, created = [];
  const sandbox = {
    location: { pathname: `/hub/${pageName}/`, hash: '#room-ticket', origin: 'http://hub.test', assign() {} },
    history: { replaceState() {} },
    sessionStorage: {
      getItem: key => stored[key] ?? null, setItem: (key, value) => { stored[key] = value; },
      removeItem: key => { delete stored[key]; },
    },
    localStorage: { getItem: () => null, setItem() {} },
    document: {
      getElementById: id => elements[id] ??= element('div'),
      createElement: tag => { const made = element(tag); created.push(made); return made; },
      body: { classList: { add() {}, remove() {} } }, documentElement: {},
    },
    window: { addEventListener() {} },
    navigator: {}, crypto: { getRandomValues: bytes => bytes }, encodeURIComponent, decodeURIComponent, AbortController,
    setTimeout: (callback, ms) => (timers.push({ callback, ms }), timers.length), clearTimeout() {},
    fetch: async url => {
      // Lyrics come in on their own schedule; the answers are for everything else, in order.
      const answer = url.includes('/api/room/lyrics') ? { status: 200, body: { song: 's1', lyrics: [], revision: 0 } }
        : answers.shift();
      if (answer instanceof Error) throw answer;
      return { ok: answer.status === 200, status: answer.status, json: async () => answer.body };
    },
  };
  vm.runInNewContext(script, sandbox);
  const polls = ms => timers.filter(timer => timer.ms === ms);
  return { sandbox, elements, timers, polls, stored, created, audio: () => created.find(made => made.tag === 'audio') };
}

const settle = () => new Promise(resolve => setImmediate(resolve));
const playing = { status: 200, body: {
  name: 'Karaoke party', song: { id: 's1', name: 'Bed Of Roses', artist: 'Bon Jovi', durationMs: 393960 },
  message: 'Ready', mediaReady: true, media: '/api/room/media?x=1', mediaKey: 's1:0', playing: true, positionMs: 0,
  commandRev: 1, requests: [], lyricsRevision: 0,
} };
const closed = { status: 404, body: { detail: 'This TV room closed or expired' } };

async function playingTv(answers) {
  const tv = hubPage('tv', [playing, ...answers]);
  await settle();
  const start = tv.created.find(made => made.tag === 'button' && made.textContent === 'Start TV audio');
  start.onclick();
  await settle();
  assert.equal(tv.audio().paused, false);
  return tv;
}

test('a TV whose room was closed stops singing and asks to be connected again', async () => {
  const tv = await playingTv([closed]);
  const polls = tv.polls(1000).length;
  tv.polls(1000).at(-1).callback();
  await settle();
  assert.equal(tv.audio().paused, true);
  assert.equal(tv.audio().src, '');
  assert.equal(tv.polls(1000).length, polls, 'no more polling');
  assert.equal(tv.stored['finamp.hub.tv'], undefined);
  assert.match(tv.elements.app.textContent, /Connect this screen/);
  assert.equal(tv.elements.connection.textContent, 'Room closed');
});

test('a TV that only lost its connection keeps playing and keeps trying', async () => {
  const tv = await playingTv([new Error('Failed to fetch')]);
  const polls = tv.polls(1000).length;
  tv.polls(1000).at(-1).callback();
  await settle();
  assert.equal(tv.audio().paused, false);
  assert.equal(tv.polls(1000).length, polls + 1);
  assert.equal(tv.elements.connection.textContent, 'Reconnecting');
  assert.equal(tv.stored['finamp.hub.tv'], 'room-ticket');
});

test('a phone remote whose room was closed says so and stops polling', async () => {
  const remote = hubPage('remote', [{ status: 200, body: [] }, playing, closed]);
  await settle();
  const polls = remote.polls(1500).length;
  remote.polls(1500).at(-1).callback();
  await settle();
  assert.equal(remote.polls(1500).length, polls);
  assert.match(remote.elements.app.textContent, /This karaoke room was closed/);
});
