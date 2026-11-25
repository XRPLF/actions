"""Tests for check-pr-description.py. Run: pytest check-pr-description"""

import importlib.util
import sys
from pathlib import Path

import pytest

SCRIPT = Path(__file__).with_name("check-pr-description.py")
spec = importlib.util.spec_from_file_location("check_pr_description", SCRIPT)
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)

TEMPLATE = "## Summary\n<!-- Describe the change. -->\n\n## Test Plan\n"


@pytest.fixture
def run(tmp_path, monkeypatch, capsys):
    def _run(body: str) -> tuple[int, str]:
        template_file = tmp_path / "template.md"
        body_file = tmp_path / "body.md"
        template_file.write_text(TEMPLATE, encoding="utf-8")
        body_file.write_text(body, encoding="utf-8")
        monkeypatch.setattr(
            sys,
            "argv",
            [
                str(SCRIPT),
                "--template-file",
                str(template_file),
                "--pr-body-file",
                str(body_file),
            ],
        )
        rc = check.main()
        return rc, capsys.readouterr().out

    return _run


def test_customized_body_passes(run):
    rc, _ = run("## Summary\nFix a bug.\n\n## Test Plan\nRan tests.\n")
    assert rc == 0


@pytest.mark.parametrize(
    "body",
    [
        pytest.param("  \n", id="empty"),
        pytest.param(TEMPLATE, id="template"),
        pytest.param("<!-- nothing here -->\n", id="comment-only"),
        pytest.param(TEMPLATE + "<!-- unclosed\nFix a bug.\n", id="unclosed-comment"),
        pytest.param(
            TEMPLATE.replace("## Test Plan", "##   Test   Plan"), id="whitespace-only"
        ),
    ],
)
def test_uncustomized_body_fails(run, body):
    rc, _ = run(body)
    assert rc == 1


def test_echoed_body_cannot_issue_workflow_commands(run):
    rc, out = run(TEMPLATE + "<!--\n::warning::injected\n-->\n")
    assert rc == 1
    lines = out.splitlines()
    start = next(i for i, l in enumerate(lines) if l.startswith("::stop-commands::"))
    token = lines[start].removeprefix("::stop-commands::")
    assert token
    end = lines.index(f"::{token}::")
    for line in lines[:start] + lines[end + 1 :]:
        assert "Visible" not in line
    assert any("## Summary" in l for l in lines[start:end])
