"""Unprivileged regression tests. No mounts, package installs or services run."""
import contextlib
import io
import json
import pathlib
import re
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = (pathlib.Path(__file__).resolve().parents[1] / 'node-setup.sh').read_text()


def embedded(label):
    return SCRIPT.split("<<'" + label + "'\n", 1)[1].split('\n' + label, 1)[0]


def device(name='/dev/sdb1', **kwargs):
    return dict(name=name, type='part', fstype='xfs', uuid='abcd-1234',
                mountpoints=[None], ro=False, rm=False, **kwargs)


class MountTests(unittest.TestCase):
    def exercise(self, devices, configured='', duplicate=False, fail_mount=False):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = pathlib.Path(temp.name)
        fstab = root / 'fstab'
        fstab.write_text('# existing\n')
        calls = []

        def fake_run(args, **kwargs):
            calls.append(args)
            cmd = args[0]
            stdout, rc = '', 0
            if cmd == 'lsblk':
                stdout = json.dumps({'blockdevices': devices})
            elif cmd == 'blkid':
                stdout = '/dev/sdb1\n' + ('/dev/sdc1\n' if duplicate else '')
            elif cmd == 'findmnt':
                stdout, rc = configured, 0 if configured else 1
            elif cmd == 'mount' and fail_mount:
                raise subprocess.CalledProcessError(32, args)
            return subprocess.CompletedProcess(args, rc, stdout=stdout)

        code = embedded('PYDISKS').replace("'/etc/fstab'", repr(str(fstab)))
        code = code.replace("'/mnt/disks'", repr(str(root / 'disks')))
        with patch('subprocess.run', fake_run), contextlib.redirect_stdout(io.StringIO()):
            try:
                exec(compile(code, '<mount-disks>', 'exec'), {})
            finally:
                self.calls, self.fstab = calls, fstab.read_text()
        return calls, self.fstab

    def test_adds_uuid_mount_and_preserves_fstab(self):
        calls, text = self.exercise([device()])
        self.assertTrue(text.startswith('# existing\n'))
        self.assertIn('UUID=abcd-1234', text)
        self.assertIn('nofail', text)
        self.assertEqual(sum(c[0] == 'mount' for c in calls), 1)

    def test_skips_mounted_raw_swap_members_and_removable(self):
        devices = []
        for key, value in [('mountpoints', ['/home']), ('fstype', None),
                           ('fstype', 'swap'), ('fstype', 'LVM2_member'),
                           ('fstype', 'crypto_LUKS'), ('ro', True), ('rm', True)]:
            d = device(); d[key] = value; devices.append(d)
        # Unique names ensure lsblk de-duplication doesn't mask cases.
        for i, d in enumerate(devices): d['name'] = f'/dev/test{i}'
        calls, text = self.exercise(devices)
        self.assertFalse(any(c[0] == 'mount' for c in calls))
        self.assertEqual(text, '# existing\n')

    def test_existing_destination(self):
        calls, text = self.exercise([device()], configured='/data defaults\n')
        self.assertIn(('mount', '--', '/data'), calls)
        self.assertEqual(text, '# existing\n')

    def test_noauto_respected(self):
        calls, _ = self.exercise([device()], configured='/data defaults,noauto\n')
        self.assertFalse(any(c[0] == 'mount' for c in calls))

    def test_duplicate_uuid_rejected(self):
        with self.assertRaises(SystemExit): self.exercise([device()], duplicate=True)
        self.assertEqual(self.fstab, '# existing\n')

    def test_mount_failure_does_not_persist_entry(self):
        with self.assertRaises(subprocess.CalledProcessError):
            self.exercise([device()], fail_mount=True)
        self.assertEqual(self.fstab, '# existing\n')

    def test_lvm_leaf_and_removable_parent(self):
        d = device(); d['type'] = 'lvm'
        parent = dict(name='/dev/sdb', type='disk', rm=False, children=[d])
        calls, _ = self.exercise([parent])
        self.assertTrue(any(c[0] == 'mount' for c in calls))
        parent['rm'] = True
        calls, _ = self.exercise([parent])
        self.assertFalse(any(c[0] == 'mount' for c in calls))


