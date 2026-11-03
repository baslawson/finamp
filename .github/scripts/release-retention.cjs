'use strict';

function publishedReleases(releases) {
  const published = releases.filter((release) => !release.draft);
  for (const release of published) {
    if (!Number.isSafeInteger(release.id) || release.id < 1 ||
        typeof release.tag_name !== 'string' || !release.tag_name ||
        !Number.isFinite(Date.parse(release.published_at))) {
      throw new Error('Invalid published release metadata; nothing deleted');
    }
  }
  return [...new Map(published.map((release) => [release.id, release])).values()]
    .sort((a, b) => Date.parse(b.published_at) - Date.parse(a.published_at) || b.id - a.id);
}

function obsoleteReleases(releases, keep = 5) {
  if (!Number.isSafeInteger(keep) || keep < 1) throw new Error('Keep at least one release');
  return publishedReleases(releases).slice(keep);
}

async function pruneReleases({ github, owner, repo, keep = 5, log = () => {} }) {
  const releases = await github.paginate(github.rest.repos.listReleases, { owner, repo, per_page: 100 });
  const obsolete = obsoleteReleases(releases, keep);
  for (const release of obsolete) {
    try {
      // Deleting the release removes its assets, while keeping its Git tag.
      await github.rest.repos.deleteRelease({ owner, repo, release_id: release.id });
      log(`Removed old release ${release.tag_name}`);
    } catch (error) {
      if (error.status !== 404) throw error;
      log(`Release ${release.tag_name} was already removed`);
    }
  }
  log(`Retained the ${keep} newest published releases; Git tags are unchanged`);
  return obsolete.map((release) => release.tag_name);
}

module.exports = { publishedReleases, obsoleteReleases, pruneReleases };
