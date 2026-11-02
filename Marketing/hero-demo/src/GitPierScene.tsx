import type { CSSProperties, ReactNode } from 'react'
import {
  ArrowDownToLine, ArrowLeftRight, ArrowUpFromLine, Box, Check, CheckCircle2,
  ChevronDown, ChevronRight, Circle, FileCode2, Folder, GitBranch,
  GitCommitHorizontal, GitCompareArrows, History, KeyRound, LayoutGrid,
  PanelLeft, Plus, Search, Settings, Star, Terminal, type LucideIcon,
} from 'lucide-react'
import { Row, Spinner, Stage, States, Window } from '../kit'
import { copyFor, type Copy, type Locale } from './copy'
import { initial, poster, story, type SceneState } from './story'
import './hero.css'

type Glyph = LucideIcon
const Glyph = ({ icon: I, size = 16, className }: { icon: Glyph; size?: number; className?: string }) =>
  <I size={size} strokeWidth={1.65} className={className} />

const REPOSITORIES = [
  { name: 'gitpier', group: 'Personal', branch: 'main', changes: 'modifiedThree', sync: 'upToDate', path: '~/Developer/gitpier' },
  { name: 'design-system', group: 'Personal', branch: 'feature/tokens', changes: 'clean', sync: 'upToDate', path: '~/Developer/design-system' },
  { name: 'api-gateway', group: 'Studio', branch: 'main', changes: 'clean', sync: 'behindTwo', path: '~/Studio/api-gateway' },
  { name: 'documentation', group: 'Studio', branch: 'main', changes: 'clean', sync: 'upToDate', path: '~/Studio/documentation' },
  { name: 'website', group: 'Personal', branch: 'feature/hero', changes: 'modifiedCount', sync: 'ahead', path: '~/Developer/website' },
] as const

const FILES = ['SidebarView.swift', 'WorkspaceStore.swift', 'SidebarViewTests.swift']
const COMMITS = [
  ['a83e9c2', 'Keep selection context'],
  ['7bf240a', 'Refine sidebar spacing'],
  ['32da9f1', 'Test navigation'],
]

export type GitPierSceneProps = { locale?: Locale }

