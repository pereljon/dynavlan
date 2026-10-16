# 2026-10-16: Permission rules match the command as written

Status: active

## What happened

During the 1.1.1 release, auto mode denied `git -C /Users/jonathan/Claude/development/dynavlan push origin v1.1.1` with "[Create Public Surface]". `.claude/settings.local.json` already allowed `Bash(git push origin *)`. The same push, run as `git push origin v1.1.1` from the repo directory, succeeded at once. Earlier `git -C` commands for the merge and tag were also denied; some passed on a later retry. To keep `gh release create` and `gh repo edit` matching their allow rules, they ran without the usual `GH_TOKEN=$(gh auth token --user pereljon)` prefix, after `gh auth status` showed `pereljon` as the active account.

## Root cause

An allow rule matches the start of the command string. `git -C <path> push ...` does not start with `git push origin`, so the rule did not apply and auto mode's own check decided. Why some `git -C` retries later passed is unknown. The settings file may have changed between attempts; this was not checked.

## Rule(s)

- Run a command that an allow rule covers in exactly the rule's form: from the working directory, with no `git -C`, no `cd ... &&`, no env-var prefix and no chaining.
- Before using bare `gh` to fit an allow rule, confirm with `gh auth status` that the active account owns the repo. Otherwise use the `GH_TOKEN` prefix and expect a permission prompt.
- When auto mode denies an allowed action, compare the command with the rule's pattern before asking the user to change settings.

## Applies to

Git and `gh` steps for merge, push, tag and release, and any command meant to match a `permissions.allow` rule.
