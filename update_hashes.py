#!/usr/bin/env python3
"""
Script to update hash references to XRPLF/actions in GitHub workflow files.

This script searches for references like:
  - XRPLF/actions/get-nproc@<hash>
  - XRPLF/actions/.github/workflows/pre-commit.yml@<hash>

Then updates them with the latest commit hash that modified the referenced directory.
"""

import argparse
import re
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Set

ACTIONS_REPO_PATH = Path(__file__).resolve().parent


def get_latest_commit_for_path(repo_path: Path, target_path: str) -> str:
    result = subprocess.run(
        [
            "git",
            "-C",
            str(repo_path),
            "log",
            "-n",
            "1",
            "--pretty=format:%H",
            "--",
            target_path,
        ],
        capture_output=True,
        text=True,
        check=True,
    )
    commit_hash = result.stdout.strip()
    assert commit_hash, "Git command failed to return a commit hash"
    return commit_hash


@dataclass(frozen=True)
class ActionReference:
    """Represents a reference to an XRPLF action in a workflow file."""

    full_match: str
    action_path: str
    current_hash: str


# Pattern to match: XRPLF/actions/<path>@<hash>
# Captures the path (which can include slashes and dots) and the 40-char hash
PATTERN = re.compile(
    r"XRPLF/actions/((?:\.github/workflows/[^@\s]+|[a-z0-9._/-]+))@([a-f0-9]{40})"
)


def find_action_references(file_path: Path) -> Set[ActionReference]:
    """
    Find all XRPLF/actions references with commit hashes in a file.

    Returns:
        Set of tuples: (full_match, action_path, current_hash)
        where action_path is like 'get-nproc' or '.github/workflows/pre-commit.yml'
    """
    references = set()

    content = file_path.read_text()
    for match in PATTERN.finditer(content):
        references.add(
            ActionReference(
                full_match=match.group(0),
                action_path=match.group(1),
                current_hash=match.group(2),
            )
        )
    return references


def collect_all_references(
    directory: Path,
) -> Dict[Path, Set[ActionReference]]:
    all_references = {}
    for yaml_file in directory.rglob("*.yml"):
        if references := find_action_references(yaml_file):
            print(f"Found in {yaml_file}: {references}")
            all_references[yaml_file] = references
    return all_references


def get_hash_mapping(
    all_references: Dict[Path, Set[ActionReference]],
) -> Dict[str, str]:
    hash_mapping = {}

    for file, references in all_references.items():
        for ref in references:
            if ref.action_path in hash_mapping:
                continue
            latest_hash = get_latest_commit_for_path(ACTIONS_REPO_PATH, ref.action_path)
            hash_mapping[ref.action_path] = latest_hash
    return hash_mapping


def main():
    parser = argparse.ArgumentParser(
        description="Update XRPLF/actions hash references in GitHub workflow/action YAML files"
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Show what would be updated without making changes",
    )
    parser.add_argument("directory", type=Path, help="Path to directory")

    args = parser.parse_args()
    assert args.directory.is_dir(), "Provided path is not a directory"

    all_references = collect_all_references(args.directory)
    hash_mapping = get_hash_mapping(all_references)

    # Update files
    files_modified = 0
    total_updates = 0

    print("\n" + "=" * 80)
    print("Updates to be applied:" if args.dry_run else "Applying updates:")
    print("=" * 80)

    for file, references in all_references.items():
        content = file.read_text()
        old_content = content

        for ref in references:
            latest_hash = hash_mapping[ref.action_path]
            if ref.current_hash == latest_hash:
                continue

            old_ref = ref.full_match
            new_ref = f"XRPLF/actions/{ref.action_path}@{latest_hash}"

            print(f"- {file}: {old_ref} -> {new_ref}")

            content = content.replace(old_ref, new_ref)
            total_updates += 1

        if content == old_content:
            continue

        files_modified += 1

        if not args.dry_run:
            file.write_text(content)

    print("\n" + "=" * 80)
    if args.dry_run:
        print(
            f"Dry run complete: {total_updates} update(s) would be applied across {files_modified} file(s)"
        )
        print("Run without --dry-run to apply changes")
    else:
        print(f"Updated {total_updates} reference(s) in {files_modified} file(s)")
    print("=" * 80)


if __name__ == "__main__":
    main()
