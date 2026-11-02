# Provenance

- `kit/` is a dependency-closed subset of the supplied Stageshow kit. Only its export entrypoint is curated; implementation and style files are copied unchanged. The MIT license is included as `kit/LICENSE`.
- `scripts/` contains the supplied Stageshow recording and validation scripts, copied unchanged. Their MIT license is included as `scripts/LICENSE`.
- `reference/hero-demo/` and `reference/dark-hero/` preserve the supplied gold examples for comparison and rehearsal. Stageshow's MIT license applies to their source. Names and marks shown in those examples belong to their respective owners and imply no affiliation.
- `public/gitpier-icon.png` is copied byte-for-byte from this repository's approved `Resources/Branding/gitpier-icon-1024.png`.
- Product content and styling under `src/` depict GitPier, informed by its existing product screenshots and the current native DashboardRepositoryRow, BranchHealth and BranchComparisonView source.
- React, React DOM, Lucide and development dependencies are installed from npm, pinned in `package-lock.json`; their package licenses remain applicable. No third-party fonts, photographs or additional brand artwork are vendored.
