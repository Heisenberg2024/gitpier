import assert from 'node:assert/strict'
import { mkdir, readFile, writeFile } from 'node:fs/promises'
import { launch } from '../scripts/browser.mjs'

// Supplemental pixel rehearsal using Stageshow's public ClockControl. Holding
// the scene between screenshots makes each sample exact despite screenshot cost.
const origin = process.argv[2] ?? 'http://127.0.0.1:5178/'
const output = new URL('../.cache/rehearsal-final/', import.meta.url)
const browser = await launch()
const cases = [
  { name: 'stepped-press', width: 390, mark: 'branch-selected', delay: 60, count: 19 },
  { name: 'stepped-seam', width: 1132, mark: 'return-to-workspace', delay: 0, count: 52 },
]
try {
  for (const item of cases) {
    const folder = new URL(`${item.name}-frames/`, output)
    await mkdir(folder, { recursive: true })
    const page = await browser.newPage({ viewport: { width: item.width, height: 780 }, deviceScaleFactor: 2 })
    const errors = []
    page.on('pageerror', error => errors.push(error.message))
    const url = new URL(origin)
    url.searchParams.set('scene', '1')
    url.searchParams.set('paused', '1')
    await page.goto(url.href)
    await page.locator('.ss-stage').waitFor()
    await page.addStyleTag({ content: 'html { background: #101114; }' })
    await page.evaluate(async mark => {
      const clock = window.__stageshow.clock
      await clock.flushLayout()
      for (let frame = 0; frame < 1200; frame++) {
        if (document.querySelector('.ss-stage').dataset.mark === mark) return
        await clock.step(1)
      }
      throw new Error(`The scene never reached ${mark}`)
    }, item.mark)
    await page.evaluate(async delay => { await window.__stageshow.clock.step(delay) }, item.delay)
    const rect = await page.locator('.ss-stage').boundingBox()
    const frames = []
    const images = []
    for (let i = 0; i < item.count; i++) {
      const sample = await page.evaluate(async step => {
        const clock = window.__stageshow.clock
        if (step) await clock.step(4)
        await clock.flushLayout()
        return { time: clock.now(), mark: document.querySelector('.ss-stage').dataset.mark, pressed: [...document.querySelectorAll('[data-pressed]')].map(node => node.dataset.target || node.className), cursor: document.querySelector('.ss-cursor')?.style.transform }
      }, i > 0)
      const path = new URL(`${String(i).padStart(3, '0')}.png`, folder)
      await page.screenshot({ path: path.pathname, clip: rect })
      images.push(`data:image/png;base64,${(await readFile(path)).toString('base64')}`)
      frames.push({ ...sample, screenshot: path.pathname })
    }
    for (let i = 1; i < frames.length; i++) assert.ok(Math.abs(frames[i].time - frames[i - 1].time - 1000 / 15) < .01)
    if (item.name === 'stepped-press') {
      assert.ok(frames.some(frame => frame.pressed.length), 'Press feedback was captured')
      assert.ok(frames.some(frame => frame.mark === 'comparison'), 'The comparison follows the press')
    } else {
      assert.ok(frames.some(frame => frame.mark === 'loop-seam'))
      assert.ok(frames.some(frame => frame.mark === 'select-repository'), 'The following loop begins')
    }
    assert.deepEqual(errors, [])
    const columns = item.width > 600 ? 4 : 5
    const sheet = await browser.newPage({ viewport: { width: columns * (rect.width + 12) + 12, height: 600 }, deviceScaleFactor: 1 })
    await sheet.setContent(`<body style="margin:0;background:#e9e9e9;font:12px system-ui"><div style="display:grid;grid-template-columns:repeat(${columns},${rect.width}px);gap:12px;padding:12px">${images.map((src, i) => `<figure style="position:relative;margin:0"><img src="${src}" style="display:block;width:100%"><figcaption style="position:absolute;top:4px;left:4px;background:#000c;color:white;padding:2px 4px">${((frames[i].time - frames[0].time) / 1000).toFixed(3)}s</figcaption></figure>`).join('')}</div></body>`)
    await sheet.screenshot({ path: new URL(`${item.name}.png`, output).pathname, fullPage: true })
    await writeFile(new URL(`${item.name}.json`, output), JSON.stringify({ status: 'passed', intervalMs: 1000 / 15, frames, errors }, null, 2) + '\n')
    await sheet.close()
    await page.close()
    console.log(`PASS ${item.name}: ${frames.length} exact frames at 66.667ms; press/response and loop cause preserved`)
  }
} finally { await browser.close() }
