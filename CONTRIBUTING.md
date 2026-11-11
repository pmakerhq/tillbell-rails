# Contributing to Tillbell

Thank you for helping. Bug reports, documentation fixes and pull requests are all welcome.

## Reporting a bug

[Open an issue](https://github.com/pmakerhq/tillbell-rails/issues/new/choose) with:

- the Tillbell, Pay, Rails and Ruby versions;
- what you did, what you expected and what happened;
- the relevant log lines. Tillbell never logs full purchase tokens, but check that your logs contain no credentials or personal data before pasting them.

The fastest way to get a bug fixed is a failing spec.

Security issues are different: do not open a public issue, follow [SECURITY.md](SECURITY.md).

## Proposing a change

For anything bigger than a small fix, open an issue first, so we can agree on the approach before you spend time on code. Changes to the bridge messages also affect [tillbell-android](https://github.com/pmakerhq/tillbell-android), so they start with an update of [docs/bridge-contract.md](docs/bridge-contract.md) and the JSON Schemas in [contract/](contract).

## Setting up

```sh
git clone https://github.com/pmakerhq/tillbell-rails.git
cd tillbell-rails
bundle install
bin/rspec
```

The suite runs against a dummy Rails app in `spec/dummy`. No test calls Google: the Google Play Developer API and the OIDC verification are stubbed, so you need no Google account.

To run the suite against another Rails version:

```sh
RAILS_VERSION="~> 8.0.0" bundle update rails && bin/rspec
```

CI runs Ruby 3.3, 3.4 and 4.0 against Rails 8.0 and 8.1.

## Pull requests

Before opening a pull request, make sure that:

- `bin/rspec` passes, and new behavior comes with specs;
- `bin/rubocop` reports no offenses (we follow [rubocop-rails-omakase](https://github.com/rails/rubocop-rails-omakase));
- every public class, module and method has a comment explaining what it does and why;
- user-facing changes are listed under `Unreleased` in [CHANGELOG.md](CHANGELOG.md), following [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
- the README is updated when configuration or behavior changes.

Keep pull requests focused on one change. Write commit messages in the imperative mood ("Add restore button", not "Added restore button").

Everything in this repository is written in English: code, comments, documentation, commits, issues and pull requests.

## License

By contributing, you agree that your contributions are licensed under the [MIT License](MIT-LICENSE).

## Releasing

Maintainers publish a version by moving the `Unreleased` entries of the changelog under the new version and bumping `lib/tillbell/version.rb` in a pull request. Once it is merged, tag the merge commit on `main` and push the tag:

```sh
git tag v0.1.1 && git push origin v0.1.1
```

The [Release workflow](.github/workflows/release.yml) checks that the tagged commit is on `main` and that the tag matches the version, runs RuboCop and the specs and pushes the gem to RubyGems. It needs a `GEM_HOST_API_KEY` repository secret.
