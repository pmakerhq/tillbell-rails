---
name: release
description: Release a new version of the Tillbell gem. Bumps the version and changelog in a pull request, tags the merge commit, and creates the GitHub release. The Release GitHub Action then publishes the gem to RubyGems by itself.
disable-model-invocation: true
argument-hint: "<patch|minor|major|x.y.z>"
---

# Release Tillbell

Publishing is the job of `.github/workflows/release.yml`: it runs when a `v*` tag is pushed, checks the tag against `Tillbell::VERSION` and that the commit is on `main`, runs RuboCop and the specs, then pushes the gem with the `GEM_HOST_API_KEY` secret. **Never run `gem push` by hand.** This skill prepares the version, creates the tag and the GitHub release, and watches the workflow.

Everything written to the repository or GitHub is in English.

## 1. Check the starting point

- `git status` is clean, the branch is `main`, and `git pull` has nothing to fetch.
- `gh auth status` works and `gh secret list` shows `GEM_HOST_API_KEY`. If not, stop and say so.
- `CHANGELOG.md` has entries under `## [Unreleased]`. If it is empty, stop: there is nothing to release.

## 2. Pick the version

`$ARGUMENTS` is `patch`, `minor`, `major` or an explicit version. Apply it to `Tillbell::VERSION` in `lib/tillbell/version.rb` (semantic versioning; breaking changes to the public API or to the bridge contract are `major`, or `minor` while the version is `0.x`). With no argument, propose a version from the changelog entries and ask.

A pre-release uses RubyGems' dot form, e.g. `0.2.0.pre1`, not `0.2.0-rc.1`. The tag is `v` followed by the exact `VERSION`.

Check that the tag `v<version>` does not exist yet, locally and on `origin`, and that the version is not already on RubyGems (`curl -s -o /dev/null -w "%{http_code}" https://rubygems.org/api/v2/rubygems/tillbell/versions/<version>.json` answers 404).

## 3. Prepare the release pull request

1. `git checkout -b release-v<version>`.
2. Set `VERSION` in `lib/tillbell/version.rb`.
3. In `CHANGELOG.md`, insert `## [<version>] - <today, YYYY-MM-DD>` right under `## [Unreleased]`, so the unreleased entries move under it and `Unreleased` stays empty.
4. Run `bin/rubocop` and `bin/rspec`; both must pass.
5. Commit `Release <version>`, push, and open the pull request.
6. Wait for CI. `gh pr checks` can answer "no checks reported" just after the PR is created, so retry it until the checks appear, then use `gh pr checks --watch`. Do not merge unless they all pass.
7. Squash-merge the pull request and delete the branch. The merge itself needs no confirmation: nothing is published until the tag is pushed.
8. `git checkout main && git pull`, then get the merge commit with `gh pr view <pr> --json mergeCommit --jq .mergeCommit.oid` and check that it equals `git rev-parse HEAD`.

## 4. Confirm, then tag

Show the version, the changelog section and the merge commit, and **ask for confirmation**: a pushed tag starts the publication, and a version published to RubyGems cannot be published again (it can only be yanked).

After a yes:

```sh
git tag -a v<version> -m "Tillbell <version>" <merge commit>
git push origin v<version>
```

## 5. Watch the publication

- Find the run of this tag: `gh run list --workflow release.yml --branch v<version> --limit 1` (a tag push reports the tag as its branch). The run can take a few seconds to appear, so retry until it does, then `gh run watch <id> --exit-status`.
- When it passes, check that the version is on RubyGems: the versions endpoint of step 2 answers 200 (RubyGems can take a minute). For a final version, `https://rubygems.org/api/v1/versions/tillbell/latest.json` returns it too; it never returns a pre-release.
- If the workflow fails, show the failing step and stop. Do not push the gem by hand. `gh run rerun <id>` replays the same tagged commit, so use it only for a cause outside the repository (secret, RubyGems outage, flaky run). A code fix needs a new version; deleting and re-creating the tag is allowed only if nothing reached RubyGems, and only after asking.

## 6. Create the GitHub release

Only once the gem is on RubyGems, so the release never announces a version that is not there. Write the changelog section of the version, without its heading, to a temporary file in the scratchpad directory and pass it as a file: the text contains backticks that a shell would run if it were quoted on the command line.

```sh
gh release create v<version> --verify-tag --title "Tillbell <version>" --notes-file <file>
```

Add `--prerelease` for a pre-release version.

Finish with the RubyGems and GitHub release links.
