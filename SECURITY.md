# Security policy

Tillbell handles purchases and grants access to paid features, so we take security reports seriously.

## Supported versions

Tillbell is in its first release cycle. Security fixes go to the latest released version only.

## Reporting a vulnerability

Please do not open a public issue, pull request or discussion for a security problem.

Report it privately through [GitHub's private vulnerability reporting](https://github.com/pmakerhq/tillbell-rails/security/advisories/new). Include:

- the affected version;
- a description of the problem and its impact (for example, access granted without a valid purchase);
- the steps to reproduce it.

You will get an answer within a few days. Once a fix is released, the advisory is published and you are credited, unless you prefer not to be.

## Scope

In scope: this gem, including purchase verification, the notification endpoint, the paywall helper and the Stimulus controller. Issues in Pay, Google's libraries or Hotwire Native belong to their own projects.
