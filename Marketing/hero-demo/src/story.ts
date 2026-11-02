import type { Act } from '../kit'

export type SceneState = {
  view: 'dashboard' | 'workspace' | 'branches' | 'compare'
  fetch: 'idle' | 'fetching' | 'done'
  selected: boolean
}

export const initial: SceneState = { view: 'dashboard', fetch: 'idle', selected: false }
export const poster: SceneState = { view: 'compare', fetch: 'done', selected: true }

/** Fixture choreography only. Selecting a comparison target never checks it out. */
export async function story(a: Act<SceneState>) {
  await a.wait(700)
  a.mark('select-repository')
  await a.move({ at: 'repository', x: 0.96, y: 0.52 }, { duration: 640 })
  await a.wait(160)
  await a.click()
  await a.set({ view: 'workspace', fetch: 'fetching' })
  a.mark('auto-fetch')
  await a.wait(1400)
  await a.set({ fetch: 'done' })
  a.mark('synced')
  await a.wait(750)

  await a.move({ at: 'branches', x: 0.92, y: 0.6 }, { duration: 700 })
  await a.wait(160)
  await a.click()
  await a.set({ view: 'branches' })
  a.mark('branches')
  await a.wait(600)
  await a.move({ at: 'feature-branch', x: 0.70, y: 0.56 }, { duration: 650 })
  await a.wait(150)
  await a.click()
  await a.set({ selected: true })
  a.mark('branch-selected')
  await a.wait(550)

  await a.move({ at: 'compare', x: 0.94, y: 0.55 }, { duration: 620 })
  await a.wait(160)
  await a.click()
  await a.set({ view: 'compare' })
  a.mark('comparison')
  await a.wait(550)
  await a.move('rest', { duration: 520 })
  a.mark('payoff')
  await a.wait(2250)

  // A real navigation supplies the reset's cause. Repository-only state is
  // reset after its whole surface has left; dashboard sync data never rewinds.
  await a.move({ at: 'workspace', x: 0.94, y: 0.6 }, { duration: 850 })
  await a.wait(160)
  await a.click()
  await a.set({ view: 'dashboard' })
  a.mark('return-to-workspace')
  await a.wait(420)
  await a.snap({ fetch: 'idle', selected: false })
  await a.move('rest', { duration: 720 })
  a.mark('loop-seam')
  await a.wait(650)
}