/** Authored product illustration; all repositories and Git results are fixtures. */
export function GitPierScene({ locale = 'en' }: GitPierSceneProps) {
  const c = copyFor(locale)
  return (
    <div role="img" aria-label={c.demoLabel} className="gp-illustration">
      <Stage<SceneState>
        width={1100} height={600} compact={{ below: 800, width: 358, height: 358 }}
        theme="dark" fidelity="realistic" accent="#5b9cf4"
        initial={initial} poster={poster} script={story}
        cursor={{ at: 'rest', style: 'real', idle: false }} className="gp-demo"
        tokens={{
          '--ss-font': '-apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif',
          '--ss-mono': '"SFMono-Regular", Menlo, Consolas, monospace',
          '--ss-canvas': '#222429', '--ss-surface': '#1a1c20',
          '--ss-chrome': '#24262b', '--ss-raised': '#2a2d33',
          '--ss-text-strong': '#ebedf0', '--ss-text': '#c4c7ce',
          '--ss-text-faint': '#969ba6', '--ss-line': '#35383f',
          '--ss-line-faint': '#2b2e34', '--ss-radius-window': '12px',
          '--ss-row-title': '13px', '--ss-row-subtitle': '11px',
          '--ss-row-meta': '12px', '--ss-row-line': '18px',
          '--ss-row-line-2': '16px', '--ss-row-gap': '3px',
        }}
      >
        {(s, _rect, layout) => (
          <>
            <Window
              className="gp-window" lightsSize="large"
              title={layout === 'compact' ? 'GitPier' : undefined}
              sidebar={layout === 'wide' ? <Sidebar s={s} c={c} /> : undefined}
              sidebarWidth={190}
              lead={layout === 'wide' ? <div className="gp-breadcrumb"><Glyph icon={PanelLeft} /><span>GitPier</span><ChevronRight size={12} /><States value={s.view === 'dashboard' ? 'home' : 'repo'} align="start" states={{ home: c.workspace, repo: 'gitpier' }} /></div> : undefined}
              toolbar={<div className="gp-chrome-tools"><Glyph icon={Plus} /><Glyph icon={PanelLeft} /></div>}
              body={{ className: 'gp-window-body' }}
            >
              {layout === 'compact' && <div data-target="workspace" data-cursor="pointer" className="gp-mobile-home" data-hoverable><Glyph icon={LayoutGrid} /><span>{c.workspace}</span></div>}
              <div className="gp-page gp-dashboard" data-active={s.view === 'dashboard'} aria-hidden={s.view !== 'dashboard'}>
                <Dashboard c={c} compact={layout === 'compact'} />
              </div>
              <div className="gp-repo-shell" data-active={s.view !== 'dashboard'} aria-hidden={s.view === 'dashboard'}>
                <RepoHeader s={s} c={c} />
                <div className="gp-tabs">
                  <Tab icon={FileCode2} selected={s.view === 'workspace'}>{c.commit}</Tab>
                  <Tab icon={History}>{c.history}</Tab>
                  <Tab icon={GitBranch} target="branches" selected={s.view === 'branches'}>{c.branches}</Tab>
                  <Tab icon={GitCompareArrows} selected={s.view === 'compare'}>{c.compare}</Tab>
                </div>
                <div className="gp-repo-pages">
                  <div className="gp-page gp-worktree" data-active={s.view === 'workspace'} aria-hidden={s.view !== 'workspace'}><WorkingTree c={c} /></div>
                  <div className="gp-page gp-branches" data-active={s.view === 'branches'} aria-hidden={s.view !== 'branches'}><Branches s={s} c={c} /></div>
                  <div className="gp-page gp-comparison" data-active={s.view === 'compare'} aria-hidden={s.view !== 'compare'}><Comparison c={c} /></div>
                </div>
              </div>
            </Window>
            <span data-target="rest" className="gp-cursor-rest" />
          </>
        )}
      </Stage>
    </div>
  )
}

function Sidebar({ s, c }: { s: SceneState; c: Copy }) {
  return <div className="gp-sidebar">
    <div className="gp-brand"><img src={`${import.meta.env.BASE_URL}gitpier-icon.png`} alt="" /><span>GitPier</span></div>
    <div className="gp-nav-item" data-current={s.view === 'dashboard'} data-target="workspace" data-cursor="pointer"><Glyph icon={LayoutGrid} /><span>{c.workspace}</span></div>
    <div className="gp-find"><Glyph icon={Search} /><span>{c.find}</span><kbd>⌘ K</kbd></div>
    <div className="gp-section-label"><span>{c.organizations}</span><Glyph icon={Plus} size={14} /></div>
    <div className="gp-group"><ChevronDown size={12} /><Glyph icon={Folder} /><span>{c.personal}</span><span className="gp-count">3</span></div>
    {['gitpier', 'design-system', 'website'].map((name, i) => <div key={name} className="gp-nav-repo" data-current={i === 0 && s.view !== 'dashboard'}><Glyph icon={Box} /><span>{name}</span>{i === 0 && <Star size={11} className="gp-star" />}</div>)}
    <div className="gp-group gp-group-second"><ChevronDown size={12} /><Glyph icon={Folder} /><span>Studio</span><span className="gp-count">2</span></div>
    {['api-gateway', 'documentation'].map(name => <div key={name} className="gp-nav-repo"><Glyph icon={Box} /><span>{name}</span></div>)}
    <div className="gp-sidebar-foot"><div><Glyph icon={KeyRound} /><span>{c.credentials}</span></div><div><Glyph icon={Settings} /><span>{c.settings}</span></div></div>
  </div>
}

