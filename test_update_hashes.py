"""
Offline tests for update_hashes.py.

Run them from the repository root with:

    python3 -m unittest -v test_update_hashes

Only the standard library is used. `git` is never executed: `subprocess.run` is
replaced by a stub that answers the `git log` query made by
`get_latest_commit_for_path` and fails on any other command.
"""

import contextlib
import io
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import update_hashes

OLD_SHA = "0" * 40
NPROC_SHA = "1" * 40
PREPARE_RUNNER_SHA = "2" * 40
PRE_COMMIT_SHA = "3" * 40
THIRD_PARTY_SHA = "a" * 40

LATEST_SHAS = {
    "get-nproc": NPROC_SHA,
    "prepare-runner": PREPARE_RUNNER_SHA,
    ".github/workflows/pre-commit.yml": PRE_COMMIT_SHA,
}

GIT_LOG = [
    "git",
    "-C",
    str(update_hashes.ACTIONS_REPO_PATH),
    "log",
    "-n",
    "1",
    "--pretty=format:%H",
    "--",
]


def fake_run(cmd, **kwargs):
    """Answer `git log -n 1 -- <path>` from LATEST_SHAS instead of running git."""
    if cmd[:-1] != GIT_LOG or cmd[-1] not in LATEST_SHAS:
        raise AssertionError(f"unexpected command: {cmd!r}")
    return subprocess.CompletedProcess(cmd, 0, stdout=LATEST_SHAS[cmd[-1]], stderr="")


def uses(ref: str) -> str:
    return f"jobs:\n  build:\n    steps:\n      - uses: {ref}\n"


