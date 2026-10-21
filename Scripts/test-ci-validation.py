#!/usr/bin/env python3
"""Offline regression tests for CI routing; all Git writes use temporary fixtures."""
import copy
from contextlib import redirect_stdout
import io
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile
import unittest
from unittest import mock
from urllib.parse import parse_qs, urlsplit

import ci_validation as policy


REPOSITORY = 'example/gitpier'
FULL_STEP_NAMES = (
    'Toolchain',
    'Real Git repository tests',
    'Release metadata and signing gates',
    'Build application',
    'Temporary DMG structure (no Finder visual claim)',
    'Archive development app preserving signatures and permissions',
    'Upload development app',
    'Full macOS validation complete (v1)',
)


def completed_run(sha, run_id=123, branch='main', attempt=1):
    return {
        'id': run_id, 'run_attempt': attempt, 'head_sha': sha,
        'path': '.github/workflows/validate.yml', 'event': 'push',
        'head_branch': branch, 'repository': {'id': 10, 'full_name': REPOSITORY},
        'head_repository': {'id': 10, 'full_name': REPOSITORY},
        'status': 'completed', 'conclusion': 'success',
    }


def completed_job(run):
    return {
        'id': 456, 'name': 'build-test', 'run_id': run['id'],
        'head_sha': run['head_sha'], 'status': 'completed', 'conclusion': 'success',
        'steps': [
            {'name': name, 'status': 'completed', 'conclusion': 'success'}
            for name in FULL_STEP_NAMES
        ],
    }


class FakeAPI:
    """Only recognizes expected read paths; never invokes gh or the network."""

    def __init__(self, runs=()):
        self.runs = copy.deepcopy(list(runs))
        self.jobs = {run['id']: [completed_job(run)] for run in self.runs}
        self.latest = {run['id']: copy.deepcopy(run) for run in self.runs}
        self.calls = []

    def __call__(self, path):
        self.calls.append(path)
        parsed = urlsplit(path)
        query = parse_qs(parsed.query)
        if parsed.path == f'repos/{REPOSITORY}/actions/workflows/validate.yml/runs':
            assert query['event'] == ['push']
            return self.page(self.runs, 'workflow_runs', query)
        match = re.fullmatch(
            rf'repos/{REPOSITORY}/actions/runs/(\d+)/attempts/(\d+)/jobs', parsed.path)
        if match:
            run_id, attempt = map(int, match.groups())
            expected = next(run for run in self.runs if run['id'] == run_id)
            assert attempt == expected['run_attempt'], 'Must fetch the exact attempt'
            return self.page(self.jobs[run_id], 'jobs', query)
        match = re.fullmatch(rf'repos/{REPOSITORY}/actions/runs/(\d+)', parsed.path)
        if match:
            return copy.deepcopy(self.latest[int(match.group(1))])
        raise AssertionError(f'Unexpected API request: {path}')

    @staticmethod
    def page(items, key, query):
        assert query['per_page'] == ['100']
        start = (int(query['page'][0]) - 1) * 100
        return {'total_count': len(items), key: copy.deepcopy(items[start:start + 100])}


class RepositoryTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='gitpier-ci-policy-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        empty_config = self.root / 'empty-gitconfig'
        empty_config.write_text('', encoding='utf-8')
        # Do not inherit user identities, signing, hooks, alternate object stores,
        # index files, or Git configuration. No global configuration is written.
        isolated_env = {
            key: value for key, value in os.environ.items()
            if not key.startswith('GIT_')
        }
        isolated_env.update({
            'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': str(empty_config),
            'GIT_AUTHOR_NAME': 'CI Fixture', 'GIT_AUTHOR_EMAIL': 'fixture@example.invalid',
            'GIT_COMMITTER_NAME': 'CI Fixture',
            'GIT_COMMITTER_EMAIL': 'fixture@example.invalid',
            'GIT_TERMINAL_PROMPT': '0',
        })
        patcher = mock.patch.dict(os.environ, isolated_env, clear=True)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.root = self.root / 'repository'
        self.root.mkdir()
        self.git('init', '-q', '-b', 'main')
        self.write('README.md', '# GitPier\n')
        self.write('docs/guide.md', '# Guide\n')
        self.write('Sources/main.swift', 'let value = 1\n')
        self.base = self.commit()
        self.api = FakeAPI()

    def git(self, *args):
        return subprocess.run(
            ['git', *args], cwd=self.root, check=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15,
        ).stdout.decode('utf-8').strip()

    def write(self, path, text):
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        if isinstance(text, bytes):
            target.write_bytes(text)
        else:
            target.write_text(text, encoding='utf-8')
        return target

    def commit(self):
        self.git('add', '--all')
        self.git('commit', '-q', '-m', 'Temporary CI fixture')
        return self.git('rev-parse', 'HEAD')

    def plan(self, *, base=None, event=None, env=None, api=None):
        environment = {
            'GITHUB_EVENT_NAME': 'push', 'GITHUB_REF': 'refs/heads/main',
            'GITHUB_SHA': self.git('rev-parse', 'HEAD'),
            'GITHUB_REPOSITORY': REPOSITORY, 'GITHUB_SERVER_URL': 'https://github.com',
            'GITHUB_RUN_ID': '999', 'GITHUB_RUN_ATTEMPT': '1',
        }
        environment.update(env or {})
        payload = {'ref': environment['GITHUB_REF'], 'before': base or self.base}
        payload.update(event or {})
        return policy.select_plan(environment, payload, self.root, api or self.api)

    def docs_commit(self):
        self.write('README.md', '# GitPier\n\nUpdated documentation.\n')
        return self.commit()

    def code_commit(self):
        self.write('Sources/main.swift', 'let value = 2\n')
        return self.commit()


