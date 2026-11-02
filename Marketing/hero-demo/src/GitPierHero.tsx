import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { Pause, Play, RotateCcw } from 'lucide-react'
import { copyFor, type Locale } from './copy'
import { CHANNEL } from './playback'
import './player.css'

export type GitPierHeroProps = {
  /** Same-origin URL where this package's dist/ is served. */
  src?: string
  locale?: Locale
  autoPlay?: boolean
  controls?: boolean
  compact?: boolean
  className?: string
}

/** Drop-in React wrapper. The isolated document scopes the animation clock. */
export function GitPierHero({ src = './', locale = 'en', autoPlay = true, controls = true, compact = false, className = '' }: GitPierHeroProps) {
  const c = copyFor(locale)
  const host = useRef<HTMLDivElement>(null)
  const frame = useRef<HTMLIFrameElement>(null)
  const visible = useRef(true)
  const [narrow, setNarrow] = useState(compact)
  const [paused, setPaused] = useState(!autoPlay)
  const [reduced, setReduced] = useState(false)
  const [ready, setReady] = useState(false)
  const url = useMemo(() => {
    const value = new URL(src, typeof location === 'undefined' ? 'http://localhost/' : location.href)
    value.search = ''
    value.hash = ''
    value.searchParams.set('scene', '1')
    value.searchParams.set('lang', locale)
    value.searchParams.set('paused', autoPlay ? '0' : '1')
    return value
  }, [src, locale, autoPlay])
  const send = useCallback((type: string, value?: boolean) => {
    frame.current?.contentWindow?.postMessage({ channel: CHANNEL, type, value }, url.origin)
  }, [url])
  useEffect(() => {
    const element = host.current
    if (!element) return
    const resize = new ResizeObserver(([entry]) => setNarrow(compact || entry.contentRect.width < 800))
    const intersection = new IntersectionObserver(([entry]) => {
      visible.current = entry.isIntersecting
      send('visible', entry.isIntersecting)
    })
    resize.observe(element)
    intersection.observe(element)
    return () => { resize.disconnect(); intersection.disconnect() }
  }, [compact, send])
  useEffect(() => {
    const receive = (event: MessageEvent) => {
      if (event.source !== frame.current?.contentWindow || event.origin !== url.origin || event.data?.channel !== CHANNEL) return
      if (event.data.type === 'ready') {
        setReady(true)
        send('paused', paused)
        send('visible', visible.current)
      }
      if (event.data.type === 'state') setReduced(Boolean(event.data.reduced))
    }
    window.addEventListener('message', receive)
    return () => window.removeEventListener('message', receive)
  }, [paused, send, url.origin])
  useEffect(() => { send('paused', paused) }, [paused, send])
  return <div ref={host} className={`gp-player ${className}`} data-ready={ready}>
    <div className="gp-film-viewport" data-compact={narrow}>
      <iframe ref={frame} src={url.href} title={c.iframeTitle} tabIndex={-1} scrolling="no" />
    </div>
    {controls && <div className="gp-playback-controls">
      <span className="gp-playback-caption">{reduced ? c.reduced : c.loop}</span>
      <div className="gp-playback-buttons">
        <button type="button" onClick={() => setPaused(value => !value)} disabled={reduced} aria-label={paused ? c.play : c.pause} aria-pressed={paused}>
          {paused ? <Play size={14} /> : <Pause size={14} />}<span>{paused ? c.play : c.pause}</span>
        </button>
        <button type="button" onClick={() => { setPaused(false); send('replay') }} disabled={reduced} aria-label={c.replay}><RotateCcw size={14} /><span>{c.replay}</span></button>
      </div>
    </div>}
  </div>
}
