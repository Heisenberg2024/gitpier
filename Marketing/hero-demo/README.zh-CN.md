# GitPier 产品演示动画

[English](README.md)

用于 GitPier 官网首页 Hero 的深色 macOS 原生风格产品动画，以 React、普通 CSS 和 Stageshow 实现。桌面设计尺寸 **1100 × 600**；窄容器采用 **358 × 358 的窗口近景**，重新安排内容以保证可读性。单次循环约 **14 秒**。

流程为工作区 Dashboard → 打开仓库 → 自动 Fetch 与远程状态更新 → 选择分支进行比较 → 展示双栏 Diff → 点击 Workspace 返回。当前检出分支始终是 `main`。全部 Git 数据均为本地虚构演示内容，不执行 Git 命令，也不访问真实仓库。

## 本地预览

需要 Node.js 20.19 或更高版本及 npm。

```sh
cd Marketing/hero-demo
npm ci
npm run dev
```

打开[本地预览](http://127.0.0.1:5177/)，支持暂停／播放、重播、桌面／窄屏和英中切换。离屏和文档隐藏时停止播放；系统开启“减少动态效果”时展示完整的分支比较静帧。

- 直接拍摄：[英文](http://127.0.0.1:5177/?capture=gitpier)、[中文](http://127.0.0.1:5177/?capture=gitpier&lang=zh)。
- 嵌入文档：[scene](http://127.0.0.1:5177/?scene=1&lang=en)。
- 成熟示例：[hero-demo](http://127.0.0.1:5177/?capture=hero-gold)、[dark-hero](http://127.0.0.1:5177/?capture=dark-gold)。

## 集成

```sh
npm run build
npm run preview
```

`dist/` 为静态产物，支持子目录部署，可将其内容放在同源的 `/product-film/` 等路径。将 `src/GitPierHero.tsx`、`src/player.css`、`src/copy.ts` 复制到宿主 React 项目；集成时可把 `playback.ts` 中的消息通道常量独立到共享模块。也可直接从此源码包导入组件，宿主构建工具需支持 TSX 与 CSS。

```tsx
import { GitPierHero } from './Marketing/hero-demo/src/GitPierHero'

<GitPierHero src="/product-film/" locale="zh" />
```

组件参数：`src`、`locale`（`en`／`zh`）、`autoPlay`（默认 `true`）、`controls`（默认 `true`）、`compact`（默认 `false`）、`className`。尺寸随容器响应。自动播放时应保留控制按钮。嵌入文档隔离动画时钟，暂停同时冻结脚本、鼠标、CSS 转场与加载图标，不影响宿主页；未修改 Stageshow 的时钟实现。

实际场景为 `src/GitPierScene.tsx`，鼠标测量目标和分镜位于 `src/story.ts`。直接拍摄与 iframe 使用同一个场景。

## 验证

Stageshow 拍摄需要 Google Chrome；可通过 `CHROME_PATH` 指定兼容的 Chromium。验证产物保存在已忽略的 `.cache/`。

```sh
npm run typecheck
npm run build
npm run verify
npm run verify:subpath
node verification/transitions.mjs
node scripts/class-clash.mjs src
node scripts/layout.mjs http://127.0.0.1:5177/ --select .gp-preview --width 390 --strict --report .cache/layout-390.json
FILM_CHILD=1 node scripts/film.mjs 'http://127.0.0.1:5177/?capture=gitpier' --width 1132 --every 1000 --count 17 --gate --out .cache/loop-wide.png --report .cache/loop-wide.json
FILM_CHILD=1 node scripts/film.mjs 'http://127.0.0.1:5177/?capture=gitpier' --width 390 --every 1000 --count 17 --gate --out .cache/loop-compact.png --report .cache/loop-compact.json
FILM_CHILD=1 node scripts/film.mjs 'http://127.0.0.1:5177/?capture=gitpier' --states --states-for 16000 --gate --out .cache/states-wide.png --report .cache/states-wide.json
FILM_CHILD=1 node scripts/film.mjs 'http://127.0.0.1:5177/?capture=gitpier' --at return-to-workspace --every 60 --count 42 --gate --out .cache/seam.png --report .cache/seam.json
```

拍摄时保持源码稳定。最终排演建议使用 5178 端口的生产预览，避免开发热更新。直接拍摄采用固定 60fps 时钟；嵌入预览按真实显示帧间隔推进，由 `verify` 单独检查。构建时将原始 Stageshow CSS 放在 `kit/` 下以保留检查器需要的样式来源，自己编写的 CSS 保留在 `assets/`。门控通过后仍需目视复核；证据与限制见 [REHEARSAL.md](REHEARSAL.md)。这些命令只验证展示动画包，不代表原生 Swift 应用验收。

来源与许可见 [NOTICE.md](NOTICE.md)。运行时不依赖字体下载、远程图片、分析服务或网络 API。
