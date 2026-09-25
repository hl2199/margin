import { build } from 'esbuild';
import { mkdir, copyFile, cp, readFile, readdir, writeFile } from 'node:fs/promises';
await mkdir('dist', { recursive: true });
await build({ entryPoints: ['src/main.js'], bundle: true, outfile: 'dist/app.js', format: 'iife', target: 'safari16', loader: { '.md': 'text', '.woff2': 'file', '.woff': 'file', '.ttf': 'file' }, assetNames: 'fonts/[name]-[hash]', sourcemap: true });
await build({ entryPoints: ['src/mermaid-bundle.js'], bundle: true, outfile: 'dist/mermaid.js', format: 'iife', target: 'safari16', sourcemap: true });
await copyFile('src/index.html', 'dist/index.html');
await copyFile('src/welcome.md', 'dist/welcome.md');
await cp('src/fixtures', 'dist/fixtures', { recursive: true });
const lock = JSON.parse(await readFile('package-lock.json', 'utf8'));
const notices = ['Third-party packages used to build Margin.\n'];
for (const path of Object.keys(lock.packages).filter(Boolean)) {
  let metadata;
  try { metadata = JSON.parse(await readFile(`${path}/package.json`, 'utf8')); }
  catch (error) { if (error.code === 'ENOENT' && lock.packages[path].optional) continue; throw error; }
  notices.push(`\n${'='.repeat(72)}\n${metadata.name} ${metadata.version}\nLicense: ${metadata.license || 'See package license'}\n`);
  for (const filename of await readdir(path)) {
    if (/^(license|copying|notice)(\.|$)/i.test(filename)) {
      try { notices.push(await readFile(`${path}/${filename}`, 'utf8')); } catch { /* Some packages use a license directory. */ }
    }
  }
}
await writeFile('dist/ThirdPartyNotices.txt', notices.join('\n'));
console.log('Built offline editor in dist/');
