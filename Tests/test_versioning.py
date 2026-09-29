from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class VersioningTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.git("init", "-q")
        self.git("config", "user.name", "Version Test")
        self.git("config", "user.email", "version-test@example.invalid")
        self.git("config", "commit.gpgsign", "false")
        (self.root / "scripts").mkdir()
        (self.root / ".githooks").mkdir()
        for name in ["versioning.py", "install-git-hooks.sh", "write-app-info.py"]:
            shutil.copy2(ROOT / "scripts" / name, self.root / "scripts" / name)
        for name in ["pre-commit", "post-commit"]:
            shutil.copy2(ROOT / ".githooks" / name, self.root / ".githooks" / name)
            (self.root / ".githooks" / name).chmod(0o755)
        self.run_command("bash", "scripts/install-git-hooks.sh")
        self.version_path = self.root / "VERSION"
        self.version_path.write_text("1.1.0\n")
        (self.root / "notes.txt").write_text("initial\n")
        self.git("add", "--all")
        self.git("commit", "-qm", "Initial explicit version")

    def run_command(self, *args, check=True):
        return subprocess.run(args, cwd=self.root, check=check, capture_output=True, text=True)

    def git(self, *args, check=True):
        return self.run_command("git", *args, check=check)

    def committed_version(self):
        return self.git("show", "HEAD:VERSION").stdout.strip()

    def test_each_commit_increments_patch(self):
        self.assertEqual(self.committed_version(), "1.1.0")
        for expected in ["1.1.1", "1.1.2"]:
            self.git("commit", "--allow-empty", "-qm", "Next change")
            self.assertEqual(self.committed_version(), expected)
            self.assertEqual(self.version_path.read_text().strip(), expected)
            self.assertEqual(self.git("status", "--porcelain").stdout, "")

    def test_staged_manual_version_wins(self):
        self.version_path.write_text("2.3.0\n")
        self.git("add", "VERSION")
        self.git("commit", "-qm", "Explicit release")
        self.assertEqual(self.committed_version(), "2.3.0")
        self.git("commit", "--allow-empty", "-qm", "Next patch")
        self.assertEqual(self.committed_version(), "2.3.1")

    def test_retry_does_not_bump_twice(self):
        for _ in range(2):
            self.run_command(sys.executable, "scripts/versioning.py", "prepare-commit")
        self.git("commit", "-qm", "Retry prepared commit")
        self.assertEqual(self.committed_version(), "1.1.1")

    def test_unstaged_version_is_never_overwritten(self):
        original_head = self.git("rev-parse", "HEAD").stdout
        self.version_path.write_text("3.0.0\n")
        result = self.git("commit", "--allow-empty", "-qm", "Must reject", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("未暂存", result.stderr)
        self.assertEqual(self.git("rev-parse", "HEAD").stdout, original_head)
        self.assertEqual(self.version_path.read_text(), "3.0.0\n")
        self.assertEqual(self.git("show", ":VERSION").stdout, "1.1.0\n")

    def test_other_unstaged_changes_stay_unstaged(self):
        note = self.root / "notes.txt"
        note.write_text("commit this\n")
        self.git("add", "notes.txt")
        note.write_text("keep this unstaged\n")
        self.git("commit", "-qm", "Partial staging")
        self.assertEqual(self.git("show", "HEAD:notes.txt").stdout, "commit this\n")
        self.assertEqual(note.read_text(), "keep this unstaged\n")
        self.assertEqual(self.committed_version(), "1.1.1")

    def test_path_limited_commit_also_includes_version(self):
        (self.root / "notes.txt").write_text("selected path\n")
        self.git("commit", "-qm", "One path", "--", "notes.txt")
        self.assertEqual(self.committed_version(), "1.1.1")
        self.assertEqual(self.version_path.read_text(), "1.1.1\n")
        self.assertEqual(self.git("status", "--porcelain").stdout, "")

    def test_invalid_version_stops_commit(self):
        self.version_path.write_text("v1.1.0\n")
        self.git("add", "VERSION")
        result = self.git("commit", "-qm", "Invalid version", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.committed_version(), "1.1.0")

    def test_installer_preserves_custom_hooks(self):
        self.git("config", "core.hooksPath", ".custom-hooks")
        result = self.run_command("bash", "scripts/install-git-hooks.sh", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.git("config", "core.hooksPath").stdout.strip(), ".custom-hooks")

    def test_packaging_reads_latest_version_file(self):
        self.version_path.write_text("2.4.6\n")
        app = self.root / "Test.app"
        (app / "Contents").mkdir(parents=True)
        self.run_command(sys.executable, "scripts/write-app-info.py", str(app), "runtime")
        with (app / "Contents/Info.plist").open("rb") as stream:
            info = plistlib.load(stream)
        self.assertEqual(info["CFBundleShortVersionString"], "2.4.6")
        self.assertEqual(info["CFBundleVersion"], "2.4.6")


if __name__ == "__main__":
    unittest.main()
