#!/usr/bin/env node
// candor install / usage tracker — pulls the public download trails on demand:
//   • crates.io  — every candor-* crate (the Rust engine workspace); verified by repository
//   • GitHub     — release-asset downloads for the engine repos (the JVM jars jbang fetches)
// No auth needed for either. Clone traffic (a proxy for `cargo install --git` / source
// builds, which leave no download) needs a GITHUB_TOKEN with push access — set it to include it.
//
// usage:  node installs.mjs

const UA = 'candor-installs (tom@poly.io)';
const OWNER = 'tombaldwin';
const ENGINE_REPOS = ['candor-rust', 'candor-java', 'candor-ts', 'candor-swift'];

const getJSON = async (url, headers) => {
  const r = await fetch(url, { headers: { 'User-Agent': UA, ...(headers || {}) } });
  if (!r.ok) throw new Error(url + ' -> HTTP ' + r.status);
  return r.json();
};

// every candor-* crate whose repository points back at one of Tom's candor repos
async function cratesIo() {
  const names = new Set();
  for (let page = 1; page <= 3; page++) {
    const res = await getJSON(`https://crates.io/api/v1/crates?q=candor&per_page=100&page=${page}`);
    const cs = res.crates || [];
    cs.forEach((c) => { if (/^candor/i.test(c.name)) names.add(c.name); });
    if (cs.length < 100) break;
  }
  const out = [];
  for (const name of names) {
    try {
      const d = await getJSON(`https://crates.io/api/v1/crates/${name}`);
      const repo = (d.crate.repository || '').toLowerCase();
      if (!repo.includes('tombaldwin') && !repo.includes('/candor')) continue; // skip any third-party "candor*"
      out.push({ name, downloads: d.crate.downloads, recent: d.crate.recent_downloads || 0 });
    } catch (e) { /* skip a crate that won't resolve */ }
  }
  return out.sort((a, b) => b.downloads - a.downloads);
}

async function gitHub() {
  const headers = {};
  const tok = process.env.GITHUB_TOKEN || process.env.GH_TOKEN;
  if (tok) headers.Authorization = 'Bearer ' + tok;
  const out = [];
  for (const repo of ENGINE_REPOS) {
    try {
      const rels = await getJSON(`https://api.github.com/repos/${OWNER}/${repo}/releases?per_page=100`, headers);
      if (!Array.isArray(rels)) { out.push({ repo, note: rels.message || 'no releases' }); continue; }
      let dl = 0, assets = 0;
      rels.forEach((r) => (r.assets || []).forEach((a) => { dl += a.download_count; assets++; }));
      let clones = null;
      if (tok) { try { const t = await getJSON(`https://api.github.com/repos/${OWNER}/${repo}/traffic/clones`, headers); clones = t.count + '/' + t.uniques + 'u (14d)'; } catch (e) {} }
      out.push({ repo, releases: rels.length, assets, downloads: dl, clones });
    } catch (e) { out.push({ repo, note: String(e.message || e) }); }
  }
  return out;
}

const [cr, gh] = await Promise.all([cratesIo().catch((e) => ({ error: String(e.message || e) })), gitHub()]);

console.log('\ncandor installs — ' + new Date().toISOString().slice(0, 10));
console.log('='.repeat(46));

console.log('\ncrates.io (Rust engine workspace):');
if (cr.error) console.log('  error: ' + cr.error);
else if (!cr.length) console.log('  (no candor crates found)');
else {
  cr.forEach((c) => console.log('  ' + c.name.padEnd(20) + String(c.downloads).padStart(8) + '   (90d: ' + c.recent + ')'));
  const tot = cr.reduce((s, c) => s + c.downloads, 0), rec = cr.reduce((s, c) => s + c.recent, 0);
  console.log('  ' + '─'.repeat(44));
  console.log('  ' + 'TOTAL'.padEnd(20) + String(tot).padStart(8) + '   (90d: ' + rec + ')');
}

console.log('\nGitHub release-asset downloads (JVM jars via jbang, etc.):');
gh.forEach((r) => {
  if (r.note) { console.log('  ' + r.repo.padEnd(14) + r.note); return; }
  console.log('  ' + r.repo.padEnd(14) + String(r.downloads).padStart(5) + ' dls · ' + r.assets + ' assets · ' + r.releases + ' releases' + (r.clones ? ' · clones ' + r.clones : ''));
});
if (!(process.env.GITHUB_TOKEN || process.env.GH_TOKEN)) console.log('  (set GITHUB_TOKEN to also pull clone traffic — the proxy for source/`cargo install --git`)');
console.log('');
