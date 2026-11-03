'use strict';

const { execFileSync } = require('node:child_process');
const { publishedReleases } = require('./release-retention.cjs');

function git(cwd, args, options = {}) {
  return execFileSync('git', args, { cwd, encoding: 'utf8', windowsHide: true, ...options });
}

function commit(cwd, sha) {
  const raw = git(cwd, ['cat-file', 'commit', sha]);
  const split = raw.indexOf('\n\n');
  if (split < 0) throw new Error('Invalid commit');
  const headers = raw.slice(0, split).split('\n');
  const field = (name) => headers.find((line) => line.startsWith(name + ' '))?.slice(name.length + 1);
  const identity = (name) => {
    const match = /^(.*) <([^<>]*)> (\d+) ([+-]\d{4})$/.exec(field(name) ?? '');
    if (!match) throw new Error('Invalid commit identity');
    return { name: match[1], email: match[2], date: `@${match[3]} ${match[4]}` };
  };
  return {
    tree: field('tree'), parents: headers.filter((line) => line.startsWith('parent ')).map((line) => line.slice(7)),
    author: identity('author'), committer: identity('committer'), message: raw.slice(split + 2),
  };
}

// Creates replacement objects only. Every retained source tree stays identical,
// and no branch, tag, index or working file changes while preparing the plan.
function createHistoryPlan(cwd, keepTags, head = 'HEAD') {
  if (!keepTags.length || new Set(keepTags).size !== keepTags.length) throw new Error('Unique release tags required');
  const oldHead = git(cwd, ['rev-parse', `${head}^{commit}`]).trim();
  const tags = keepTags.map((name) => ({
    name,
    oldObject: git(cwd, ['rev-parse', `refs/tags/${name}`]).trim(),
    oldCommit: git(cwd, ['rev-parse', `refs/tags/${name}^{commit}`]).trim(),
  }));
  const root = tags[0].oldCommit;
  git(cwd, ['merge-base', '--is-ancestor', root, oldHead]);
  const descendants = git(cwd, ['rev-list', '--reverse', `${root}..${oldHead}`]).trim();
  const chain = [root, ...(descendants ? descendants.split('\n') : [])];
  if (tags.some((tag) => !chain.includes(tag.oldCommit))) throw new Error('Release tags are outside the retained history');
  const commits = [];
  for (const [index, original] of chain.entries()) {
    const data = commit(cwd, original);
    if (index > 0 && (data.parents.length !== 1 || data.parents[0] !== chain[index - 1])) {
      throw new Error('History is not linear; manual review required before rewriting');
    }
    const env = { ...process.env,
      GIT_AUTHOR_NAME: data.author.name, GIT_AUTHOR_EMAIL: data.author.email, GIT_AUTHOR_DATE: data.author.date,
      GIT_COMMITTER_NAME: data.committer.name, GIT_COMMITTER_EMAIL: data.committer.email, GIT_COMMITTER_DATE: data.committer.date,
    };
    const replacement = git(cwd, ['commit-tree', data.tree, ...(index ? ['-p', commits[index - 1].replacement] : [])], {
      input: data.message, env,
    }).trim();
    if (git(cwd, ['rev-parse', `${replacement}^{tree}`]).trim() !== data.tree) throw new Error('Source tree changed');
    commits.push({ original, replacement, tree: data.tree });
  }
  for (const tag of tags) {
    tag.newCommit = commits.find((item) => item.original === tag.oldCommit).replacement;
    const type = git(cwd, ['cat-file', '-t', tag.oldObject]).trim();
    if (type === 'commit') {
      tag.newObject = tag.newCommit;
    } else if (type === 'tag') {
      const raw = git(cwd, ['cat-file', 'tag', tag.oldObject]);
      if (!raw.startsWith(`object ${tag.oldCommit}\n`) || raw.includes('-----BEGIN PGP SIGNATURE-----')) {
        throw new Error('Nested or signed release tag requires manual review');
      }
      tag.newObject = git(cwd, ['mktag'], { input: raw.replace(/^object [a-f0-9]+\n/, `object ${tag.newCommit}\n`) }).trim();
    } else {
      throw new Error('Unexpected release tag type');
    }
  }
  const newHead = commits.at(-1).replacement;
  if (Number(git(cwd, ['rev-list', '--count', newHead]).trim()) !== chain.length) throw new Error('Old ancestry remains');
  return { oldHead, newHead, commits, tags };
}

