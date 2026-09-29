"""The committed VERSION is the sole source for app packaging and display."""
from pathlib import Path
import re
import subprocess
import sys
import tempfile


def validate_version(value):
    if not re.fullmatch(r"(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)", value):
        raise ValueError("VERSION 必须为 major.minor.patch，例如 1.1.0。")
    return value


def read_version(root):
    return validate_version((Path(root) / "VERSION").read_text(encoding="utf-8").strip())


def git(root, *args, check=True):
    return subprocess.run(["git", *args], cwd=root, check=check, text=True, capture_output=True)


def prepare_commit(root):
    root = Path(root)
    path = root / "VERSION"
    if path.is_symlink() or not path.is_file():
        raise ValueError("VERSION 必须是仓库中的普通文件，请先创建并暂存。")
    staged = git(root, "show", ":VERSION", check=False)
    if staged.returncode:
        raise ValueError("请先执行 git add VERSION，再提交。")
    version = validate_version(staged.stdout.strip())
    if read_version(root) != version:
        raise ValueError("VERSION 有未暂存修改；请先暂存或还原该文件，避免覆盖手动指定的版本。")
    previous = git(root, "show", "HEAD:VERSION", check=False)
    # A newly introduced or explicitly staged version is a manual override.
    # A failed commit can be retried without incrementing the staged version twice.
    if previous.returncode or previous.stdout.strip() != version:
        print("提交版本：" + version)
        return version
    major, minor, patch = map(int, version.split("."))
    version = f"{major}.{minor}.{patch + 1}"
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=root, prefix=".version-", delete=False) as stream:
        temporary = Path(stream.name)
        stream.write(version + "\n")
    try:
        temporary.chmod(path.stat().st_mode & 0o777)
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)
    git(root, "add", "--", "VERSION")
    print("自动递增版本：" + version)
    return version


def sync_index(root):
    # `git commit -- <paths>` builds a temporary index for pre-commit. Its new
    # VERSION is committed, but Git can leave the real index at the old version.
    # Reconcile only that old entry; preserve any unrelated staged/working work.
    root = Path(root)
    committed = git(root, "show", "HEAD:VERSION", check=False)
    staged = git(root, "show", ":VERSION", check=False)
    if committed.returncode or staged.returncode:
        return
    version = committed.stdout.strip()
    if read_version(root) != version or staged.stdout.strip() == version:
        return
    for previous in ["HEAD@{1}:VERSION", "HEAD^:VERSION"]:
        old = git(root, "show", previous, check=False)
        if old.returncode == 0 and staged.stdout.strip() == old.stdout.strip():
            git(root, "add", "--", "VERSION")
            return


if __name__ == "__main__":
    try:
        operations = {"prepare-commit": prepare_commit, "sync-index": sync_index}
        if len(sys.argv) != 2 or sys.argv[1] not in operations:
            raise ValueError("用法：python3 scripts/versioning.py prepare-commit|sync-index")
        root = git(Path.cwd(), "rev-parse", "--show-toplevel").stdout.strip()
        operations[sys.argv[1]](root)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
