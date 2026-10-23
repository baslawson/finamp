// Run with: node --test test/party_guest_page_test.js
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const test = require('node:test');

function guestPage() {
  const source = fs.readFileSync(path.join(__dirname, '../lib/services/party_service.dart'), 'utf8');
  const script = source.match(/<script>([\s\S]*?)<\/script>/)[1];
  const elements = {};
  const vote = { disabled: false, dataset: { request: 'r' } };
  const failures = { add: false, vote: false };
  const sent = [];
  const state = {
    nowPlaying: null, upNext: [], voting: true,
    ballot: [{ name: '<script>bad</script>', guest: '<img src=x onerror=bad>', votes: 1, voted: false, requestId: 'r' }],
  };
  const sandbox = {
    URLSearchParams, location: { search: '?k=test-key' },
    document: {
      getElementById: id => elements[id] ??= { value: '', style: {}, innerHTML: '', textContent: '' },
      querySelectorAll: selector => selector === '#ballot button' ? [vote] : [],
    },
    localStorage: { getItem: () => '', setItem: () => {} },
    setTimeout: () => 0, clearTimeout: () => {}, setInterval: () => 0,
    fetch: async (url, options) => (options?.body && sent.push(JSON.parse(options.body)), {
      ok: !((url.startsWith('/api/add') && failures.add) || (url.startsWith('/api/vote') && failures.vote)),
      json: async () => url.startsWith('/api/state') ? state : { ok: true, voting: true },
    }),
  };
  vm.runInNewContext(script, sandbox);
  return { sandbox, elements, vote, failures, sent };
}

test('guest names and titles are escaped before rendering', async () => {
  const { sandbox, elements } = guestPage();
  await sandbox.refresh();
  assert(elements.ballot.innerHTML.includes('&lt;script&gt;'));
  assert(!elements.ballot.innerHTML.includes('<img'));
});

test('failed requests and votes stay retryable and successful requests are confirmed', async () => {
  const { sandbox, vote, failures } = guestPage();
  const button = { disabled: false, dataset: { id: 'song' }, textContent: '' };
  failures.add = true;
  await sandbox.add(button);
  assert.equal(button.disabled, false);
  failures.add = false;
  await sandbox.add(button);
  assert.equal(button.disabled, true);
  assert.equal(button.textContent, 'Requested \u2713');
  await sandbox.refresh();
  failures.vote = true;
  await vote.onclick();
  assert.equal(vote.disabled, false);
});

test('a dedication is sent with the request and cleared once it is accepted', async () => {
  const { sandbox, elements, failures, sent } = guestPage();
  elements.msg = { value: 'For Sam, happy birthday!', style: {} };
  const button = { disabled: false, dataset: { id: 'song' }, textContent: '' };
  failures.add = true;
  await sandbox.add(button);
  assert.equal(elements.msg.value, 'For Sam, happy birthday!', 'kept for a retry');
  failures.add = false;
  await sandbox.add(button);
  assert.equal(sent.at(-1).message, 'For Sam, happy birthday!');
  assert.equal(elements.msg.value, '');
});
