"""Isolated regression tests for runtime propagation and seed readiness."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class FleetInheritance(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='fm-fleet-inherit-')
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.parent = self.base / 'parent'
        self.child = self.base / 'child'
        self.code = self.base / 'code'
        shutil.copytree(ROOT / 'bin', self.code / 'bin')
        for home in (self.parent, self.child):
            for name in ('config', 'state', 'data'):
                (home / name).mkdir(parents=True)
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(('FM_', 'HC_', 'HERDR_', 'TMUX'))}
        self.env.update(FM_HOME=str(self.parent), FM_ROOT_OVERRIDE=str(self.code),
                        FM_INHERITABLE_CONFIG='crew-harness backend',
                        FM_REMOTE_INHERIT_PUSH_JOBS='1')
        self.write(self.parent, 'config/crew-harness', 'codex\n')
        self.write(self.child, 'config/crew-harness', 'claude\n')

    def write(self, home, name, value):
        path = home / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(value)

    def run_bash(self, command):
        return subprocess.run(['bash', '-c', command], env=self.env,
                              text=True, capture_output=True, timeout=30)

    def local(self):
        return self.run_bash(f'. "{self.code}/bin/fm-config-inherit-lib.sh"; '
                            f'propagate_secondmate_inheritance "{self.parent}" "{self.child}"')

    def test_local_conflict_preserves_all_config(self):
        self.write(self.parent, 'state/fleet-backend', 'hc\n')
        self.write(self.child, 'config/backend', 'herdr\n')
        self.write(self.child, 'data/captain-shared.md', 'keep shared preferences\n')
        result = self.local()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('refusing runtime change', result.stderr)
        self.assertEqual((self.child / 'data/captain-shared.md').read_text(), 'keep shared preferences\n')
        self.assertEqual((self.child / 'config/backend').read_text(), 'herdr\n')
        self.assertEqual((self.child / 'config/crew-harness').read_text(), 'claude\n')

    def test_local_pin_survives_absent_source_config(self):
        self.write(self.parent, 'state/fleet-backend', 'hc\n')
        self.write(self.child, 'config/backend', 'hc\n')
        result = self.local()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.child / 'config/backend').exists(), 'selected backend was removed')
        self.assertEqual((self.child / 'config/backend').read_text(), 'hc\n')
        self.assertEqual((self.child / 'state/fleet-backend').read_text(), 'hc\n')

    def test_unrelated_backend_keeps_legacy_copy(self):
        self.write(self.parent, 'config/backend', 'rex\n')
        self.write(self.child, 'config/backend', 'tmux\n')
        result = self.local()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.child / 'config/backend').read_text(), 'rex\n')

    def test_local_parent_conflict_changes_nothing(self):
        self.write(self.parent, 'state/fleet-backend', 'hc\n')
        self.write(self.parent, 'config/backend', 'herdr\n')
        result = self.local()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.child / 'config/crew-harness').read_text(), 'claude\n')
        self.assertFalse((self.child / 'state/fleet-backend').exists())

    def test_local_child_binding_refuses_unrelated_override(self):
        self.write(self.parent, 'config/backend', 'rex\n')
        self.write(self.child, 'state/fleet-backend', 'hc\n')
        result = self.local()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.child / 'config/crew-harness').read_text(), 'claude\n')

    def test_child_cannot_select_unbound_parent_runtime(self):
        self.write(self.child, 'state/fleet-backend', 'hc\n')
        result = self.local()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.parent / 'state/fleet-backend').exists())
        self.assertEqual((self.child / 'config/crew-harness').read_text(), 'claude\n')

    def test_item_failure_still_propagates_shared_preferences(self):
        shared = ('<!-- main-authoritative; read-only in secondmate homes and must not be edited there; '
                  'edit it in the main firstmate home; marked status -->\nshared preferences\n')
        self.write(self.parent, 'data/captain-shared.md', shared)
        (self.parent / 'config/crew-harness').unlink()
        (self.parent / 'config/crew-harness').mkdir()
        result = self.local()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.child / 'data/captain-shared.md').read_text(), shared)
        self.assertEqual((self.child / 'config/crew-harness').read_text(), 'claude\n')

    def test_unbound_selection_keeps_legacy_inheritance(self):
        # Inheritance alone never selects the fleet runtime; secondmate creation does.
        for name, value in (('FM_BACKEND', 'hc'), ('config', 'herdr')):
            with self.subTest(source=name):
                if name == 'FM_BACKEND':
                    self.env['FM_BACKEND'] = value
                else:
                    self.env.pop('FM_BACKEND', None)
                    self.write(self.parent, 'config/backend', value + '\n')
                self.write(self.child, 'config/backend', 'tmux\n')
                result = self.run_bash(f'. "{self.code}/bin/fm-config-inherit-lib.sh"; '
                                      'FM_ROOT=sentinel; FM_BACKEND_CONFIG_DIR=sentinel; '
                                      f'propagate_secondmate_inheritance "{self.parent}" "{self.child}" || exit; '
                                      '[ "$FM_ROOT" = sentinel ] && [ "$FM_BACKEND_CONFIG_DIR" = sentinel ]')
                self.assertEqual(result.returncode, 0, result.stderr)
                if name == 'FM_BACKEND':
                    self.assertFalse((self.child / 'config/backend').exists())
                else:
                    self.assertEqual((self.child / 'config/backend').read_text(), value + '\n')
                self.assertFalse((self.parent / 'state/fleet-backend').exists())
                self.assertFalse((self.child / 'state/fleet-backend').exists())

    def test_seed_explicit_herdr_and_unknown_legacy(self):
        self.transport()
        self.env['FM_SECONDMATE_CHARTER'] = 'Maintain fixture documentation.'
        for backend, expected in [('herdr', ' --backend herdr'), ('rex', '')]:
            with self.subTest(backend=backend):
                self.env['FM_BACKEND'] = backend
                log = self.base / 'transport.log'
                log.write_text('')
                result = self.run_bash(f'bash "{self.code}/bin/fm-remote-home-seed.sh" fixture fixture-host "{self.code}" "{self.child}" --no-projects')
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(log.read_text().splitlines()[0], 'fixture fm-remote-doctor.sh' + expected)

    def transport(self):
        self.write(self.parent, 'data/secondmates.md',
                   f'- fixture - Fixture (host: fixture-host; root: {self.code}; home: {self.child}; scope: fixtures; projects: none; added 2026-11-15)\n')
        self.write(self.child, '.fm-secondmate-home', 'fixture\n')
        self.write(self.child, 'AGENTS.md', '# Fixture\n')
        (self.child / 'bin').mkdir()
        self.env['FIXTURE_CHILD'] = str(self.child)
        self.env['FIXTURE_LOG'] = str(self.base / 'transport.log')
        self.write(self.code, 'bin/fm-on.sh', '''#!/usr/bin/env bash
set -eu
printf '%s\\n' "$*" >> "$FIXTURE_LOG"
[ "${1:-}" != --stdin ] || shift
shift
command=$1; shift
case "$command" in
 fm-remote-doctor.sh) exit 0 ;;
 fm-remote-home-provision.sh) cat >/dev/null; exit 0 ;;
 fm-remote-secondmate-control.sh) [ -z "${FIXTURE_VALIDATE_RC:-}" ] || exit "$FIXTURE_VALIDATE_RC" ;;
esac
export FM_HOME="$FIXTURE_CHILD"
exec bash "$(dirname "$0")/$command" "$@"
''')

    def test_remote_conflict_precedes_any_transfer(self):
        self.transport()
        self.write(self.parent, 'state/fleet-backend', 'hc\n')
        self.write(self.child, 'config/backend', 'herdr\n')
        result = self.run_bash(f'bash "{self.code}/bin/fm-remote-inherit-push.sh" fixture 1')
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.child / 'config/crew-harness').read_text(), 'claude\n')
        self.assertIn('refusing runtime change', result.stderr)
        self.assertNotIn('fm-remote-inherit.sh put', (self.base / 'transport.log').read_text())

    def test_remote_unknown_validation_outcome_is_preserved(self):
        self.transport()
        self.write(self.parent, 'state/fleet-backend', 'hc\n')
        self.env['FIXTURE_VALIDATE_RC'] = '255'
        result = self.run_bash(f'bash "{self.code}/bin/fm-remote-inherit-push.sh" fixture 1')
        self.assertEqual(result.returncode, 255, result.stdout + result.stderr)
        self.assertNotIn('fm-remote-inherit.sh', (self.base / 'transport.log').read_text())

    def test_remote_unmanaged_parent_keeps_legacy_inheritance(self):
        self.transport()
        for generation, parent_backend in enumerate(('rex', ''), 1):
            with self.subTest(parent=parent_backend):
                parent_config = self.parent / 'config/backend'
                parent_config.unlink(missing_ok=True)
                if parent_backend:
                    self.write(self.parent, 'config/backend', parent_backend + '\n')
                self.write(self.child, 'config/backend', 'tmux\n')
                result = self.run_bash(f'bash "{self.code}/bin/fm-remote-inherit-push.sh" fixture {generation}')
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                if parent_backend:
                    self.assertEqual((self.child / 'config/backend').read_text(), parent_backend + '\n')
                else:
                    self.assertFalse((self.child / 'config/backend').exists())
                self.assertFalse((self.parent / 'state/fleet-backend').exists())
                self.assertFalse((self.child / 'state/fleet-backend').exists())
                # A remote checkout older than fleet binding knows no validation command.
                self.assertNotIn('fm-remote-secondmate-control.sh', (self.base / 'transport.log').read_text())

    def test_remote_transfers_pin_without_config_file(self):
        self.transport()
        self.write(self.parent, 'state/fleet-backend', 'hc\n')
        result = self.run_bash(f'bash "{self.code}/bin/fm-remote-inherit-push.sh" fixture 1')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((self.child / 'config/backend').exists(), 'selected backend was removed')
        self.assertEqual((self.child / 'config/backend').read_text(), 'hc\n')

    def test_remote_environment_selection_does_not_bind(self):
        self.transport()
        self.env['FM_BACKEND'] = 'hc'
        result = self.run_bash(f'bash "{self.code}/bin/fm-remote-inherit-push.sh" fixture 1')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.parent / 'state/fleet-backend').exists())
        self.assertFalse((self.child / 'state/fleet-backend').exists())

    def test_seed_conflict_does_not_contact_remote(self):
        self.transport()
        self.write(self.parent, 'state/fleet-backend', 'hc\n')
        self.env['FM_BACKEND'] = 'herdr'
        result = self.run_bash(f'bash "{self.code}/bin/fm-remote-home-seed.sh" fixture fixture-host "{self.code}" "{self.child}" --no-projects')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.base / 'transport.log').exists())

    def test_seed_readiness_uses_fleet_pin(self):
        self.transport()
        self.write(self.parent, 'state/fleet-backend', 'hc\n')
        self.env['FM_SECONDMATE_CHARTER'] = 'Maintain fixture documentation.'
        result = self.run_bash(f'bash "{self.code}/bin/fm-remote-home-seed.sh" fixture fixture-host "{self.code}" "{self.child}" --no-projects')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('fm-remote-doctor.sh --backend hc', (self.base / 'transport.log').read_text())


if __name__ == '__main__':
    unittest.main()
