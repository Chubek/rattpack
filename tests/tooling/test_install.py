"""Installation checks without a D compiler or administrator privileges."""
import importlib.util
import errno
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("installer", ROOT / "tools/install.py")
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class InstallationTests(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory()
        self.addCleanup(self.work.cleanup)
        self.root = Path(self.work.name)
        self.build = self.root / "build"
        self.build.mkdir()
        suffix, library, _ = installer.platform_names()
        for name in [app + suffix for app in installer.APPLICATIONS] + [library, "ratt-satie" + suffix]:
            (self.build / name).write_bytes(b"new payload")

    @unittest.skipIf(os.name == "nt", "POSIX shell launcher")
    def test_shell_launcher_installs_from_another_directory(self):
        destination = self.root / "prefix with spaces"
        result = subprocess.run([str(ROOT / "install.sh"), "--build-dir", str(self.build),
                                 "--prefix", str(destination)], cwd=self.root,
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        for app in installer.APPLICATIONS:
            self.assertEqual((destination / "bin" / (app + installer.platform_names()[0])).read_bytes(),
                             b"new payload")
            self.assertEqual((destination / "share/man/man1" / (app + ".1")).read_bytes(),
                             (ROOT / "man" / (app + ".1")).read_bytes())

    @unittest.skipIf(os.name == "nt", "POSIX shell launcher")
    def test_shell_launcher_propagates_failure(self):
        (self.build / installer.platform_names()[1]).unlink()
        destination = self.root / "install"
        result = subprocess.run([str(ROOT / "install.sh"), "--build-dir", str(self.build),
                                 "--prefix", str(destination)], cwd=self.root,
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("missing build products", result.stderr)
        self.assertFalse(destination.exists())

    def test_missing_runtime_does_not_create_destination(self):
        (self.build / installer.platform_names()[1]).unlink()
        destination = self.root / "install"
        self.assertEqual(installer.main(["--build-dir", str(self.build), "--prefix", str(destination)]), 1)
        self.assertFalse(destination.exists())

    def test_install_layout_and_upgrade_preserve_unmanaged_files(self):
        destination = self.root / "prefix with spaces"
        plan = installer.installation_plan(self.build)
        installer.install(plan, destination)
        self.assertEqual((destination / "bin" / ("ratt-satie" + installer.platform_names()[0])).read_bytes(),
                         b"new payload")
        (destination / "custom.conf").write_text("keep")
        for app in installer.APPLICATIONS:
            self.assertEqual((destination / "bin" / (app + installer.platform_names()[0])).read_bytes(), b"new payload")
            (destination / "share/man/man1" / (app + ".1")).write_text("old manual")
        self.assertTrue((destination / "share/rattpack/templates/scaffold/Rattpkg.in").is_file())
        installer.install(plan, destination)
        self.assertEqual((destination / "custom.conf").read_text(), "keep")
        for app in installer.APPLICATIONS:
            self.assertEqual((destination / "share/man/man1" / (app + ".1")).read_bytes(),
                             (ROOT / "man" / (app + ".1")).read_bytes())

    def test_dry_run_does_not_write(self):
        destination = self.root / "preview"
        self.assertEqual(installer.main(["--build-dir", str(self.build), "--prefix", str(destination), "--dry-run"]), 0)
        self.assertFalse(destination.exists())

    def test_destdir_preserves_prefix_layout(self):
        prefix = self.root / "prefix"
        stage = self.root / "stage"
        self.assertEqual(installer.staged_prefix(prefix, stage), stage.joinpath(*prefix.parts[1:]))

    def test_destdir_installs_manpages_without_writing_prefix(self):
        prefix = self.root / "prefix"
        stage = self.root / "stage"
        self.assertEqual(installer.main(["--build-dir", str(self.build), "--prefix", str(prefix),
                                         "--destdir", str(stage)]), 0)
        self.assertFalse(prefix.exists())
        destination = installer.staged_prefix(prefix, stage)
        for app in installer.APPLICATIONS:
            self.assertEqual((destination / "share/man/man1" / (app + ".1")).read_bytes(),
                             (ROOT / "man" / (app + ".1")).read_bytes())

    def test_build_stages_every_utility_manpage(self):
        result = subprocess.run([os.sys.executable, str(ROOT / "tools/build-man.py"),
                                 "--build-dir", str(self.build)], cwd=self.root,
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual({path.name for path in (self.build / "man/man1").glob("*.1")},
                         {app + ".1" for app in installer.APPLICATIONS})
        for app in installer.APPLICATIONS:
            self.assertEqual((self.build / "man/man1" / (app + ".1")).read_bytes(),
                             (ROOT / "man" / (app + ".1")).read_bytes())

    def test_directory_conflict_is_preflighted(self):
        destination = self.root / "install"
        (destination / "bin/rattsc").mkdir(parents=True)
        with self.assertRaises(ValueError):
            installer.install([(self.build / "rattbuild", Path("bin/rattbuild")),
                               (self.build / "rattsc", Path("bin/rattsc"))], destination)
        self.assertFalse((destination / "bin/rattbuild").exists())

    def test_failed_publication_rolls_back_previous_files(self):
        destination = self.root / "install"
        (destination / "bin").mkdir(parents=True)
        (destination / "bin/first").write_text("old")
        plan = [(self.build / (installer.APPLICATIONS[0] + installer.platform_names()[0]), Path("bin/first")),
                (self.build / (installer.APPLICATIONS[1] + installer.platform_names()[0]), Path("bin/second"))]
        real_replace = installer.os.replace
        def replace(source, target):
            if Path(target).name == "second":
                raise PermissionError("injected publication failure")
            return real_replace(source, target)
        with patch.object(installer.os, "replace", side_effect=replace):
            with self.assertRaises(PermissionError):
                installer.install(plan, destination)
        self.assertEqual((destination / "bin/first").read_text(), "old")
        self.assertFalse((destination / "bin/second").exists())

    @unittest.skipIf(os.name == "nt", "POSIX directory symlinks")
    def test_symlinked_directories_stage_and_roll_back_on_each_filesystem(self):
        destination = self.root / "install"
        destination.mkdir()
        for name in ("bin", "share"):
            directory = self.root / (name + " filesystem")
            directory.mkdir()
            (destination / name).symlink_to(directory, target_is_directory=True)
        first = destination / "bin/first"
        first.write_text("old")
        plan = [(self.build / installer.APPLICATIONS[0], Path("bin/first")),
                (self.build / installer.APPLICATIONS[1], Path("share/second")),
                (self.build / installer.APPLICATIONS[2], Path("share/third"))]
        real_replace = installer.os.replace

        def replace(source, target):
            # Emulate EXDEV for a rename between these filesystem roots.
            if Path(source).resolve().relative_to(self.root).parts[0] != \
                    Path(target).resolve().relative_to(self.root).parts[0]:
                raise OSError(errno.EXDEV, "Invalid cross-device link")
            if Path(target).name == "third":
                raise PermissionError("injected publication failure")
            return real_replace(source, target)

        with patch.object(installer.os, "replace", side_effect=replace):
            with self.assertRaisesRegex(PermissionError, "injected publication failure"):
                installer.install(plan, destination)
        self.assertEqual(first.read_text(), "old")
        self.assertFalse((destination / "share/second").exists())
        self.assertFalse(list(self.root.rglob(".rattpack-install-*")))

        with patch.object(installer.os, "replace", side_effect=replace):
            installer.install(plan[:2], destination)
        self.assertEqual(first.read_bytes(), b"new payload")
        self.assertEqual((destination / "share/second").read_bytes(), b"new payload")
        self.assertFalse(list(self.root.rglob(".rattpack-install-*")))


if __name__ == "__main__":
    unittest.main()
