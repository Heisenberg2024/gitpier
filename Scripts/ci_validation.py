#!/usr/bin/env python3
"""Conservative CI routing. Uncertain evidence always requires full validation."""
from dataclasses import dataclass
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
from urllib.parse import urlencode


ROOT = Path(__file__).resolve().parent.parent
WORKFLOW = '.github/workflows/validate.yml'
DOC_FILES = frozenset({
    'README.md', 'README.zh-CN.md', 'CHANGELOG.md', 'CONTRIBUTING.md',
    'SECURITY.md', '.github/pull_request_template.md',
})
FULL_STEPS = (
    'Toolchain', 'Real Git repository tests', 'Release metadata and signing gates',
    'Build application', 'Temporary DMG structure (no Finder visual claim)',
    'Archive development app preserving signatures and permissions',
    'Upload development app', 'Full macOS validation complete (v1)',
)


class EvidenceError(Exception):
    """Missing, ambiguous or incomplete evidence must never skip validation."""


@dataclass(frozen=True)
class Plan:
    mode: str
    reason: str
    base: str = ''
    reused_run: str = ''
    reused_attempt: str = ''


def git(*args, root=ROOT):
    return subprocess.run(
        ['git', '--literal-pathspecs', *args], cwd=root, check=True, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, timeout=30,
    ).stdout


def is_sha(value):
    return isinstance(value, str) and re.fullmatch(r'[0-9a-f]{40}', value) is not None and value != '0' * 40


def is_doc(path):
    # In particular, never ignore all *.md: branding/legal Markdown is packaged.
    parts = PurePosixPath(path).parts
    return (not path.startswith('/') and '..' not in parts and
            (path in DOC_FILES or (path.startswith('docs/') and path.endswith('.md'))))


def changed_paths(base, head, root=ROOT):
    if not is_sha(base) or not is_sha(head):
        raise EvidenceError('Invalid comparison commits')
    # Disable rename detection so both the old and new paths are classified.
    raw = git('diff', '--no-ext-diff', '--no-textconv', '--no-renames',
              '--name-only', '-z', base, head, '--', root=root)
    return [p.decode('utf-8', errors='strict') for p in raw.split(b'\0') if p]


def docs_only(base, head, root=ROOT):
    paths = changed_paths(base, head, root)
    if not paths or not all(is_doc(p) for p in paths):
        return False
    # A symlink, executable or submodule with a Markdown name is not ordinary prose.
    for revision in (base, head):
        entries = git('ls-tree', '-z', revision, '--', *paths, root=root).split(b'\0')
        if any(e and not e.startswith(b'100644 blob ') for e in entries):
            return False
    return True


def comparison_base(event_name, event, head, root=ROOT):
    if event_name == 'push' and event.get('ref', '').startswith('refs/heads/'):
        base = event.get('before')
        if event.get('created') or event.get('deleted') or event.get('forced') or not is_sha(base):
            return None
        # Missing history and non-fast-forward pushes conservatively run everything.
        git('merge-base', '--is-ancestor', base, head, root=root)
        return base
    if event_name == 'pull_request':
        base = event.get('pull_request', {}).get('base', {}).get('sha')
        if is_sha(base):
            return git('merge-base', base, head, root=root).decode().strip()
    return None


def api_get(path):
    result = subprocess.run(
        ['gh', 'api', '--hostname', 'github.com', '-H', 'Accept: application/vnd.github+json', path],
        check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20,
    )
    return json.loads(result.stdout)


def api_items(path, key, get=api_get):
    """Never accept a truncated page as complete proof (bounded to 1,000 items)."""
    items = []
    expected_total = None
    seen = set()
    for page in range(1, 11):
        separator = '&' if '?' in path else '?'
        body = get(f'{path}{separator}per_page=100&page={page}')
        total, batch = body.get('total_count'), body.get(key)
        if type(total) is not int or total < 0 or total > 1000 or not isinstance(batch, list):
            raise EvidenceError('Incomplete API listing')
        if expected_total is not None and total != expected_total:
            raise EvidenceError('API listing changed during pagination')
        expected_total = total
        if len(batch) > 100 or any(not isinstance(item, dict) for item in batch):
            raise EvidenceError('Invalid API item')
        for item in batch:
            item_id = item.get('id')
            if type(item_id) is not int or item_id <= 0 or item_id in seen:
                raise EvidenceError('Invalid or repeated API item')
            seen.add(item_id)
        items.extend(batch)
        if len(items) == total:
            return items
        if not batch or len(items) > total:
            raise EvidenceError('Inconsistent API pagination')
    raise EvidenceError('API pagination limit reached')


def successful_full_job(job, run_id, sha):
    if (job.get('name') != 'build-test' or job.get('run_id') != run_id or
            job.get('head_sha') != sha or job.get('status') != 'completed' or
            job.get('conclusion') != 'success'):
        return False
    steps = job.get('steps')
    if not isinstance(steps, list) or any(not isinstance(s, dict) for s in steps):
        return False
    for name in FULL_STEPS:
        matches = [s for s in steps if s.get('name') == name]
        if len(matches) != 1 or matches[0].get('status') != 'completed' or matches[0].get('conclusion') != 'success':
            return False
    return True


