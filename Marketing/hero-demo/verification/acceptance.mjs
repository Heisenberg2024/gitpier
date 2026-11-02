import assert from 'node:assert/strict'
import { mkdir, writeFile } from 'node:fs/promises'
import { launch } from '../scripts/browser.mjs'

const url = process.argv[2] ?? 'http://127.0.0.1:5177/'
const out = new URL('../.cache/', import.meta.url)
await mkdir(out, { recursive: true })
const browser = await launch()
const page = await browser.newPage({ viewport: { width: 1200, height: 960 }, deviceScaleFactor: 1 })
const errors = []
const requests = []
page.on('pageerror', error => errors.push(error.message))
page.on('request', request => { if (new URL(request.url()).origin !== new URL(url).origin) requests.push(request.url()) })
const report = { browser: browser.version(), url, checks: [], errors, externalRequests: requests }
const pass = (name, data) => { report.checks.push({ name, status: 'passed', ...data }); console.log(`PASS ${name}`) }

try {
  await page.goto(url)
  await page.locator('.gp-player[data-ready="true"]').waitFor()
  const scene = page.frames().find(frame => new URL(frame.url()).searchParams.has('scene'))
  assert.ok(scene, 'Embedded React scene loaded')
  await scene.locator('.ss-stage').waitFor()

  const live = await page.evaluate(async () => {
    const child = document.querySelector('iframe').contentWindow
    const samples = []
    const start = performance.now()
    await new Promise(resolve => {
      function take(now) {
        const stage = child.document.querySelector('.ss-stage')
        const cursor = child.document.querySelector('.ss-cursor')
        samples.push({ wall: now, time: child.performance.now(), mark: stage?.dataset.mark, pose: cursor?.style.transform })
        if (now - start < 1800) requestAnimationFrame(take)
        else resolve()
      }
      requestAnimationFrame(take)
    })
    return samples
  })
  const travel = live.filter(item => item.mark === 'select-repository')
  const unique = new Set(travel.map(item => item.pose)).size
  assert.ok(unique > 12, `Cursor has continuous live poses, got ${unique}`)
  const ratio = (live.at(-1).time - live[0].time) / (live.at(-1).wall - live[0].wall)
  assert.ok(ratio > .85 && ratio < 1.15, `Animation follows live elapsed time (${ratio})`)
  const gaps = live.slice(1).map((value, i) => value.wall - live[i].wall).sort((a, b) => a - b)
  pass('Live playback follows the display clock', { uniqueTravelPoses: unique, clockRatio: ratio, medianFrameMs: gaps[Math.floor(gaps.length / 2)], maximumFrameMs: gaps.at(-1) })

  await page.getByRole('button', { name: 'Pause', exact: true }).click()
  await page.waitForTimeout(100)
  const snapshot = () => scene.evaluate(() => ({
    time: window.__stageshow.clock.now(),
    cursor: document.querySelector('.ss-cursor')?.style.transform ?? null,
    animations: document.getAnimations().map(item => item.currentTime),
  }))
  const before = await snapshot()
  await page.waitForTimeout(450)
  assert.deepEqual(await snapshot(), before, 'Pause freezes cursor, story timers and CSS animations')
  pass('Pause freezes the complete animation')
  await page.getByRole('button', { name: 'Play', exact: true }).focus()
  await page.keyboard.press('Enter')
  await page.waitForTimeout(180)
  assert.ok((await snapshot()).time > before.time + 80, 'Keyboard resume advances without a restart')
  pass('Keyboard resume preserves the timeline')

  await page.getByRole('button', { name: 'Replay', exact: true }).click()
  await scene.locator('.gp-dashboard[data-active="true"]').waitFor()
  await page.getByRole('button', { name: 'Pause', exact: true }).click()
  await scene.evaluate(() => {
    window.__filmMarks = []
    new MutationObserver(() => {
      const stage = document.querySelector('.ss-stage')
      const name = stage.dataset.mark
      if (!name || window.__filmMarks.at(-1)?.name === name) return
      const box = element => {
        const r = element.getBoundingClientRect()
        return { x: r.x, y: r.y, right: r.right, bottom: r.bottom }
      }
      const active = document.querySelector('.gp-page[data-active="true"]')
      const targets = [...document.querySelectorAll('[data-target]')].filter(element => {
        const style = getComputedStyle(element)
        return style.visibility === 'visible' && element.getBoundingClientRect().width > 0 && element.dataset.target !== 'rest'
      }).map(element => ({ name: element.dataset.target, ...box(element) }))
      window.__filmMarks.push({ name, time: performance.now(), view: active?.className, currentBranch: document.querySelector('.gp-current-branch').textContent, stage: box(stage), targets, dashboard: document.querySelector('.gp-dashboard').textContent })
    }).observe(document.querySelector('.ss-stage'), { attributes: true, attributeFilter: ['data-mark'] })
  })
  await scene.evaluate(async () => { await window.__stageshow.clock.step(1860) })
  const marks = await scene.evaluate(() => window.__filmMarks)
  const starts = marks.filter(item => item.name === 'select-repository')
  assert.ok(starts.length >= 2, 'Observed at least two loops')
  const durations = starts.slice(1).map((item, i) => item.time - starts[i].time)
  for (const duration of durations) assert.ok(duration >= 12000 && duration <= 15000, `Loop lasts 12–15 seconds: ${duration}`)
  for (const name of ['auto-fetch', 'synced', 'branches', 'branch-selected', 'comparison', 'payoff', 'return-to-workspace', 'loop-seam']) assert.ok(marks.some(item => item.name === name), `Observed ${name}`)
  const seams = marks.filter(item => item.name === 'loop-seam')
  assert.ok(seams.length >= 2)
  assert.equal(seams[0].dashboard, seams[1].dashboard, 'Dashboard data does not rewind or accumulate')
  for (const item of marks.filter(item => ['branch-selected', 'comparison', 'payoff'].includes(item.name))) assert.equal(item.currentBranch.trim(), 'main', 'Comparison never claims a checkout')
  pass('The complete story loops with unchanged dashboard data', { durationMs: durations, marks: marks.map(({ name, time }) => ({ name, time })) })

  await page.setViewportSize({ width: 390, height: 780 })
  await scene.locator('.ss-stage[data-layout="compact"]').waitFor()
  await scene.evaluate(() => { window.__filmMarks.length = 0 })
  await scene.evaluate(async () => { await window.__stageshow.clock.step(960) })
  const compact = await scene.evaluate(() => ({
    marks: window.__filmMarks,
    pageWidth: document.documentElement.scrollWidth,
    viewport: innerWidth,
  }))
  assert.ok(compact.pageWidth <= compact.viewport, 'Compact document has no horizontal page overflow')
  for (const item of compact.marks) for (const target of item.targets) {
    if ((item.name === 'branches' || item.name === 'branch-selected') && ['feature-branch', 'compare'].includes(target.name)) {
      assert.ok(target.x >= item.stage.x && target.right <= item.stage.right + 1, `${target.name} stays in the compact crop horizontally`)
      assert.ok(target.y >= item.stage.y && target.bottom <= item.stage.bottom + 1, `${target.name} stays in the compact crop vertically`)
    }
  }
  assert.ok(compact.marks.some(item => item.name === 'payoff'))
  pass('Responsive resize preserves readable action targets and payoff')

  await page.emulateMedia({ reducedMotion: 'reduce' })
  await scene.locator('.gp-comparison[data-active="true"]').waitFor()
  await page.getByRole('button', { name: 'Play', exact: true }).waitFor({ state: 'visible' })
  assert.ok(await page.getByRole('button', { name: 'Play', exact: true }).isDisabled())
  const reducedBefore = await snapshot()
  await page.waitForTimeout(350)
  assert.deepEqual(await snapshot(), reducedBefore)
  await page.screenshot({ path: new URL('preview-compact.png', out).pathname })
  pass('Reduced motion holds the completed comparison')
  await page.emulateMedia({ reducedMotion: 'no-preference' })

  await page.getByRole('button', { name: 'Play', exact: true }).click()
  await page.evaluate(() => { const spacer = document.createElement('div'); spacer.id = 'acceptance-spacer'; spacer.style.height = '1500px'; document.body.append(spacer); window.scrollTo(0, document.body.scrollHeight) })
  await page.waitForTimeout(180)
  const offscreenBefore = await snapshot()
  await page.waitForTimeout(350)
  assert.equal((await snapshot()).time, offscreenBefore.time)
  await page.evaluate(() => { document.querySelector('#acceptance-spacer').remove(); window.scrollTo(0, 0) })
  await page.waitForTimeout(200)
  assert.ok((await snapshot()).time > offscreenBefore.time)
  pass('Offscreen playback stops and resumes without elapsed-time catch-up')

  const coveringTab = await browser.newPage()
  await coveringTab.bringToFront()
  if (await page.evaluate(() => document.hidden)) {
    await page.waitForTimeout(100)
    const hiddenBefore = await snapshot()
    await page.waitForTimeout(350)
    assert.equal((await snapshot()).time, hiddenBefore.time)
    pass('A hidden browser tab stops the animation clock')
  } else report.checks.push({ name: 'Hidden-tab visibility', status: 'not-exercised', reason: 'This headless browser keeps both tabs visible; offscreen suspension was verified separately.' })
  await coveringTab.close()
  await page.bringToFront()

  await page.setViewportSize({ width: 1200, height: 960 })
  await page.emulateMedia({ reducedMotion: 'reduce' })
  await scene.locator('.ss-stage[data-layout="wide"]').waitFor()
  await scene.locator('.gp-comparison[data-active="true"]').waitFor()
  await page.screenshot({ path: new URL('preview-desktop.png', out).pathname })
  await page.getByRole('button', { name: 'Switch to Simplified Chinese', exact: true }).click()
  await page.getByRole('heading', { name: 'GitPier，流畅呈现。' }).waitFor()
  await scene.getByText('分支比较', { exact: true }).waitFor()
  pass('Simplified Chinese preview and scene stay in sync')
  assert.deepEqual(errors, [])
  assert.deepEqual(requests, [])
  report.status = 'passed'
} catch (error) {
  report.status = 'failed'
  report.failure = error.stack
  await page.screenshot({ path: new URL('acceptance-failure.png', out).pathname }).catch(() => {})
  console.error(error)
  process.exitCode = 1
} finally {
  await writeFile(new URL('acceptance.json', out), JSON.stringify(report, null, 2) + '\n')
  await browser.close()
}
