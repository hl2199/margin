import http from 'node:http';
import { readFile } from 'node:fs/promises';
import { resolve, extname } from 'node:path';
const root = resolve('dist');
const types = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.md': 'text/plain', '.woff2': 'font/woff2', '.svg': 'image/svg+xml' };
http.createServer(async (req, res) => {
  try {
    const file = resolve(root, '.' + decodeURIComponent(req.url.split('?')[0] === '/' ? '/index.html' : req.url.split('?')[0]));
    if (!file.startsWith(root + '/')) throw new Error('Outside root');
    res.setHeader('Content-Type', types[extname(file)] || 'application/octet-stream');
    res.end(await readFile(file));
  } catch { res.statusCode = 404; res.end('Not found'); }
}).listen(4173, '127.0.0.1', () => console.log('Margin preview: http://127.0.0.1:4173'));
