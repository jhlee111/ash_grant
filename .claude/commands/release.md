# Release

End-to-end release workflow: analyze changes, update docs + version, verify, PR, merge, tag.
Run this on main after feature PRs are merged.

## Input

$ARGUMENTS — version number (e.g., `0.11.0`) or semver bump type (`major`, `minor`, `patch`).
If omitted, suggest version based on changes since last tag.

## Steps

### 1. Pre-checks

```bash
git checkout main && git pull
```

Verify clean working tree (no uncommitted changes except PLAN.md, docs/).

### 2. Analyze changes since last release

```bash
# Find last version tag
git describe --tags --abbrev=0

# All commits since last tag
git log --oneline <last-tag>..HEAD

# All changed files since last tag
git diff --stat <last-tag>..HEAD
```

Categorize:
- Features (feat:)
- Fixes (fix:)
- Docs (docs:)
- Refactors (refactor:)
- Tests (test:)

Determine version bump if not specified:
- Breaking change → major
- New feature → minor
- Bug fix / docs only → patch

### 3. Documentation gate

Check ALL of these before creating release branch:

**CHANGELOG.md:**
- Add new version section with date
- List all changes categorized by Added/Changed/Fixed/Removed
- Move from commit messages, but write user-facing descriptions (not just commit text)

**README.md:**
- Installation version matches new release?
- Any new features from this release missing from README?
- Examples still accurate with current API?
- Feature list at top of README reflects new capabilities?

**@moduledoc:**
- New public modules have `@moduledoc`?
- Changed modules have accurate `@moduledoc`?

**CLAUDE.md:**
- Architecture section reflects new modules?
- Any new commands, patterns, or test structures?

**usage-rules.md:**
- AI-agent-facing rulebook — audit as seriously as README.
- New DSL options / entities / recommended patterns since last release are surfaced as "DO:" rules?
- Deprecated or removed options are surfaced as "DON'T:" rules?
- Examples still reflect current API (e.g., post-deprecation they no longer demonstrate the deprecated path)?

**guides/*.md:**
- Final cross-link audit: `grep -l "<new-feature>" guides/` should match the guides where the feature is relevant. Missing entries indicate a gap.
- Any guide still recommending a pattern that is now deprecated or replaced?
- Examples tested / still compile after API changes in the release window?

**mix.exs:**
- `@version` updated to new version

If any docs need updating, make ALL changes in this step.

### 4. Code verification

Run all four checks. ALL must pass:

```bash
mix compile --warnings-as-errors
mix test
mix credo
mix format --check-formatted
```

### 5. Release branch + PR

```bash
git checkout -b release/v<version>
git add mix.exs CHANGELOG.md README.md usage-rules.md <guides/*.md if touched> <any other changed docs>
git commit -m "release: v<version>"
git push -u origin release/v<version>
gh pr create --title "release: v<version>" --body "..."
```

PR body format:
```
## Summary
- Bump version to <version>
- Update CHANGELOG.md

### What's new in v<version>
<bullet points from CHANGELOG>

## Post-merge
git checkout main && git pull
git tag v<version>
git push --tags
```

### 6. CI + Merge

```bash
gh pr checks <pr-number> --watch
gh pr merge <pr-number> --merge
```

### 7. Tag

```bash
git checkout main && git pull
git tag v<version>
git push --tags
```

### 8. Report

Show the user:
- Release version
- Tag URL
- CHANGELOG entry
- Any doc changes that were made
