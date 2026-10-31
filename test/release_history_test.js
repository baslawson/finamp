const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const { createHistoryPlan, publishHistoryPlan, trimReleaseHistory } = require('../.github/scripts/release-history.cjs');

function git(cwd, ...args) {
  return execFileSync('git', args, { cwd, encoding: 'utf8', windowsHide: true }).trim();
}

function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'finamp-release-history-test-'));
  t.after(() => {
    const resolved = fs.realpathSync(root);
    const temporary = fs.realpathSync(os.tmpdir());
    assert.equal(path.dirname(resolved), temporary);
    assert.ok(path.basename(resolved).startsWith('finamp-release-history-test-'));
    fs.rmSync(resolved, { recursive: true, force: true });
  });
  const cwd = path.join(root, 'source');
  fs.mkdirSync(cwd);
  git(cwd, 'init', '--quiet', '-b', 'library-search');
  git(cwd, 'config', 'user.name', 'Release test');
  git(cwd, 'config', 'user.email', 'release-test@example.invalid');
  for (let version = 0; version < 8; version++) {
    fs.writeFileSync(path.join(cwd, 'music.txt'), `Version ${version}\n`);
    git(cwd, 'add', 'music.txt');
    git(cwd, 'commit', '--quiet', '-m', `Release ${version}`);
    git(cwd, 'tag', '-a', `v${version}`, '-m', `Release tag ${version}`);
  }
  fs.writeFileSync(path.join(cwd, 'pending.txt'), 'Preserve newer work too\n');
  git(cwd, 'add', 'pending.txt');
  git(cwd, 'commit', '--quiet', '-m', 'Pending maintenance');
  const remote = path.join(root, 'remote.git');
  git(cwd, 'clone', '--quiet', '--bare', cwd, remote);
  git(cwd, 'remote', 'add', 'test', remote);
  const refs = new Map(git(cwd, 'ls-remote', '--heads', '--tags', 'test').split('\n')
    .filter((line) => !line.endsWith('^{}')).map((line) => {
      const [sha, ref] = line.split(/\s+/); return [ref, sha];
    }));
  return { cwd, remote, refs, keep: ['v3', 'v4', 'v5', 'v6', 'v7'] };
}

test('rewritten history starts at the oldest retained release and preserves every source tree', (t) => {
  const { cwd, keep } = fixture(t);
  const original = git(cwd, 'rev-parse', 'HEAD');
  const plan = createHistoryPlan(cwd, keep);
  assert.equal(plan.commits.length, 6, 'Five release versions plus newer untagged maintenance');
  assert.equal(git(cwd, 'rev-list', '--count', plan.newHead), '6');
  assert.equal(git(cwd, 'show', '-s', '--format=%P', plan.commits[0].replacement), '');
  for (const item of plan.commits) {
    assert.equal(git(cwd, 'rev-parse', `${item.replacement}^{tree}`), git(cwd, 'rev-parse', `${item.original}^{tree}`));
    assert.equal(git(cwd, 'show', '-s', '--format=%an%n%ae%n%aI%n%cn%n%ce%n%cI%n%B', item.replacement),
      git(cwd, 'show', '-s', '--format=%an%n%ae%n%aI%n%cn%n%ce%n%cI%n%B', item.original));
  }
  assert.equal(git(cwd, 'rev-parse', 'HEAD'), original);
  assert.equal(fs.readFileSync(path.join(cwd, 'pending.txt'), 'utf8'), 'Preserve newer work too\n');
  for (const tag of plan.tags) {
    assert.equal(git(cwd, 'cat-file', 'tag', tag.newObject).split('\n').slice(1).join('\n'),
      git(cwd, 'cat-file', 'tag', tag.oldObject).split('\n').slice(1).join('\n'));
  }
});

test('atomic publication leaves exactly five tags and the rewritten branch', (t) => {
  const { cwd, remote, refs, keep } = fixture(t);
  const plan = createHistoryPlan(cwd, keep);
  const remove = [...refs.keys()].filter((ref) => ref.startsWith('refs/tags/') && !keep.includes(ref.slice(10)));
  publishHistoryPlan(cwd, 'test', plan, refs, 'library-search', remove);
  assert.equal(git(remote, 'rev-list', '--count', 'library-search'), '6');
  assert.deepEqual(git(remote, 'tag', '--list').split('\n'), keep);
  for (const tag of plan.tags) assert.equal(git(remote, 'rev-parse', `${tag.name}^{tree}`), git(cwd, 'rev-parse', `${tag.oldCommit}^{tree}`));
  for (const tag of plan.tags) git(cwd, 'update-ref', `refs/tags/${tag.name}`, tag.newObject, tag.oldObject);
  const repeat = createHistoryPlan(cwd, keep, plan.newHead);
  assert.equal(repeat.newHead, plan.newHead, 'Repeating cleanup does not change commit IDs again');
});

test('a concurrent branch update prevents every tag deletion through atomic leases', (t) => {
  const { cwd, remote, refs, keep } = fixture(t);
  const plan = createHistoryPlan(cwd, keep);
  const remove = [...refs.keys()].filter((ref) => ref.startsWith('refs/tags/') && !keep.includes(ref.slice(10)));
  git(remote, 'update-ref', 'refs/heads/library-search', git(cwd, 'rev-parse', 'v7^{commit}'));
  assert.throws(() => publishHistoryPlan(cwd, 'test', plan, refs, 'library-search', remove));
  for (const [ref, sha] of refs) {
    if (ref.startsWith('refs/tags/')) assert.equal(git(remote, 'rev-parse', ref), sha);
  }
});

test('merge history and unrelated release tags are rejected before modifying refs', (t) => {
  const { cwd, keep } = fixture(t);
  const original = git(cwd, 'rev-parse', 'HEAD');
  const merge = execFileSync('git', ['commit-tree', git(cwd, 'rev-parse', 'HEAD^{tree}'), '-p', original,
    '-p', git(cwd, 'rev-parse', 'v2^{commit}')], { cwd, encoding: 'utf8', input: 'Merge\n' }).trim();
  assert.throws(() => createHistoryPlan(cwd, keep, merge), /not linear/);
  assert.throws(() => createHistoryPlan(cwd, ['v7', 'v3']), /outside/);
  assert.equal(git(cwd, 'rev-parse', 'HEAD'), original);
});

test('an active release defers rewriting before any Git operation can run', async () => {
  const github = { rest: { actions: { listWorkflowRuns: 'runs' } },
    async paginate(method, params) {
      assert.equal(method, 'runs');
      assert.equal(params.workflow_id, 'release-plus.yml');
      return [{ id: 22 }];
    },
  };
  const result = await trimReleaseHistory({ github, owner: 'baslawson', repo: 'finamp', branch: 'library-search',
    currentRunId: 11, cwd: 'path-that-does-not-exist' });
  assert.deepEqual(result, { deferred: true });
});