function Dashboard({ c, compact }: { c: Copy; compact: boolean }) {
  return <>
    <div className="gp-dashboard-head">
      <div><div className="gp-heading">{c.workspace}</div><div className="gp-subheading">{c.workspaceSubtitle}</div></div>
      <div className="gp-dashboard-actions"><span className="gp-native-button">{c.clone}</span><span className="gp-native-button"><Plus size={14} />{c.open}</span></div>
    </div>
    <div className="gp-dashboard-toolbar"><div className="gp-search"><Glyph icon={Search} /><span>{c.search}</span></div><span className="gp-filter"><Glyph icon={ChevronDown} size={12} />{compact ? '5' : c.repositoriesCount}</span></div>
    <div className="gp-filters"><span className="gp-filter-active">{c.all}<b>5</b></span><span>{c.modified}<b>2</b></span><span>{c.behind}<b>1</b></span></div>
    <div className="gp-table-head"><span>{c.repository}</span><span>{c.branch}</span><span>{c.changes}</span><span>{c.sync}</span></div>
    <div className="gp-repository-list">
      {REPOSITORIES.map((repo, i) => <Row key={repo.name} pad={10} className="gp-repository" data-target={i === 0 ? 'repository' : undefined} data-cursor="pointer"
        lead={<Glyph icon={Box} size={20} />}
        title={<span className="gp-repository-name">{repo.name}{i === 0 && <Star size={11} className="gp-star" />}</span>}
        subtitle={compact ? <span className="gp-compact-branch"><GitBranch size={12} />{repo.branch}</span> : repo.path}
        meta={<span className="gp-repository-meta"><span className="gp-repo-branch"><GitBranch size={14} />{repo.branch}</span><span className={repo.changes !== 'clean' ? 'gp-amber gp-changes-cell' : 'gp-changes-cell'}>{c[repo.changes]}</span><span className={`gp-sync-cell ${repo.sync === 'upToDate' ? 'gp-green' : repo.sync === 'behindTwo' ? 'gp-blue' : ''}`}><Glyph icon={repo.sync === 'upToDate' ? CheckCircle2 : repo.sync === 'behindTwo' ? ArrowDownToLine : ArrowUpFromLine} size={14} />{c[repo.sync]}</span><ChevronRight size={14} /></span>}
      />)}
    </div>
    <div className="gp-dashboard-foot"><span>{c.repositoriesCount}<span className="gp-foot-separator">·</span>{c.organizationsCount}</span><span><CheckCircle2 size={14} />{c.fetchEnabled}</span></div>
  </>
}

function RepoHeader({ s, c }: { s: SceneState; c: Copy }) {
  return <div className="gp-repo-header">
    <div className="gp-repo-identity"><Glyph icon={Box} size={24} /><div><div className="gp-repo-title">gitpier<span className="gp-repo-org">{c.personal}</span></div><div className="gp-subheading">~/Developer/gitpier</div></div></div>
    <div className="gp-fetch" data-fetch={s.fetch}>
      <span className="gp-fetch-icon"><span data-on={s.fetch === 'fetching'}><Spinner size={13} /></span><span data-on={s.fetch !== 'fetching'}><Glyph icon={s.fetch === 'done' ? CheckCircle2 : Circle} size={14} /></span></span>
      <States align="start" value={s.fetch} states={{ idle: c.autoFetch, fetching: c.fetching, done: <span className="gp-fetch-finished"><span>{c.upToDate}</span><span className="gp-fetch-freshness">{c.fetched}</span></span> }} />
      <span className="gp-fetch-origin">origin</span>
    </div>
    <span className="gp-current-branch"><GitBranch size={14} />main<ChevronDown size={12} /></span>
  </div>
}

function Tab({ icon, selected, target, children }: { icon: Glyph; selected?: boolean; target?: string; children: ReactNode }) {
  return <div className="gp-tab" data-current={selected} data-target={target} data-cursor="pointer"><Glyph icon={icon} /><span>{children}</span></div>
}

