import { installVirtualClock, type ClockControl } from '../kit'

export const CHANNEL = 'gitpier-product-film-v1'
export type PlaybackDriver = {
  setPaused(value: boolean): void
  setVisible(value: boolean): void
  announce(): void
  destroy(): void
}

/** Runs only inside the embedded document. Host page timers stay native. */
export function createPlaybackDriver({ capture = false }: { capture?: boolean } = {}): PlaybackDriver | undefined {
  if ((window as unknown as { __stageshow?: { clock?: ClockControl } }).__stageshow?.clock) return
  const raf = window.requestAnimationFrame.bind(window)
  const cancel = window.cancelAnimationFrame.bind(window)
  const motion = window.matchMedia('(prefers-reduced-motion: reduce)')
  let paused = false
  let visible = true
  let frame = 0
  let layoutFrame = 0
  let previous: number | undefined
  let accumulated = 0
  let destroyed = false
  let control: ClockControl
  const active = () => !destroyed && !paused && visible && !document.hidden && !motion.matches
  const announce = () => window.parent.postMessage({ channel: CHANNEL, type: 'state', paused, reduced: motion.matches }, location.origin)
  const queue = () => { if (active() && !frame) frame = raf(tick) }
  const flushLayout = () => {
    if (destroyed || layoutFrame) return
    layoutFrame = raf(async () => {
      layoutFrame = 0
      await control.flushLayout()
      if (control.layoutPending) flushLayout()
    })
  }
  control = installVirtualClock({ fps: 60, onLayout: flushLayout })
  async function tick(timestamp: number) {
    frame = 0
    if (!active()) { previous = undefined; return }
    const elapsed = previous === undefined ? 0 : timestamp - previous
    previous = timestamp
    if (capture) {
      // Rehearsal records every authored 60Hz frame, even if taking a Chrome
      // screenshot delayed the native callback. Live embeds use elapsed time.
      accumulated += elapsed
      const frames = Math.floor(accumulated / (1000 / 60))
      accumulated -= frames * (1000 / 60)
      if (frames) await control.step(frames)
    } else await control.advance(elapsed)
    queue()
  }
  const refresh = () => {
    if (frame) { cancel(frame); frame = 0 }
    previous = undefined
    flushLayout()
    queue()
    announce()
  }
  document.addEventListener('visibilitychange', refresh)
  motion.addEventListener('change', refresh)
  queue()
  flushLayout()
  return {
    setPaused(value) { paused = value; refresh() },
    setVisible(value) { visible = value; refresh() },
    announce,
    destroy() {
      destroyed = true
      cancel(frame)
      cancel(layoutFrame)
      document.removeEventListener('visibilitychange', refresh)
      motion.removeEventListener('change', refresh)
    },
  }
}