class DocumentationRoutingTests(RepositoryTests):
    def test_all_commits_in_push_are_compared(self):
        self.docs_commit()
        self.write('docs/guide.md', '# Guide\n\nSecond commit.\n')
        head = self.commit()
        plan = self.plan()
        self.assertEqual((plan.mode, plan.base), ('docs', self.base))
        policy.check_docs(plan.base, head, self.root)
        self.assertEqual(self.api.calls, [])

    def test_earlier_code_change_cannot_hide_behind_final_docs_commit(self):
        self.code_commit()
        self.docs_commit()
        self.assertEqual(self.plan().mode, 'full')

    def test_allowlisted_additions_deletions_and_nested_unicode_docs(self):
        (self.root / 'README.md').unlink()
        self.write('README.zh-CN.md', '# 中文说明\n')
        self.write('CHANGELOG.md', '# Changes\n')
        self.write('CONTRIBUTING.md', '# Contributing\n')
        self.write('SECURITY.md', '# Security\n')
        self.write('.github/pull_request_template.md', 'Describe the change.\n')
        self.write('docs/中文 guide/[draft].md', '# 文档\n')
        head = self.commit()
        self.assertEqual(self.plan().mode, 'docs')
        policy.check_docs(self.base, head, self.root)

    def test_packaged_markdown_code_workflows_and_unknown_paths_require_full(self):
        for path in (
            'Resources/Help.md', 'Resources/Legal/THIRD_PARTY_NOTICES.md',
            'BRANDING.md', 'LICENSE', 'Package.swift',
            'Sources/README.md', 'Scripts/test.sh', '.github/workflows/validate.yml',
            'docs/diagram.svg', 'unlisted.md',
        ):
            with self.subTest(path=path):
                base = self.git('rev-parse', 'HEAD')
                self.write(path, 'Changed input\n')
                self.write('docs/guide.md', f'# Guide\n\nChanged with {path}.\n')
                self.commit()
                self.assertEqual(self.plan(base=base).mode, 'full')

    def test_doc_to_doc_rename_remains_lightweight(self):
        self.git('mv', 'docs/guide.md', 'docs/renamed.md')
        head = self.commit()
        self.assertEqual(self.plan().mode, 'docs')
        policy.check_docs(self.base, head, self.root)

    def test_rename_from_code_to_docs_classifies_deleted_source(self):
        self.git('mv', 'Sources/main.swift', 'docs/source.md')
        self.commit()
        self.assertEqual(self.plan().mode, 'full')

    def test_rename_from_docs_to_packaged_resource_classifies_destination(self):
        (self.root / 'Resources').mkdir()
        self.git('mv', 'docs/guide.md', 'Resources/guide.md')
        self.commit()
        self.assertEqual(self.plan().mode, 'full')

    def test_symlink_with_document_name_requires_full(self):
        (self.root / 'docs/link.md').symlink_to('../Sources/main.swift')
        self.commit()
        self.assertEqual(self.plan().mode, 'full')

    def test_submodule_with_document_name_requires_full(self):
        self.git('update-index', '--add', '--cacheinfo', '160000', self.base, 'docs/module.md')
        self.git('commit', '-q', '-m', 'Temporary submodule fixture')
        self.assertEqual(self.plan().mode, 'full')

    def test_executable_document_and_removing_executable_mode_require_full(self):
        path = self.root / 'docs/guide.md'
        path.chmod(0o755)
        executable = self.commit()
        self.assertEqual(self.plan().mode, 'full')
        path.chmod(0o644)
        self.commit()
        self.assertEqual(self.plan(base=executable).mode, 'full')

    def test_empty_diff_never_counts_as_docs(self):
        self.assertEqual(self.plan().mode, 'full')

    def test_initial_missing_or_force_push_comparison_requires_full(self):
        self.docs_commit()
        for event in (
            {'before': '0' * 40}, {'created': True}, {'deleted': True},
            {'before': 'f' * 40}, {'forced': True},
        ):
            with self.subTest(event=event):
                self.assertEqual(self.plan(event=event).mode, 'full')

    def test_non_ancestor_before_requires_full_even_without_forced_flag(self):
        self.git('switch', '-q', '-c', 'other')
        self.write('docs/guide.md', '# Other branch\n')
        unrelated = self.commit()
        self.git('switch', '-q', 'main')
        self.docs_commit()
        self.assertEqual(self.plan(base=unrelated).mode, 'full')

    def test_pull_request_uses_merge_base_not_stale_head_parent(self):
        self.git('switch', '-q', '-c', 'docs-pr')
        self.docs_commit()
        self.git('switch', '-q', 'main')
        target_base = self.code_commit()
        self.git('merge', '-q', '--no-edit', 'docs-pr')
        plan = self.plan(
            env={'GITHUB_EVENT_NAME': 'pull_request', 'GITHUB_REF': 'refs/pull/1/merge'},
            event={'pull_request': {'base': {'sha': target_base}}},
        )
        self.assertEqual((plan.mode, plan.base), ('docs', target_base))
        self.assertEqual(self.api.calls, [])

    def test_manual_run_and_rerun_of_docs_require_full(self):
        self.docs_commit()
        for env in ({'GITHUB_EVENT_NAME': 'workflow_dispatch'}, {'GITHUB_RUN_ATTEMPT': '2'}):
            with self.subTest(env=env):
                self.assertEqual(self.plan(env=env).mode, 'full')
        self.assertEqual(self.api.calls, [])

    def test_release_tag_of_docs_requires_full_without_full_evidence(self):
        self.docs_commit()
        self.git('tag', 'v1.0.0')
        self.assertEqual(self.plan(env={'GITHUB_REF': 'refs/tags/v1.0.0'}).mode, 'full')

    def test_successful_docs_run_does_not_satisfy_release_tag_validation(self):
        head = self.docs_commit()
        self.git('tag', 'v1.0.0')
        api = FakeAPI([completed_run(head)])
        for step in api.jobs[123][0]['steps']:
            step['conclusion'] = 'skipped'
        api.jobs[123][0]['steps'].append({
            'name': 'Check ordinary documentation', 'status': 'completed',
            'conclusion': 'success',
        })
        self.assertEqual(self.plan(env={'GITHUB_REF': 'refs/tags/v1.0.0'}, api=api).mode, 'full')

    def test_checkout_mismatch_and_invalid_event_sha_require_full(self):
        self.docs_commit()
        for sha in (self.base, 'bad', '0' * 40):
            with self.subTest(sha=sha):
                self.assertEqual(self.plan(env={'GITHUB_SHA': sha}).mode, 'full')

    def test_mismatched_push_ref_cannot_turn_release_into_docs_run(self):
        self.docs_commit()
        self.assertEqual(self.plan(
            env={'GITHUB_REF': 'refs/tags/v1.0.0'},
            event={'ref': 'refs/heads/main'},
        ).mode, 'full')