function WorkingTree({ c }: { c: Copy }) {
  return <div className="gp-editor-layout">
    <aside className="gp-files-pane">
      <div className="gp-pane-label">{c.unstaged}<span>2</span></div>
      {FILES.slice(0, 2).map((file, i) => <Row key={file} pad={12} className="gp-file" selected={i === 0} lead={<Glyph icon={FileCode2} />} title={file} meta={<span className="gp-amber">M</span>} />)}
      <div className="gp-pane-label gp-staged-label">{c.staged}</div>
      <Row pad={12} className="gp-file" lead={<Glyph icon={FileCode2} />} title="Theme.swift" meta={<span className="gp-green">A</span>} />
      <div className="gp-commit-composer"><div>{c.commitPlaceholder}</div><span className="gp-native-button">{c.commitAction}</span></div>
    </aside>
    <div className="gp-worktree-diff"><div className="gp-file-bar"><FileCode2 size={14} /><span>SidebarView.swift</span><span className="gp-diff-total"><b>+8</b><i>−3</i></span></div><Diff c={c} working /></div>
    <div className="gp-worktree-status"><span><GitBranch size={13} />main</span><span className="gp-green"><CheckCircle2 size={13} />{c.upToDate}</span><span><Terminal size={13} />zsh</span></div>
  </div>
}

function Branches({ s, c }: { s: SceneState; c: Copy }) {
  const rows = [
    ['main', 'origin/main', c.upToDate, true],
    ['feature/sidebar', 'origin/feature/sidebar', c.ahead, false],
    ['fix/keyboard-focus', 'origin/fix/keyboard-focus', c.upToDate, false],
    ['release/2.0', 'origin/release/2.0', c.upToDate, false],
  ] as const
  return <>
    <div className="gp-branch-heading"><div><div className="gp-view-heading">{c.localBranches}<span>4</span></div><div className="gp-subheading">{c.branchSubtitle}</div></div><div className="gp-native-button gp-compare-button" data-target="compare" data-cursor="pointer" data-enabled={s.selected}><GitCompareArrows size={14} /><span className="gp-compare-long">{c.compareWithMain}</span><span className="gp-compare-short">{c.compare}</span></div></div>
    <div className="gp-branch-list">{rows.map(([name, upstream, sync, current], i) => <Row key={name} pad={10} className="gp-branch-row" selected={i === 1 && s.selected} data-target={i === 1 ? 'feature-branch' : undefined} data-cursor="pointer"
      lead={<Glyph icon={current ? CheckCircle2 : GitBranch} className={current ? 'gp-mint' : ''} />}
      title={<span className="gp-branch-name">{name}{current && <span className="gp-current-label">{c.current}</span>}</span>}
      subtitle={upstream} meta={<span className={`gp-branch-health ${i === 1 ? '' : 'gp-green'}`}><Glyph icon={i === 1 ? ArrowUpFromLine : CheckCircle2} size={14} /><span>{sync}</span></span>}
    />)}</div>
    <div className="gp-selection-hint"><States align="start" value={s.selected ? 'selected' : 'hint'} states={{ hint: c.branchHint, selected: c.selectedHint }} /></div>
    <div className="gp-remote-heading"><ChevronDown size={12} /><span>{c.remoteBranches}</span><span>origin</span></div>
    {['origin/main', 'origin/feature/sidebar'].map(name => <Row key={name} pad={12} className="gp-remote-row" lead={<Glyph icon={GitBranch} />} title={name} meta={<span className="gp-remote-hash">{name.endsWith('/main') ? '2e84f0a' : 'a83e9c2'}</span>} />)}
  </>
}

