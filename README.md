# actions

Reusable workflows and actions for XRPLF repos

## Available Actions

- `cleanup-workspace`: Cleans up the GitHub Actions workspace, should be used for self-hosted runners before running any steps.
- `get-nproc`: Retrieves the number of processing units available on the runner.
- `prepare-runner`: Prepares the GitHub Actions runner environment for subsequent steps.

## Available Reusable Workflows

- `pre-commit.yml`: Runs `pre-commit` checks on code changes.
- `pre-commit-autoupdate.yml`: Runs `pre-commit autoupdate` to update pre-commit hooks.

## Maintenance Tools

### update_hashes.py

A Python script to update hash references to XRPLF/actions in GitHub workflow/actions YAML files.

This script searches for references like:

- `XRPLF/actions/get-nproc@<hash>`
- `XRPLF/actions/.github/workflows/pre-commit.yml@<hash>`

Then updates them with the latest commit hash that modified the referenced directory.

**Usage:**

```bash
# Dry run (show what would be updated)
python3 update_hashes.py --dry-run /path/to/directory
```

**Arguments:**

- `--dry-run`: Show what would be updated without making changes (optional)
- Path to the git directory (positional argument)