class DocumentationValidationTests(RepositoryTests):
    def test_bad_document_content_fails_lightweight_check(self):
        for text in (
            b'# Invalid UTF-8\n\xff\n', b'# Binary\n\0\n',
            '# Guide with trailing space \n', '# Guide\n<<<<<<< HEAD\n',
            '# Guide\n=======\n', '# Guide\n>>>>>>> other\n',
        ):
            with self.subTest(text=repr(text)):
                base = self.git('rev-parse', 'HEAD')
                self.write('docs/guide.md', text)
                head = self.commit()
                with self.assertRaises((policy.EvidenceError, UnicodeError, subprocess.SubprocessError)):
                    policy.check_docs(base, head, self.root)

    def test_validation_rechecks_scope_instead_of_trusting_plan(self):
        self.docs_commit()
        plan = self.plan()
        self.assertEqual(plan.mode, 'docs')
        head = self.code_commit()
        with self.assertRaises(policy.EvidenceError):
            policy.check_docs(plan.base, head, self.root)


class ReuseEvidenceTests(RepositoryTests):
    def setUp(self):
        super().setUp()
        self.head = self.code_commit()
        self.run = completed_run(self.head)
        self.api = FakeAPI([self.run])

    def test_tag_reuses_completed_main_full_validation(self):
        self.git('tag', 'v1.0.0')
        plan = self.plan(env={'GITHUB_REF': 'refs/tags/v1.0.0'})
        self.assertEqual((plan.mode, plan.reused_run, plan.reused_attempt), ('reuse', '123', '1'))
        self.assertTrue(any('/attempts/1/jobs?' in call for call in self.api.calls))
        self.assertEqual(self.api.calls[-1], f'repos/{REPOSITORY}/actions/runs/123')

    def test_main_reuses_tag_full_validation_for_exact_same_commit(self):
        self.git('tag', 'v1.0.0')
        api = FakeAPI([completed_run(self.head, branch='v1.0.0')])
        self.assertEqual(self.plan(api=api).mode, 'reuse')

    def test_main_cannot_reuse_tag_pointing_to_different_commit(self):
        self.git('tag', 'v0.9.0', self.base)
        api = FakeAPI([completed_run(self.head, branch='v0.9.0')])
        self.assertEqual(self.plan(api=api).mode, 'full')

    def test_invalid_run_identity_or_non_success_is_not_reused(self):
        changes = (
            {'head_sha': self.base}, {'id': 999}, {'id': True}, {'run_attempt': 0},
            {'path': '.github/workflows/another.yml'}, {'event': 'pull_request'},
            {'event': 'workflow_dispatch'}, {'head_branch': 'feature'},
            {'repository': {'full_name': 'other/gitpier'}},
            {'head_repository': {'full_name': 'fork/gitpier'}},
            {'status': 'in_progress'}, {'conclusion': 'failure'},
            {'conclusion': 'cancelled'}, {'conclusion': 'skipped'},
        )
        for change in changes:
            with self.subTest(change=change):
                run = {**self.run, **change}
                self.assertEqual(self.plan(api=FakeAPI([run])).mode, 'full')

    def test_docs_or_reused_success_without_executed_full_steps_is_not_evidence(self):
        for skipped in (FULL_STEP_NAMES, (FULL_STEP_NAMES[-1],)):
            with self.subTest(skipped=skipped):
                api = FakeAPI([self.run])
                for step in api.jobs[123][0]['steps']:
                    if step['name'] in skipped:
                        step['conclusion'] = 'skipped'
                self.assertEqual(self.plan(api=api).mode, 'full')

    def test_missing_failed_cancelled_or_duplicate_required_step_is_not_evidence(self):
        for name in FULL_STEP_NAMES:
            for kind in ('missing', 'failure', 'cancelled', 'in_progress', 'duplicate'):
                with self.subTest(name=name, kind=kind):
                    api = FakeAPI([self.run])
                    steps = api.jobs[123][0]['steps']
                    step = next(item for item in steps if item['name'] == name)
                    if kind == 'missing':
                        steps.remove(step)
                    elif kind == 'duplicate':
                        steps.append(copy.deepcopy(step))
                    elif kind == 'in_progress':
                        step['status'] = kind
                    else:
                        step['conclusion'] = kind
                    self.assertEqual(self.plan(api=api).mode, 'full')

    def test_wrong_job_identity_or_ambiguous_jobs_is_not_evidence(self):
        for change in (
            {'run_id': 456}, {'head_sha': self.base}, {'status': 'queued'},
            {'conclusion': 'failure'}, {'steps': None}, {'steps': [None]},
        ):
            with self.subTest(change=change):
                api = FakeAPI([self.run])
                api.jobs[123][0].update(change)
                self.assertEqual(self.plan(api=api).mode, 'full')
        for jobs in ([], [completed_job(self.run), completed_job(self.run)]):
            api = FakeAPI([self.run])
            api.jobs[123] = jobs
            self.assertEqual(self.plan(api=api).mode, 'full')

    def test_latest_successful_attempt_is_fetched_explicitly(self):
        api = FakeAPI([completed_run(self.head, attempt=3)])
        plan = self.plan(api=api)
        self.assertEqual((plan.mode, plan.reused_attempt), ('reuse', '3'))
        self.assertTrue(any('/attempts/3/jobs?' in call for call in api.calls))

    def test_changed_run_during_final_read_falls_back_to_full(self):
        for change in (
            {'run_attempt': 2}, {'status': 'in_progress'}, {'conclusion': 'failure'},
            {'head_sha': self.base}, {'event': 'pull_request'},
            {'path': '.github/workflows/another.yml'}, {'id': 987},
            {'repository': {'full_name': 'other/gitpier'}},
            {'head_repository': {'full_name': 'fork/gitpier'}},
            {'repository': {'id': 11, 'full_name': REPOSITORY}},
            {'head_repository': {'id': 11, 'full_name': REPOSITORY}},
            {'head_branch': 'feature'},
        ):
            with self.subTest(change=change):
                api = FakeAPI([self.run])
                api.latest[123].update(change)
                self.assertEqual(self.plan(api=api).mode, 'full')

    def test_unrelated_repository_metadata_change_does_not_invalidate_full_evidence(self):
        self.api.latest[123]['repository']['description'] = 'Updated repository description'
        self.api.latest[123]['head_repository']['open_issues_count'] = 42
        self.assertEqual(self.plan().mode, 'reuse')

    def test_manual_reruns_do_not_reuse_successful_history(self):
        for env in ({'GITHUB_EVENT_NAME': 'workflow_dispatch'}, {'GITHUB_RUN_ATTEMPT': '2'}):
            self.assertEqual(self.plan(env=env).mode, 'full')
        self.assertEqual(self.api.calls, [])

    def test_pull_requests_feature_branches_and_other_hosts_do_not_reuse(self):
        for env in (
            {'GITHUB_EVENT_NAME': 'pull_request', 'GITHUB_REF': 'refs/pull/1/merge'},
            {'GITHUB_REF': 'refs/heads/feature'},
            {'GITHUB_SERVER_URL': 'https://example.invalid'},
            {'GITHUB_REPOSITORY': '../invalid'},
        ):
            with self.subTest(env=env):
                self.assertEqual(self.plan(env=env).mode, 'full')
        self.assertEqual(self.api.calls, [])

    def test_api_errors_fail_closed_without_leaking_payload(self):
        for error in (
            policy.EvidenceError('private response'),
            subprocess.CalledProcessError(1, ['gh', 'api'], stderr=b'private response'),
            subprocess.TimeoutExpired(['gh', 'api'], 20), OSError('private response'),
            ValueError('private response'),
        ):
            with self.subTest(error=type(error).__name__):
                def fail(_path):
                    raise error
                plan = self.plan(api=fail)
                self.assertEqual(plan.mode, 'full')
                self.assertNotIn('private response', plan.reason)

    def test_later_page_of_runs_and_jobs_is_read_before_reuse(self):
        ignored = [completed_run(self.head, run_id=1000 + n, branch='feature') for n in range(100)]
        api = FakeAPI([*ignored, self.run])
        api.jobs[123] = [
            {'id': n + 1000, 'name': f'other-job-{n}'} for n in range(100)
        ] + [completed_job(self.run)]
        self.assertEqual(self.plan(api=api).mode, 'reuse')
        self.assertEqual(sum('page=2' in call for call in api.calls), 2)

    def test_incomplete_run_or_job_listing_falls_back_to_full(self):
        for target in ('runs', 'jobs'):
            with self.subTest(target=target):
                api = FakeAPI([self.run])
                def truncated(path):
                    body = api(path)
                    key = 'workflow_runs' if target == 'runs' else 'jobs'
                    if key in body:
                        body['total_count'] = 2
                    return body
                self.assertEqual(self.plan(api=truncated).mode, 'full')