def reusable_run(repo, sha, current_run, tag_names, get=api_get):
    path = f'repos/{repo}/actions/workflows/validate.yml/runs?{urlencode({"head_sha": sha, "event": "push"})}'
    runs = api_items(path, 'workflow_runs', get)
    for run in runs:
        run_id, attempt = run.get('id'), run.get('run_attempt')
        if (type(run_id) is not int or run_id <= 0 or str(run_id) == str(current_run) or
                type(attempt) is not int or attempt <= 0 or run.get('head_sha') != sha or
                run.get('path') != WORKFLOW or run.get('event') != 'push' or
                run.get('head_branch') not in {'main', *tag_names} or
                run.get('repository', {}).get('full_name') != repo or
                run.get('head_repository', {}).get('full_name') != repo or
                run.get('status') != 'completed' or run.get('conclusion') != 'success'):
            continue
        jobs = api_items(f'repos/{repo}/actions/runs/{run_id}/attempts/{attempt}/jobs', 'jobs', get)
        builds = [j for j in jobs if j.get('name') == 'build-test']
        if len(builds) != 1 or not successful_full_job(builds[0], run_id, sha):
            continue
        # A rerun can replace the evidence while the jobs request is in flight.
        latest = get(f'repos/{repo}/actions/runs/{run_id}')
        if any(latest.get(key) != run.get(key) for key in (
                'id', 'run_attempt', 'head_sha', 'path', 'event', 'head_branch',
                'status', 'conclusion')):
            raise EvidenceError('Validation changed during lookup')
        for field in ('repository', 'head_repository'):
            if any(latest.get(field, {}).get(key) != run.get(field, {}).get(key)
                   for key in ('id', 'full_name')):
                raise EvidenceError('Repository identity changed during lookup')
        return Plan('reuse', 'Reusing successful full validation for this exact commit.',
                    reused_run=str(run_id), reused_attempt=str(attempt))
    return None


def select_plan(env, event, root=ROOT, get=api_get):
    event_name, ref, sha = (env.get(k, '') for k in ('GITHUB_EVENT_NAME', 'GITHUB_REF', 'GITHUB_SHA'))
    try:
        if not is_sha(sha) or git('rev-parse', 'HEAD', root=root).decode().strip() != sha:
            raise EvidenceError('Checkout does not match event commit')
        if event_name == 'push' and event.get('ref') != ref:
            raise EvidenceError('Push ref does not match event context')
        if event_name == 'workflow_dispatch' or env.get('GITHUB_RUN_ATTEMPT', '1') != '1':
            return Plan('full', 'Manual runs and reruns always perform full validation.')
        base = comparison_base(event_name, event, sha, root)
        if base and docs_only(base, sha, root):
            return Plan('docs', 'Only allowlisted ordinary documentation changed.', base=base)
        if event_name == 'push' and (ref == 'refs/heads/main' or ref.startswith('refs/tags/')):
            repo = env.get('GITHUB_REPOSITORY', '')
            if (not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repo) or
                    any(part in {'.', '..'} for part in repo.split('/')) or
                    not re.fullmatch(r'[1-9][0-9]*', env.get('GITHUB_RUN_ID', '')) or
                    env.get('GITHUB_SERVER_URL') != 'https://github.com'):
                raise EvidenceError('Unsupported repository context')
            tags = git('tag', '--points-at', sha, root=root).decode('utf-8').splitlines()
            reused = reusable_run(repo, sha, env.get('GITHUB_RUN_ID'), tags, get)
            if reused:
                return reused
        return Plan('full', 'No reusable full validation; running every macOS gate.')
    except (EvidenceError, subprocess.SubprocessError, OSError, UnicodeError,
            ValueError, TypeError, AttributeError, KeyError):
        # Do not echo raw API errors, payloads, credentials or untrusted path text.
        return Plan('full', 'Evidence unavailable or ambiguous; running every macOS gate.')


def check_docs(base, head, root=ROOT):
    if not docs_only(base, head, root):
        raise EvidenceError('Documentation scope changed or could not be verified')
    git('diff', '--no-ext-diff', '--no-textconv', '--check', base, head, '--', root=root)
    for path in changed_paths(base, head, root):
        entries = git('ls-tree', '-z', head, '--', path, root=root)
        if not entries:  # Deleted documentation still participates in diff --check.
            continue
        text = git('show', f'{head}:{path}', root=root).decode('utf-8', errors='strict')
        if '\0' in text or re.search(r'^(?:<{7}|={7}|>{7})(?: |$)', text, flags=re.MULTILINE):
            raise EvidenceError('Documentation contains NUL bytes or unresolved conflict markers')


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in {'plan', 'docs'}:
        raise SystemExit('Usage: ci_validation.py plan|docs')
    if sys.argv[1] == 'docs':
        check_docs(os.environ.get('VALIDATION_BASE', ''), os.environ.get('GITHUB_SHA', ''))
        print('Documentation scope, whitespace, UTF-8 and conflict-marker checks passed.')
        return
    try:
        event = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text())
        plan = select_plan(os.environ, event)
    except (OSError, ValueError, KeyError):
        plan = Plan('full', 'Event unavailable; running every macOS gate.')
    with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
        for key in ('mode', 'base', 'reused_run', 'reused_attempt'):
            output.write(f'{key}={getattr(plan, key)}\n')
    print(f'{plan.mode}: {plan.reason}')
    summary = os.environ.get('GITHUB_STEP_SUMMARY')
    if summary:
        with open(summary, 'a') as output:
            output.write(f'Validation mode: **{plan.mode}**. {plan.reason}\n')


if __name__ == '__main__':
    main()
