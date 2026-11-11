# Changelog

All notable changes to this project are documented in this file. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project adheres to
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.6.0] - 2026-11-11

### Added

- App Store subscriptions, for the iOS app of [tillbell-ios](https://github.com/pmakerhq/tillbell-ios):
  `Pay::AppStore::Customer` and `Pay::AppStore::Subscription`, set up with
  `config.apple.bundle_id`. `POST /tillbell/purchases` accepts the signed StoreKit 2
  transaction the iOS app sends as its purchase token, verifies Apple's signature without
  calling Apple and checks its `appAccountToken`, the same account id as Google Play.
- `POST /tillbell/notifications/app_store` receives App Store Server Notifications (version 2),
  verified and processed through Pay like Google Play notifications: renewals, billing retries,
  grace periods, expiries and refunds keep the subscription current.
- `app_store?` and the `app_store` scope on Pay customers and subscriptions. `grants_access?`
  gives no access to an App Store subscription in billing retry after the grace period.

### Changed

- Bridge contract: a `pending` purchase reply may come without `purchaseToken`, for an App Store
  purchase waiting for approval (Ask to Buy). The paywall controller then shows the pending
  message. Copy the new `tillbell_controller.js` from the generator template into your app.
- The bridge contract documents how tillbell-ios maps it to StoreKit 2.

## [0.5.1] - 2026-11-11

### Changed

- The gem author and the license holder are now `pmakerhq`.
- The README no longer has an inspiration paragraph in its acknowledgements.

## [0.5.0] - 2026-11-02

### Added

- `grants_access?` on every Pay subscription: it bills and is not paused, and a Google Play
  subscription on hold gives no access (Google requires it), while a Stripe payment being
  retried does.
- `Pay::GooglePlay::Subscription#owned?`: Google still counts the purchase as the customer's
  (a paused subscription and a pending purchase included), so a new purchase would be answered
  `ALREADY_OWNED`.
- `Tillbell::GooglePlay.store_url`: the Play Store page of the app.

### Changed

- README: an "Upgrading" section, starting with 0.4. Documentation comments on `google_play?` (subscriptions),
  `Tillbell::GooglePlay.package_name` and `reset!`.

## [0.4.0] - 2026-10-30

### Added

- `Tillbell::Owner`, to include in the model that declares `pay_customer`: `google_play_subscription`,
  `google_play_on_hold?`, `current_subscription` (the best subscription across processors),
  `billing_subscriptions` and `cancel_billing_subscriptions!` (for closing or deleting an account).
- `billing?` on every Pay subscription: still billed, retried after a failed payment, or paused.
- Events `subscription_renewed`, `payment_failed`, `payment_recovered` and `plan_changed`. They are
  emitted next to the existing events, which are unchanged.
- `config.plans`, `Tillbell.plan`, `Tillbell.replacement_mode(from:, to:)` and `subscription.plan`:
  a catalog of the plans you sell. `tillbell:check` verifies them without `PLANS`.
- `paywall.plan_change(to:, from:)`: the option of a plan change, with the replacement mode chosen
  from the order of the catalog.
- `subscription.replaced_subscription` and `subscription.token_digest` (a purchase identifier that
  is safe to send to analytics).
- Paywall texts in French, Spanish and German (formal address). Their locales become available
  in the host app unless it sets `config.i18n.available_locales`.

### Changed

- `cancel` and `cancel_now!` raise a `Tillbell::Error` (a `Pay::Error`, with Google's error as its
  `cause`) instead of a `Google::Apis::Error` or a `Signet::AuthorizationError`, so a host app
  rescues Pay's error only. Code that rescued the Google errors from `cancel` must rescue
  `Pay::Error` too.

## [0.3.0] - 2026-10-30

### Added

- `bin/rails tillbell:check` (`Tillbell::Check`): checks the package name, the service account
  key, that the engine is mounted and the notification sender, without printing a secret.
  `ONLINE=1` also asks Google (the key, its rights, the subscriptions of the Play Console);
  `PLANS=premium:monthly,premium:yearly` checks the plans the app sells exist and are active.
- The install generator prints the credentials template and the next steps.

### Changed

- README, "Google Play setup": rewritten for someone who has never touched Google Play's
  consoles. What Google needs and why, a credentials template to fill in, a checklist, every
  step in the Play Console and the Cloud Console, the check, a test purchase and a
  troubleshooting table.

## [0.2.0] - 2026-10-30

### Added

- `Tillbell.native?(user_agent)` and the `tillbell_native?` view helper: tell whether the
  app showing the page registered the `tillbell` component, to choose between the paywall
  and another way to pay.
- Details of a `Pay::GooglePlay::Subscription` read from Google's last answer:
  `price_amount` and `price_currency`, `replacement?`, `linked_purchase_token`, `replaced?`,
  `plan_change_pending?`, `deferred_product_id` and `manage_url`.
- `Tillbell::GooglePlay.manage_url(product_id = nil)`: the Play Store page of a
  subscription, for web pages and emails.
- README: detecting the native app, plan changes (replacement modes, `DEFERRED`
  downgrades), subscription details, several processors per customer, closing an account,
  and events during a plan change.

### Changed

- A replaced subscription remembers the purchase token that replaced it (`data["replaced_by"]`)
  and keeps its ended state: a later read of the old token no longer brings it back.
- `cancel` decides whether to ask Google from its subscription state (canceled or expired)
  instead of `auto_renewing`, which is false while a deferred plan change waits for the renewal
  though the subscription will renew.

### Fixed

- `cancel` (and `cancel_now!`) on a subscription Google answers 410 for (a purchase token
  expired for more than 60 days) no longer raises: it made closing an account or deleting an
  owner fail for a customer who left long ago, including for a row still stored as active
  because a notification was missed. The subscription is recorded as ended and
  `subscription_expired` is emitted once. Other errors still raise.

## [0.1.1] - 2026-10-30

### Changed

- Internal: versions are now published to RubyGems by a GitHub Actions workflow when a
  `v*` tag is pushed. The gem itself is unchanged.

## [0.1.0] - 2026-10-30

### Added

- `Pay::GooglePlay` processor: Google Play subscriptions stored as Pay customers and
  subscriptions, next to Stripe or any other Pay processor.
- Server-side purchase verification (`POST /tillbell/purchases`) with an ownership check
  and server-side acknowledgment.
- Real-time developer notifications endpoint (`POST /tillbell/notifications/google_play`)
  authenticated with the Pub/Sub OIDC token and processed through Pay's webhook pipeline.
- Events: `subscription_created`, `subscription_updated`, `subscription_canceled`,
  `subscription_expired`, `subscription_revoked` and `purchase_rejected`.
- `tillbell_paywall` view helper, the `tillbell` Stimulus controller and the bridge
  contract (JSON Schemas) implemented by the native libraries.
- `rails generate tillbell:install`.
- `google_play?` on Pay customers and subscriptions, and a `google_play` scope on both.

### Fixed

- Paywall texts fall back to English in a locale that has no translation, instead of
  rendering a "translation missing" marker.
- Deleting an owner no longer fails on a subscription that already stopped renewing.
- A refunded subscription stays `canceled` when a later read reports it as active.