class PaginationTests(unittest.TestCase):
    def test_invalid_or_excessive_listing_is_rejected(self):
        for body in (
            {}, {'total_count': True, 'jobs': []}, {'total_count': -1, 'jobs': []},
            {'total_count': 1001, 'jobs': []}, {'total_count': 1, 'jobs': {}},
            {'total_count': 1, 'jobs': [None]}, {'total_count': 0, 'jobs': [{}]},
            {'total_count': 1, 'jobs': []},
        ):
            with self.subTest(body=body):
                with self.assertRaises(policy.EvidenceError):
                    policy.api_items('fake', 'jobs', lambda _path: body)

    def test_repeated_nonempty_page_cannot_run_unbounded(self):
        calls = []
        def repeated(path):
            calls.append(path)
            return {'total_count': 1000, 'jobs': [{'id': 1}]}
        with self.assertRaises(policy.EvidenceError):
            policy.api_items('fake', 'jobs', repeated)
        self.assertLessEqual(len(calls), 10)

    def test_duplicate_page_items_do_not_prove_complete_listing(self):
        def duplicate(path):
            page = int(parse_qs(urlsplit(path).query)['page'][0])
            items = [{'id': value} for value in range(1, 101)] if page == 1 else [{'id': 1}]
            return {'total_count': 101, 'jobs': items}
        with self.assertRaises(policy.EvidenceError):
            policy.api_items('fake', 'jobs', duplicate)

    def test_changing_total_during_pagination_is_rejected(self):
        def changed(path):
            page = int(parse_qs(urlsplit(path).query)['page'][0])
            if page == 1:
                return {'total_count': 102, 'jobs': [{'id': value} for value in range(1, 101)]}
            return {'total_count': 101, 'jobs': [{'id': 101}]}
        with self.assertRaises(policy.EvidenceError):
            policy.api_items('fake', 'jobs', changed)