class SetupTests(unittest.TestCase):
    def test_embedded_python_compiles(self):
        for label in re.findall(r"<<'(PY\w*)'", SCRIPT):
            compile(embedded(label), label, 'exec')

    def test_storage_paths(self):
        for paths, good in [(['/var/lib/docker', '/home/docker-data', '/home/containerd-data'], True),
                            (['/var/lib/docker', '/home', '/home/containerd'], False),
                            (['/var/lib/docker', 'relative', '/home/containerd'], False),
                            (['/var/lib/docker', '/home/data', '/home/data/sub'], False),
                            (['/var/lib/docker', '/home/data', '/home/data'], False)]:
            result = subprocess.run(['python3', '-c', embedded('PYPATH'), *paths], capture_output=True)
            self.assertEqual(result.returncode == 0, good, result.stderr)

    def test_failed_copy_keeps_originals_and_does_not_switch_config(self):
        with tempfile.TemporaryDirectory() as temp:
            root = pathlib.Path(temp)
            docker = root / 'var/lib/docker'
            containerd = root / 'var/lib/containerd'
            docker.mkdir(parents=True)
            containerd.mkdir()
            (docker / 'image').write_text('image-data')
            (containerd / 'snapshot').write_text('snapshot-data')
            function = SCRIPT.split('setup_docker() {', 1)[1].split('# New-node update', 1)[0]
            function = 'setup_docker() {' + function
            for path in ('/var/', '/etc/', '/home/'):
                function = function.replace(path, str(root) + path)
            harness = f"""
set -eu -o pipefail
STATE_DIR={root}/state
DOCKER_DATA_ROOT={root}/home/docker-data
CONTAINERD_DATA_ROOT={root}/home/containerd-data
log_error() {{ echo "$*"; }}
dnf() {{ :; }}
containerd() {{ echo 'root = "{containerd}"'; }}
systemctl() {{ [[ $1 != is-active ]]; }}
mountpoint() {{ :; }}
readlink() {{ python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$2"; }}
rsync() {{ return 23; }}
""" + function + '\nsetup_docker\n'
            result = subprocess.run(['bash', '-c', harness], text=True, capture_output=True)
            self.assertEqual(result.returncode, 23, result.stderr)
            self.assertEqual((docker / 'image').read_text(), 'image-data')
            self.assertEqual((containerd / 'snapshot').read_text(), 'snapshot-data')
            self.assertFalse(containerd.is_symlink())
            self.assertFalse((root / 'etc/docker/daemon.json').exists())

    def test_base_failure_stops_and_success_checkpoint_skips_reinstall(self):
        with tempfile.TemporaryDirectory() as temp:
            root = pathlib.Path(temp)
            os_release = root / 'os-release'
            os_release.write_text('VERSION_ID=9\n')
            definitions = SCRIPT.split('# dispatch\n', 1)[0]
            definitions = definitions.replace('/var/lock/node-maintenance.lock', str(root / 'lock'))
            definitions = definitions.replace('. /etc/os-release', '. ' + str(os_release))
            prefix = definitions + f'''
STATE_DIR={root}/state
require_root() {{ :; }}
flock() {{ :; }}
uname() {{ if [[ $1 == -m ]]; then echo x86_64; else echo test-kernel; fi; }}
kernels_installed() {{ echo test-kernel; }}
dnf() {{ echo "$*" >> {root}/dnf.log; return "$FAIL_DNF"; }}
bootstrap base
'''
            def run(fail):
                return subprocess.run(['bash', '-c', 'FAIL_DNF=' + str(fail) + '\n' + prefix], capture_output=True, text=True)
            self.assertNotEqual(run(1).returncode, 0)
            self.assertFalse((root / 'state/bootstrap/base').exists())
            result = run(0)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue((root / 'state/bootstrap/base').exists())
            log = (root / 'dnf.log').read_text()
            self.assertEqual(run(1).returncode, 0)
            self.assertEqual((root / 'dnf.log').read_text(), log)


if __name__ == '__main__':
    unittest.main()