function publishHistoryPlan(cwd, remote, plan, refs, branch, remove = []) {
  const branchRef = `refs/heads/${branch}`;
  const updates = [ [branchRef, plan.newHead], ...plan.tags.map((tag) => [`refs/tags/${tag.name}`, tag.newObject]),
    ...remove.map((ref) => [ref, '']) ].filter(([ref, sha]) => refs.get(ref) !== sha);
  if (updates.length) {
    const push = ['push', '--atomic', ...updates.map(([ref]) => `--force-with-lease=${ref}:${refs.get(ref)}`), remote,
      ...updates.map(([ref, sha]) => `${sha}:${ref}`)];
    git(cwd, [...push.slice(0, 1), '--dry-run', ...push.slice(1)]);
    git(cwd, push);
  }
  const finalRefs = new Map(git(cwd, ['ls-remote', '--heads', '--tags', remote]).trim().split('\n')
    .filter((line) => line && !line.endsWith('^{}')).map((line) => {
      const [sha, ref] = line.split(/\s+/); return [ref, sha];
    }));
  if (finalRefs.size !== plan.tags.length + 1 || finalRefs.get(branchRef) !== plan.newHead ||
      plan.tags.some((tag) => finalRefs.get(`refs/tags/${tag.name}`) !== tag.newObject)) {
    throw new Error('Remote history verification failed');
  }
}

async function trimReleaseHistory({ github, owner, repo, branch, currentRunId, remote = 'origin',
  cwd = process.cwd(), obsoleteBranches = [], keep = 5, log = () => {} }) {
  if (!Number.isSafeInteger(keep) || keep < 1) throw new Error('Keep at least one release');
  // Let the last active release perform cleanup, so an upcoming release tag
  // cannot be removed while its APK is still being built.
  for (const status of ['in_progress', 'queued', 'waiting', 'requested', 'pending']) {
    const runs = await github.paginate(github.rest.actions.listWorkflowRuns, {
      owner, repo, workflow_id: 'release-plus.yml', status, per_page: 100,
    });
    if (runs.some((run) => run.id !== currentRunId)) {
      log('Another release is active; history cleanup is deferred to its completion');
      return { deferred: true };
    }
  }
  const releases = publishedReleases(await github.paginate(github.rest.repos.listReleases, { owner, repo, per_page: 100 }));
  const keepTags = releases.slice(0, keep).map((release) => release.tag_name).reverse();
  if (!keepTags.length) throw new Error('No published release history to retain');
  const url = git(cwd, ['remote', 'get-url', remote]).trim().replace(/\.git$/, '');
  if (![ `https://github.com/${owner}/${repo}`, `git@github.com:${owner}/${repo}`, `ssh://git@github.com/${owner}/${repo}` ].includes(url)) {
    throw new Error('Remote does not match the requested repository');
  }
  git(cwd, ['check-ref-format', '--branch', branch]);
  const shallow = git(cwd, ['rev-parse', '--is-shallow-repository']).trim() === 'true';
  git(cwd, ['fetch', '--quiet', '--no-recurse-submodules', '--tags', ...(shallow ? ['--unshallow'] : []), remote,
    `+refs/heads/${branch}:refs/remotes/${remote}/${branch}`]);
  const refs = new Map(git(cwd, ['ls-remote', '--heads', '--tags', remote]).trim().split('\n')
    .filter((line) => line && !line.endsWith('^{}')).map((line) => {
      const [sha, ref] = line.split(/\s+/);
      return [ref, sha];
    }));
  const branchRef = `refs/heads/${branch}`;
  const oldHead = refs.get(branchRef);
  if (!oldHead || git(cwd, ['rev-parse', `refs/remotes/${remote}/${branch}`]).trim() !== oldHead) {
    throw new Error('Branch changed during preparation; retry cleanup');
  }
  const plan = createHistoryPlan(cwd, keepTags, oldHead);
  const retainedRefs = new Set(plan.tags.map((tag) => `refs/tags/${tag.name}`));
  const remove = [];
  for (const [ref] of refs) {
    if (ref.startsWith('refs/tags/') && !retainedRefs.has(ref)) remove.push(ref);
    if (ref.startsWith('refs/heads/') && ref !== branchRef) {
      if (!obsoleteBranches.includes(ref.slice(11))) throw new Error(`Other branch retains old history: ${ref}`);
      git(cwd, ['merge-base', '--is-ancestor', refs.get(ref), plan.commits[0].original]);
      remove.push(ref);
    }
  }
  for (const tag of plan.tags) {
    if (refs.get(`refs/tags/${tag.name}`) !== tag.oldObject) throw new Error('Release tag changed during preparation');
  }
  publishHistoryPlan(cwd, remote, plan, refs, branch, remove);
  log(`Retained ${keepTags.join(', ')}; history now starts at ${keepTags[0]} (${plan.commits.length} commits)`);
  return { ...plan, removedRefs: remove };
}

module.exports = { createHistoryPlan, publishHistoryPlan, trimReleaseHistory };