class WorkflowContractTests(unittest.TestCase):
    """The fast path may reuse compilation, never successful test results."""

    def setUp(self):
        self.workflow = (policy.ROOT / policy.WORKFLOW).read_text(encoding='utf-8')
        self.build = self.workflow.split('  build-test:\n', 1)[1]
        matches = list(re.finditer(r'^      - name: (.+)$', self.build, re.MULTILINE))
        self.names = [match[1] for match in matches]
        self.assertEqual(len(self.names), len(set(self.names)))
        self.steps = {
            match[1]: self.build[match.end():matches[index + 1].start() if index + 1 < len(matches) else None]
            for index, match in enumerate(matches)
        }

    def test_all_full_gates_remain_ordered_and_independent_of_cache_hits(self):
        positions = [self.names.index(name) for name in FULL_STEP_NAMES]
        self.assertEqual(positions, sorted(positions))
        for name in FULL_STEP_NAMES:
            with self.subTest(step=name):
                step = self.steps[name]
                self.assertNotIn('cache-hit', step)
                self.assertNotIn('continue-on-error:', step)
                self.assertNotIn('--skip-build', step)
                self.assertNotIn('--filter', step)
                self.assertNotIn('--skip ', step)
                condition = "env.VALIDATION_MODE != 'reuse'" if name == 'Release metadata and signing gates' else "env.VALIDATION_MODE == 'full'"
                self.assertIn('if: ' + condition, step)

    def test_core_runs_all_tests_with_bounded_parallelism(self):
        command = re.search(r'^\s*(?:run: )?(Scripts/test.sh[^\n]*)$', self.steps['Real Git repository tests'], re.MULTILINE)
        self.assertIsNotNone(command)
        arguments = shlex.split(command[1])
        self.assertIn('--parallel', arguments)
        self.assertEqual(arguments[arguments.index('--num-workers') + 1], '2')
        self.assertEqual(arguments[arguments.index('--jobs') + 1], '2')
        self.assertIn('--xunit-output', arguments)

    def test_diagnostics_preserve_test_failures_and_only_archive_test_output(self):
        core = self.steps['Real Git repository tests']
        self.assertIn('set -o pipefail', core)
        self.assertIn('2>&1 | tee .cache/ci/core-tests.log', core)
        self.assertNotIn('continue-on-error:', core)
        self.assertIn('Upload test diagnostics', self.steps)
        diagnostics = self.steps['Upload test diagnostics']
        self.assertIn("steps.core-tests.outcome == 'failure'", diagnostics)
        self.assertIn('!cancelled()', diagnostics)
        self.assertIn('.cache/ci/core-tests.xml', diagnostics)
        self.assertIn('.cache/ci/core-tests.log', diagnostics)
        self.assertIn('include-hidden-files: true', diagnostics)
        self.assertNotIn('path: .cache\n', diagnostics)

    def test_jobs_and_expensive_steps_are_time_bounded(self):
        header = self.build.split('    steps:', 1)[0]
        job_timeout = re.search(r'^    timeout-minutes: (\d+)$', header, re.MULTILINE)
        self.assertIsNotNone(job_timeout)
        self.assertLessEqual(int(job_timeout[1]), 45)
        self.assertNotIn('continue-on-error:', header)
        for name, maximum in (('Real Git repository tests', 25), ('Build application', 15),
                              ('Restore SwiftPM build cache', 5), ('Save SwiftPM build cache', 5)):
            with self.subTest(step=name):
                timeout = re.search(r'^        timeout-minutes: (\d+)$', self.steps[name], re.MULTILINE)
                self.assertIsNotNone(timeout)
                self.assertGreater(int(timeout[1]), 0)
                self.assertLessEqual(int(timeout[1]), maximum)

    def test_cache_is_limited_to_build_files_and_written_only_after_successful_pushes(self):
        self.assertIn('Restore SwiftPM build cache', self.steps)
        self.assertIn('Save SwiftPM build cache', self.steps)
        allowed = {'.build', '.cache/swiftpm', '.cache/swift', '.cache/clang'}
        for name in ('Restore SwiftPM build cache', 'Save SwiftPM build cache'):
            with self.subTest(step=name):
                step = self.steps[name]
                block = re.search(r'^          path: \|\n((?:            .+\n)+)', step, re.MULTILINE)
                self.assertIsNotNone(block)
                self.assertEqual({line.strip() for line in block[1].splitlines()}, allowed)
                self.assertIn("env.VALIDATION_MODE == 'full'", step)
        save = self.steps['Save SwiftPM build cache']
        self.assertIn('success()', save)
        self.assertIn("github.event_name == 'push'", save)
        self.assertGreater(self.names.index('Save SwiftPM build cache'), self.names.index(FULL_STEP_NAMES[-1]))

    def test_cache_keys_bind_toolchain_dependencies_and_build_inputs(self):
        self.assertIn('Restore SwiftPM build cache', self.steps)
        self.assertIn('Save SwiftPM build cache', self.steps)
        restore = self.steps['Restore SwiftPM build cache']
        self.assertIn('runner.os', restore)
        self.assertIn('runner.arch', restore)
        self.assertIn('steps.toolchain.outputs.cache-context', restore)
        self.assertIn("hashFiles('Package.swift', 'Package.resolved')", restore)
        for inputs in ('Sources/**', 'Tests/**', 'Scripts/**', 'Resources/**', '.github/workflows/validate.yml'):
            self.assertIn(inputs, restore)
        self.assertIn('steps.swift-cache.outputs.cache-primary-key', self.steps['Save SwiftPM build cache'])
        toolchain = self.steps['Toolchain']
        for context in ('swift --version', 'xcodebuild -version', '--show-sdk-build-version', 'sw_vers -buildVersion'):
            self.assertIn(context, toolchain)


class CommandLineTests(unittest.TestCase):
    def test_missing_event_file_outputs_full_plan_without_payload_or_network(self):
        with tempfile.TemporaryDirectory(prefix='gitpier-ci-cli-') as temporary:
            root = Path(temporary)
            output, summary = root / 'output', root / 'summary'
            environment = {
                'GITHUB_EVENT_PATH': str(root / 'missing-private-event.json'),
                'GITHUB_OUTPUT': str(output), 'GITHUB_STEP_SUMMARY': str(summary),
            }
            captured = io.StringIO()
            with mock.patch.dict(os.environ, environment, clear=True), \
                    mock.patch.object(policy.sys, 'argv', ['ci_validation.py', 'plan']), \
                    redirect_stdout(captured):
                policy.main()
            self.assertEqual(output.read_text().splitlines(), [
                'mode=full', 'base=', 'reused_run=', 'reused_attempt=',
            ])
            self.assertIn('**full**', summary.read_text())
            self.assertNotIn('missing-private-event', captured.getvalue())


if __name__ == '__main__':
    unittest.main(verbosity=2)
