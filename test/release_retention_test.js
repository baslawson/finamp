const { test } = require('node:test');
const assert = require('node:assert/strict');
const { obsoleteReleases, pruneReleases } = require('../.github/scripts/release-retention.cjs');

function release(id, extra = {}) {
  return { id, tag_name: `v1.6.${id}`, draft: false, published_at: new Date(id * 1000).toISOString(), ...extra };
}

test('retains the five newest publication dates regardless of API or version order', () => {
  const releases = [release(3), release(7), release(1), release(6), release(2), release(5), release(4)];
  assert.deepEqual(obsoleteReleases(releases).map((item) => item.id), [2, 1]);
  assert.equal(releases[0].id, 3, 'Does not mutate the original API result');
  assert.deepEqual(obsoleteReleases([release(100), release(1, { published_at: new Date(200000).toISOString() })], 1)
    .map((item) => item.id), [100]);
});

test('drafts are preserved and prereleases count among the five published releases', () => {
  const releases = Array.from({ length: 6 }, (_, index) => release(index + 1));
  releases.push({ id: 8, draft: true, published_at: null });
  releases[5].prerelease = true;
  assert.deepEqual(obsoleteReleases(releases).map((item) => item.id), [1]);
  assert.deepEqual(obsoleteReleases(releases.slice(0, 5)), []);
  assert.deepEqual(obsoleteReleases([]), []);
});

test('duplicate pages and tied timestamps cannot cause repeated deletion', () => {
  const releases = Array.from({ length: 7 }, (_, index) => release(index + 1, { published_at: new Date(1000).toISOString() }));
  releases.push(releases[0]);
  assert.deepEqual(obsoleteReleases(releases).map((item) => item.id), [2, 1]);
});

test('invalid retention or published metadata fails before deleting anything', () => {
  for (const keep of [0, -1, 1.5, NaN, Infinity]) assert.throws(() => obsoleteReleases([], keep));
  for (const extra of [{ id: 0 }, { id: '1' }, { tag_name: '' }, { published_at: null }, { published_at: 'bad' }]) {
    assert.throws(() => obsoleteReleases([release(1, extra)]));
  }
});

function fakeGithub(releases, remove = async () => {}) {
  return {
    rest: { repos: { listReleases: Symbol('listReleases'), deleteRelease: remove } },
    async paginate(method, params) {
      assert.equal(method, this.rest.repos.listReleases);
      assert.deepEqual(params, { owner: 'baslawson', repo: 'finamp', per_page: 100 });
      return releases;
    },
  };
}

test('deletes only obsolete release IDs in the requested repository, preserving tags', async () => {
  const deleted = [];
  const github = fakeGithub(Array.from({ length: 7 }, (_, index) => release(index + 1)), async (params) => deleted.push(params));
  assert.deepEqual(await pruneReleases({ github, owner: 'baslawson', repo: 'finamp' }), ['v1.6.2', 'v1.6.1']);
  assert.deepEqual(deleted, [
    { owner: 'baslawson', repo: 'finamp', release_id: 2 },
    { owner: 'baslawson', repo: 'finamp', release_id: 1 },
  ]);
});

test('tolerates an already removed release but stops on an actual API failure', async () => {
  const deleted = [];
  const releases = Array.from({ length: 7 }, (_, index) => release(index + 1));
  const github = fakeGithub(releases, async (params) => {
    deleted.push(params.release_id);
    if (params.release_id === 2) throw Object.assign(new Error('Already gone'), { status: 404 });
  });
  await pruneReleases({ github, owner: 'baslawson', repo: 'finamp' });
  assert.deepEqual(deleted, [2, 1]);
  deleted.length = 0;
  github.rest.repos.deleteRelease = async (params) => {
    deleted.push(params.release_id);
    throw Object.assign(new Error('Forbidden'), { status: 403 });
  };
  await assert.rejects(pruneReleases({ github, owner: 'baslawson', repo: 'finamp' }), /Forbidden/);
  assert.deepEqual(deleted, [2]);
  github.paginate = async () => [...releases, release(8, { published_at: null })];
  deleted.length = 0;
  await assert.rejects(pruneReleases({ github, owner: 'baslawson', repo: 'finamp' }), /Invalid/);
  assert.deepEqual(deleted, []);
});
