# actions

Reusable workflows and actions for XRPLF repos

## Available Actions

- `cleanup-workspace`: Cleans up the GitHub Actions workspace, should be used for self-hosted runners before running any steps.
- `get-nproc`: Retrieves the number of processing units available on the runner.
- `prepare-runner`: Prepares the GitHub Actions runner environment for subsequent steps.

## Available Reusable Workflows

- `pre-commit.yml` - runs `pre-commit` checks on code changes.
- `pre-commit-autoupdate.yml` - runs `pre-commit autoupdate` to update pre-commit hooks.