class UpdateHashesTest(unittest.TestCase):
    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)

        patcher = mock.patch.object(
            update_hashes.subprocess, "run", side_effect=fake_run
        )
        self.git = patcher.start()
        self.addCleanup(patcher.stop)

    def write(self, relative_path: str, content: str) -> Path:
        path = self.root / relative_path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        return path

    def run_script(self, *args: str) -> str:
        stdout = io.StringIO()
        argv = ["update_hashes.py", *args, str(self.root)]
        with mock.patch.object(sys, "argv", argv), contextlib.redirect_stdout(stdout):
            update_hashes.main()
        return stdout.getvalue()

    def test_yml_and_yaml_files_are_both_updated(self) -> None:
        paths = [
            self.write(name, uses(f"XRPLF/actions/get-nproc@{OLD_SHA}"))
            for name in ("workflow.yml", "workflow.yaml")
        ]

        output = self.run_script()

        for path in paths:
            self.assertEqual(
                path.read_text(), uses(f"XRPLF/actions/get-nproc@{NPROC_SHA}")
            )
        self.assertIn("Updated 2 reference(s) in 2 file(s)", output)

    def test_nested_directories_are_scanned(self) -> None:
        files = {
            ".github/workflows/ci.yml": "get-nproc",
            ".github/workflows/release.yaml": "prepare-runner",
            ".github/actions/build/action.yaml": "get-nproc",
            "deeply/nested/directory/tree/config.yml": "prepare-runner",
        }
        for name, action in files.items():
            self.write(name, uses(f"XRPLF/actions/{action}@{OLD_SHA}"))

        output = self.run_script()

        for name, action in files.items():
            self.assertIn(f"Found 1 reference(s) in {self.root / name}:", output)
            self.assertEqual(
                (self.root / name).read_text(),
                uses(f"XRPLF/actions/{action}@{LATEST_SHAS[action]}"),
            )
        self.assertIn("Updated 4 reference(s) in 4 file(s)", output)
        # The latest commit is still looked up once per action path.
        self.assertEqual(
            sorted(call.args[0][-1] for call in self.git.call_args_list),
            ["get-nproc", "prepare-runner"],
        )

    def test_yml_files_keep_their_order_and_yaml_files_follow(self) -> None:
        for name in ("b.yaml", "a/c.yml", "a/d.yaml", "e.yml", "f/g/h.yml"):
            self.write(name, uses(f"XRPLF/actions/get-nproc@{OLD_SHA}"))

        with contextlib.redirect_stdout(io.StringIO()):
            found = list(update_hashes.collect_all_references(self.root))

        self.assertEqual(found, [*self.root.rglob("*.yml"), *self.root.rglob("*.yaml")])

    def test_dry_run_writes_nothing(self) -> None:
        paths = [
            self.write(name, uses(f"XRPLF/actions/get-nproc@{OLD_SHA}"))
            for name in (".github/workflows/ci.yml", ".github/actions/x/action.yaml")
        ]
        for path in paths:
            os.utime(path, ns=(1_000_000_000, 1_000_000_000))
        before = {path: (path.read_bytes(), path.stat().st_mtime_ns) for path in paths}
        tree_before = sorted(self.root.rglob("*"))

        with mock.patch.object(
            Path, "write_text", side_effect=AssertionError("dry run wrote a file")
        ):
            output = self.run_script("--dry-run")

        after = {path: (path.read_bytes(), path.stat().st_mtime_ns) for path in paths}
        self.assertEqual(after, before)
        self.assertEqual(sorted(self.root.rglob("*")), tree_before)
        self.assertIn("Updates to be applied:", output)
        for path in paths:
            self.assertIn(
                f"- {path}: XRPLF/actions/get-nproc@{OLD_SHA}"
                f" -> XRPLF/actions/get-nproc@{NPROC_SHA}",
                output,
            )
        self.assertIn(
            "Dry run complete: 2 update(s) would be applied across 2 file(s)", output
        )

    def test_sha_replacement(self) -> None:
        template = (
            "jobs:\n"
            "  lint:\n"
            "    uses: XRPLF/actions/.github/workflows/pre-commit.yml@{pre_commit}\n"
            "  build:\n"
            "    steps:\n"
            "      - uses: actions/checkout@{third_party} # v7.0.1\n"
            "      - uses: XRPLF/actions/get-nproc@{nproc} # keep this comment\n"
            "      - uses: XRPLF/actions/get-nproc@{nproc}\n"
            "      - uses: XRPLF/actions/prepare-runner@{prepare_runner}\n"
            "      - uses: XRPLF/actions/get-nproc@main\n"
        )
        original = template.format(
            pre_commit=OLD_SHA,
            third_party=THIRD_PARTY_SHA,
            nproc=OLD_SHA,
            prepare_runner=PREPARE_RUNNER_SHA,  # already the latest commit
        )
        expected = template.format(
            pre_commit=PRE_COMMIT_SHA,
            third_party=THIRD_PARTY_SHA,
            nproc=NPROC_SHA,
            prepare_runner=PREPARE_RUNNER_SHA,
        )

        for extension in (".yml", ".yaml"):
            with self.subTest(extension=extension):
                path = self.write(f"nested/workflow{extension}", original)

                output = self.run_script()

                self.assertEqual(path.read_text(), expected)
                self.assertIn("Updated 2 reference(s) in 1 file(s)", output)
                path.unlink()

    def test_up_to_date_file_is_not_rewritten(self) -> None:
        self.write("action.yaml", uses(f"XRPLF/actions/get-nproc@{NPROC_SHA}"))

        with mock.patch.object(
            Path, "write_text", side_effect=AssertionError("file was rewritten")
        ):
            output = self.run_script()

        self.assertIn(f"Found 1 reference(s) in {self.root / 'action.yaml'}:", output)
        self.assertIn("Updated 0 reference(s) in 0 file(s)", output)

    def test_other_files_are_ignored(self) -> None:
        content = uses(f"XRPLF/actions/get-nproc@{OLD_SHA}")
        paths = [
            self.write(name, content)
            for name in ("notes.txt", "config.json", "workflow.yml.bak", "x.yamlx")
        ]

        output = self.run_script()

        for path in paths:
            self.assertEqual(path.read_text(), content)
        self.assertIn("Updated 0 reference(s) in 0 file(s)", output)
        self.git.assert_not_called()

    @unittest.skipIf(os.name == "nt", "pathlib globbing is case-insensitive on Windows")
    def test_extension_match_is_case_sensitive_on_posix(self) -> None:
        content = uses(f"XRPLF/actions/get-nproc@{OLD_SHA}")
        paths = [self.write(name, content) for name in ("UPPER.YML", "UPPER.YAML")]

        output = self.run_script()

        for path in paths:
            self.assertEqual(path.read_text(), content)
        self.assertIn("Updated 0 reference(s) in 0 file(s)", output)
        self.git.assert_not_called()


if __name__ == "__main__":
    unittest.main()
