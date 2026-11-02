import assert from 'node:assert/strict'
import { createServer } from 'node:http'
import { readFile, writeFile } from 'node:fs/promises'
import { resolve, sep, extname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { launch } from '../scripts/browser.mjs'

const root = fileURLToPath(new URL('../dist/', import.meta.url))
const mime = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.png': 'image/png' }
const server = createServer(async (request, response) => {
  const url = new URL(request.url, 'http://localhost')
  if (!url.pathname.startsWith('/product-film/')) { response.writeHead(404).end(); return }
  const path = resolve(root, url.pathname.slice('/product-film/'.length) || 'index.html')
  if (!path.startsWith(root.endsWith(sep) ? root : root + sep)) { response.writeHead(403).end(); return }
  try { response.writeHead(200, { 'content-type': mime[extname(path)] || 'application/octet-stream' }).end(await readFile(path)) }
  catch { response.writeHead(404).end() }
})
await new Promise(done => server.listen(0, '127.0.0.1', done))
const url = `http://127.0.0.1:${server.address().port}/product-film/`
const browser = await launch()
const page = await browser.newPage({ viewport: { width: 1200, height: 960 }, reducedMotion: 'reduce' })
const failures = []
page.on('pageerror', error => failures.push(error.message))
page.on('response', response => { if (response.status() >= 400) failures.push(`${response.status()} ${response.url()}`) })
try {
  await page.goto(url)
  await page.locator('.gp-player[data-ready="true"]').waitFor()
  const scene = page.frames().find(frame => new URL(frame.url()).searchParams.has('scene'))
  assert.ok(scene.url().includes('/product-film/?scene=1'))
  await scene.locator('.gp-comparison[data-active="true"]').waitFor()
  const styles = await scene.evaluate(() => [...document.styleSheets].map(sheet => sheet.href).filter(Boolean))
  assert.ok(styles.some(path => path.includes('/product-film/kit/stageshow-')), 'Vendor CSS retains its provenance')
  assert.ok(styles.some(path => path.includes('/product-film/assets/index-')), 'Authored CSS remains separately audited')
  assert.ok(await scene.locator('.gp-brand img').evaluate(image => image.complete && image.naturalWidth > 0))
  assert.deepEqual(failures, [])
  await writeFile(new URL('../.cache/subpath.json', import.meta.url), JSON.stringify({ status: 'passed', path: '/product-film/', styles: styles.map(path => new URL(path).pathname), errors: failures }, null, 2) + '\n')
  console.log('PASS production bundle, iframe, icon and both stylesheet owners at /product-film/')
} finally {
  await browser.close()
  await new Promise(done => server.close(done))
}
