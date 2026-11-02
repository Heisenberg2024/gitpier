import { useEffect, useState } from 'react'
import { createRoot } from 'react-dom/client'
import HeroGold from '../reference/hero-demo'
import DarkGold from '../reference/dark-hero'
import { GitPierScene } from './GitPierScene'
import { GitPierHero } from './GitPierHero'
import { CHANNEL, createPlaybackDriver } from './playback'
import { copyFor, type Locale } from './copy'
import './preview.css'

const params = new URLSearchParams(location.search)
const initialLocale: Locale = params.get('lang') === 'zh' ? 'zh' : 'en'
const embedded = params.has('scene')
const capture = params.has('capture')
const playback = embedded || params.get('capture') === 'gitpier'
  ? createPlaybackDriver({ capture: !embedded }) : undefined
if (embedded) {
  document.documentElement.dataset.scene = ''
  playback?.setPaused(params.get('paused') === '1')
}

function EmbeddedScene() {
  const [run, setRun] = useState(0)
  useEffect(() => {
    const receive = (event: MessageEvent) => {
      if (event.source !== parent || event.origin !== location.origin || event.data?.channel !== CHANNEL) return
      if (event.data.type === 'paused') playback?.setPaused(Boolean(event.data.value))
      if (event.data.type === 'visible') playback?.setVisible(Boolean(event.data.value))
      if (event.data.type === 'replay') { setRun(value => value + 1); playback?.setPaused(false) }
    }
    window.addEventListener('message', receive)
    parent.postMessage({ channel: CHANNEL, type: 'ready' }, location.origin)
    playback?.announce()
    return () => window.removeEventListener('message', receive)
  }, [])
  return <GitPierScene key={run} locale={initialLocale} />
}

function Preview() {
  const [locale, setLocale] = useState<Locale>(initialLocale)
  const [compact, setCompact] = useState(false)
  const c = copyFor(locale)
  return <main className="gp-preview">
    <header className="gp-preview-top"><a href="https://github.com/Heisenberg2024/gitpier" className="gp-preview-brand"><img src={`${import.meta.env.BASE_URL}gitpier-icon.png`} alt="" /><span>GitPier</span></a><div className="gp-preview-options">
      <div className="gp-size-switch" role="group" aria-label={locale === 'en' ? 'Preview layout' : '预览布局'}><button type="button" aria-pressed={!compact} onClick={() => setCompact(false)}>{c.desktop}</button><button type="button" aria-pressed={compact} onClick={() => setCompact(true)}>{c.compact}</button></div>
      <button type="button" className="gp-language" aria-label={locale === 'en' ? 'Switch to Simplified Chinese' : '切换为英文'} onClick={() => setLocale(value => value === 'en' ? 'zh' : 'en')}>{locale === 'en' ? '中文' : 'EN'}</button>
    </div></header>
    <div className="gp-preview-intro"><h1>{c.previewTitle}</h1><p>{c.previewSubtitle}</p></div>
    <GitPierHero src={import.meta.env.BASE_URL} locale={locale} compact={compact} />
  </main>
}

createRoot(document.getElementById('root')!).render(
  embedded ? <EmbeddedScene /> : capture ? <div id="example" className="gp-direct-capture">{
    params.get('capture') === 'hero-gold' ? <HeroGold /> : params.get('capture') === 'dark-gold' ? <DarkGold /> : <GitPierScene locale={initialLocale} />
  }</div> : <Preview />,
)