function Comparison({ c }: { c: Copy }) {
  return <>
    <div className="gp-comparison-heading"><div className="gp-view-heading">{c.branchComparison}</div><span className="gp-comparison-mode">{c.mergeBase}</span></div>
    <div className="gp-comparison-refs"><span><GitBranch size={14} />main</span><ArrowLeftRight size={16} /><span className="gp-feature-ref"><GitBranch size={14} />feature/sidebar</span><span className="gp-comparison-count">{c.commitsCount}</span></div>
    <div className="gp-commit-summary"><div className="gp-main-summary"><CheckCircle2 size={14} /><span>{c.noUnique}</span></div><div><GitCommitHorizontal size={14} /><span>{c.uniqueCommits}</span></div></div>
    <div className="gp-comparison-content">
      <aside className="gp-comparison-side"><div className="gp-pane-label">{c.changedFiles}<span className="gp-diff-total"><b>+42</b><i>−12</i></span></div>{FILES.map((name, i) => <Row key={name} pad={12} className="gp-file" selected={i === 0} lead={<Glyph icon={FileCode2} />} title={name} meta={<span className="gp-amber">M</span>} />)}
        <div className="gp-pane-label gp-commit-label">feature/sidebar</div>{COMMITS.map(([hash, title]) => <Row key={hash} pad={8} className="gp-commit-row" lead={<Glyph icon={GitCommitHorizontal} />} title={title} meta={hash} />)}
      </aside>
      <div className="gp-result-diff"><div className="gp-file-bar"><FileCode2 size={14} /><span>SidebarView.swift</span><span className="gp-diff-total"><b>+18</b><i>−6</i></span></div><Diff c={c} /></div>
    </div>
  </>
}

const CODE = [
  ['context', 'struct SidebarView: View {', 'struct SidebarView: View {'],
  ['context', '  var body: some View {', '  var body: some View {'],
  ['context', '    VStack(spacing: 0) {', '    VStack(spacing: 0) {'],
  ['removed', '      repositoryList', '      ScrollView {'],
  ['added', '        .padding(.horizontal, 8)', '        repositoryList'],
  ['added', '        .padding(.vertical, 4)', '          .padding(.horizontal, 12)'],
  ['added', '', '          .padding(.vertical, 8)'],
  ['added', '', '      }'],
  ['added', '', '      .scrollIndicators(.hidden)'],
  ['context', '      Spacer(minLength: 0)', '      Spacer(minLength: 0)'],
  ['context', '      workspaceControls', '      workspaceControls'],
  ['context', '    }', '    }'],
  ['context', '    .background(Theme.sidebar)', '    .background(Theme.sidebar)'],
  ['context', '  }', '  }'],
  ['context', '}', '}'],
] as const

function CodeText({ value }: { value: string }) {
  const parts = value.split(/(struct|var|some|View|VStack|ScrollView|Spacer|@EnvironmentObject|\.padding|\.scrollIndicators|\.background)/g)
  return <>{parts.map((text, i) => <span key={i} className={/^(struct|var|some|@)/.test(text) ? 'gp-code-keyword' : /^(View|VStack|ScrollView|Spacer)$/.test(text) ? 'gp-code-type' : text.startsWith('.') ? 'gp-code-method' : undefined}>{text || '\u00a0'}</span>)}</>
}

function Diff({ c, working = false }: { c: Copy; working?: boolean }) {
  return <div className="gp-diff" data-working={working}>
    {[0, 1].map(side => <div key={side} className={`gp-diff-pane gp-diff-pane-${side}`}>
      <div className="gp-diff-pane-heading"><span>{side === 0 ? 'main' : working ? c.workingCopy : 'feature/sidebar'}</span><span>{side === 0 ? '2e84f0a' : working ? c.right : 'a83e9c2'}</span></div>
      <div className="gp-hunk-header">@@ −24,11 +24,15 @@</div>
      <div className="gp-code-lines">{CODE.map(([kind, old, next], i) => <div key={i} className="gp-code-line" data-kind={kind === 'context' ? 'context' : side === 0 ? old ? 'removed' : 'empty' : 'added'} style={{ '--line': i } as CSSProperties}><span className="gp-line-number">{side === 0 && !old ? '' : 24 + i}</span><span className="gp-line-mark">{kind === 'context' ? ' ' : side === 0 ? old ? '−' : '' : '+'}</span><code><CodeText value={side === 0 ? old : next} /></code></div>)}</div>
    </div>)}
  </div>
}
