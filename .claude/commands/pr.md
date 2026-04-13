# Create PR

End-to-end workflow: verify code, check docs, commit, push, create PR.
Run this after implementation is done and tests pass locally.

## Input

$ARGUMENTS — short description of changes (used for branch name and PR title)

## Steps

### 1. Code verification

Run all four checks in parallel. ALL must pass before proceeding:

```bash
mix compile --warnings-as-errors
mix test
mix credo
mix format --check-formatted
```

If any fail, fix the issue and re-run. Do not skip.

### 2. Analyze changes

Run `git diff HEAD` and `git status` to understand what changed.
Categorize changes:
- New modules added?
- Public API changed? (new functions, changed signatures, removed functions)
- New DSL options or entities?
- New behaviours or protocols?
- Config/dependency changes?

### 3. Documentation gate

Based on the change analysis, check EACH of these. Ask the user for confirmation before proceeding if any are needed:

**@moduledoc / @doc:**
- Every NEW public module has `@moduledoc`
- Every NEW public function has `@doc`
- Changed function signatures: is `@doc` still accurate?

**README.md:**
- New feature → needs section or mention in README?
- New DSL option → DSL Configuration table needs update?
- Changed API → Quick Start / examples still correct?
- Version in Installation section current?

**CLAUDE.md:**
- New module → Architecture section needs update?
- New command or workflow → Common Commands needs update?
- New test pattern → Test Structure needs update?

**usage-rules.md:**
- This file is the AI-agent-facing rulebook consumers of AshGrant follow — treat it with the same seriousness as README.
- New DSL option or entity → add to the DSL Configuration table / new section?
- New recommended pattern → add as a "DO:" rule?
- Deprecated or removed option → add as a "DON'T:" rule and update any examples still using it?
- Changed behaviour for an existing rule → update the rule's example and explanation?

**guides/*.md:**
- New feature has a dedicated guide → add cross-links from every other guide whose topic touches it (audit `grep -l "<new-feature>" guides/` and check omissions as deliberately as inclusions).
- Pattern was recommended-against → ensure the old-pattern guide text reflects the new recommendation.
- Examples in existing guides still compile / make sense after the change?

**CHANGELOG.md:**
- NOT updated here. CHANGELOG is updated during `/release` only.

If docs need updating, make the changes now before committing.

### 4. Branch, commit, push

```bash
# Determine branch type from changes (feat/, fix/, docs/, refactor/, test/)
git checkout -b <type>/<description>
# Stage relevant files (never git add -A)
git add <specific files>
# Commit with convention: <type>: <description>
git commit -m "<type>: <description>"
git push -u origin <branch>
```

### 5. Create PR

```bash
gh pr create --title "<type>: <description>" --body "..."
```

PR body format:
```
## Summary
<bullet points of what changed and why>

## Test plan
<checklist of what was tested>

🤖 Generated with [Claude Code](https://claude.com/claude-code)
```

### 6. Report

Show the user:
- PR URL
- Summary of what was included
- Any doc changes that were made
