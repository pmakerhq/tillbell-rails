# Tillbell

[![CI](https://github.com/pmakerhq/tillbell-rails/actions/workflows/ci.yml/badge.svg)](https://github.com/pmakerhq/tillbell-rails/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](MIT-LICENSE)

**Self-hosted in-app subscriptions for Rails + Hotwire Native apps, built on [Pay](https://github.com/pay-rails/pay).**

Your Android app sells subscriptions through Google Play. Your Rails app verifies them, acknowledges them and keeps them in sync. No third-party service sits between the store and your server, and no extra table is added: Google Play subscriptions are regular `Pay::Subscription` records, right next to your Stripe ones.

```ruby
user.pay_subscriptions.active            # Stripe and Google Play together
Pay::GooglePlay::Customer.for(user)     # the Google Play customer, next to Stripe
subscription.active?                     # same rules as for Stripe
```

> [!NOTE]
> **Status: v0.1, not released on RubyGems yet.** Google Play only for now. The App Store (StoreKit 2) is planned.

## Table of contents

- [Why Tillbell](#why-tillbell)
- [Quick start](#quick-start)
- [How it works](#how-it-works)
- [Requirements](#requirements)
- [Installation](#installation)
- [Upgrading](#upgrading)
- [Configuration](#configuration)
- [The paywall](#the-paywall)
- [Subscriptions and statuses](#subscriptions-and-statuses)
- [Events](#events)
- [Google Play setup](#google-play-setup)
- [Security](#security)
- [Troubleshooting](#troubleshooting)
- [The Tillbell family](#the-tillbell-family)
- [Getting help](#getting-help)
- [Contributing](#contributing)
- [Acknowledgements](#acknowledgements)
- [License](#license)

## Why Tillbell

- **Your server is the source of truth.** Every purchase is read back from Google before it grants anything.
- **One subscription model.** Web (Stripe, Paddle, ...) and Android subscriptions share Pay's tables, scopes and helpers.
- **Access is immediate.** The paywall posts the purchase as soon as Google Play confirms it, without waiting for a notification.
- **No vendor in the middle.** Google's real-time notifications go straight to your app. You pay no revenue share and keep your data.
- **Small and replaceable.** A Rails engine, one Stimulus controller and a [documented bridge contract](docs/bridge-contract.md).

## Quick start

Assuming a Rails 8 app with a `User` model and Pay installed:

1. Add the gems and run the installer:

   ```sh
   bundle add pay
   bundle add tillbell --github pmakerhq/tillbell-rails   # until the first RubyGems release
   bin/rails generate tillbell:install
   ```

2. Make the buyer a Pay customer:

   ```ruby
   class User < ApplicationRecord
     pay_customer
   end
   ```

3. Fill in `config/initializers/tillbell.rb`, and put the two values Google gives you in your credentials (the [Google Play setup](#google-play-setup) below has the template and every click):

   ```ruby
   Tillbell.configure do |config|
     config.google.package_name = "com.example.app"
     config.google.service_account_json = Rails.application.credentials.dig(:tillbell, :google_service_account)
     config.google.pubsub_service_account_email = Rails.application.credentials.dig(:tillbell, :pubsub_service_account_email)
   end
   ```

   Then `bin/rails tillbell:check` tells you what is still missing.

4. Render a paywall:

   ```erb
   <%= tillbell_paywall success_url: dashboard_path do |paywall| %>
     <%= paywall.plan_option product_id: "premium", base_plan_id: "monthly", checked: true do %>
       Premium, <%= paywall.price %> per month
     <% end %>
     <%= paywall.submit %>
     <%= paywall.fallback %>
   <% end %>
   ```

5. Gate features with Pay, whatever the store:

   ```ruby
   current_user.pay_subscriptions.active.any?
   ```

Then add [tillbell-android](https://github.com/pmakerhq/tillbell-android) to your Hotwire Native app, and do the [Google Play setup](#google-play-setup) if you have not yet: it is the part that happens on Google's side.

## How it works

```
 tillbell_paywall (Rails view) ──► "products" ──► native app ──► localized prices from Google Play
          │
          ▼  tap "Subscribe"
 Stimulus controller ──► "purchase" ──► native app ──► Google Play purchase sheet
          │                                (obfuscatedAccountId supplied by the server)
          ▼
 POST /tillbell/purchases (purchase token) ──► Rails reads the purchase from Google,
                                               checks it belongs to the signed-in owner,
                                               saves the Pay::Subscription, acknowledges it
 Google Pub/Sub ──► POST /tillbell/notifications/google_play ──► Pay::Webhook ──► re-read from Google
```

The page and the native app talk through a [Hotwire Native bridge component](https://native.hotwired.dev/overview/bridge-components) named `tillbell`. Its messages are specified in [docs/bridge-contract.md](docs/bridge-contract.md), with JSON Schemas in [contract/](contract).

- **The server never trusts the client.** A purchase made with another owner's account id is refused.
- **Notifications are triggers, not truth.** A notification only says which purchase changed. Tillbell reads the current state from Google, so duplicated or out-of-order notifications end in the same state.
- **Purchases are acknowledged on the server.** Google refunds subscriptions that are not acknowledged within three days. The native app never acknowledges.
- **Idempotent.** Syncing the same state twice changes nothing and emits no event.

## Requirements

| | Version |
|---|---|
| Ruby | 3.3+ (tested on 3.3, 3.4 and 4.0) |
| Rails | 8.0+ (tested on 8.0 and 8.1) |
| Pay | 12+, installed and migrated |
| Active Job | A queue backend in production (Solid Queue, Sidekiq, ...) |
| Android app | Hotwire Native with [tillbell-android](https://github.com/pmakerhq/tillbell-android) |

## Installation

```ruby
# Gemfile
gem "pay"
gem "tillbell"
```

```sh
bundle install
bin/rails pay:install:migrations db:migrate   # skip if you already use Pay
bin/rails generate tillbell:install
```

The generator:

- creates `config/initializers/tillbell.rb`;
- mounts the engine with `mount Tillbell::Engine, at: "/tillbell"` (change the path if you like);
- copies the Stimulus controller to `app/javascript/controllers/tillbell_controller.js`;
- pins `@hotwired/hotwire-native-bridge` with importmap. With a JavaScript bundler, run `npm install @hotwired/hotwire-native-bridge` yourself.

The model that buys subscriptions must be a Pay customer:

```ruby
class User < ApplicationRecord
  pay_customer
end
```

## Upgrading

Every release is listed in the [CHANGELOG](CHANGELOG.md). No release so far has added a migration.

### To 0.4

Nothing is required, but one behavior changes: `cancel` and `cancel_now!` on a Google Play subscription now raise a `Tillbell::Error` (a `Pay::Error`, with Google's error as its `cause`) instead of a `Google::Apis::Error` or a `Signet::AuthorizationError`. Code that rescued the Google errors around a cancellation, to close or delete an account for example, must rescue `Pay::Error`, which also covers Stripe:

```ruby
begin
  user.cancel_billing_subscriptions!
rescue Pay::Error => error
  # Stripe or Google Play refused: keep the account open and say why
end
```

Then, to drop the code you wrote around the gem:

- `include Tillbell::Owner` in your Pay customer model for `current_subscription`, `google_play_subscription`, `google_play_on_hold?`, `billing_subscriptions` and `cancel_billing_subscriptions!`;
- declare the plans you sell in `config.plans`: `tillbell:check` verifies them without `PLANS`, and `paywall.plan_change` chooses the replacement mode from their order;
- subscribe to `plan_changed`, `payment_failed`, `payment_recovered` and `subscription_renewed` instead of reading `saved_changes` in `subscription_updated`;
- send `subscription.token_digest` to analytics instead of hashing the purchase token yourself.

The existing events are unchanged. The paywall texts now exist in French, Spanish and German: if your app set `config.i18n.available_locales`, add the ones you want.

## Configuration

```ruby
# config/initializers/tillbell.rb
Tillbell.configure do |config|
  config.google.package_name = "com.example.app"
  config.google.service_account_json = Rails.application.credentials.dig(:tillbell, :google_service_account)
  config.google.pubsub_service_account_email = Rails.application.credentials.dig(:tillbell, :pubsub_service_account_email)
end
```

The values marked "credentials" below come from Google: the [Google Play setup](#google-play-setup) says where to find each one, and gives the template to fill in. `bin/rails tillbell:check` verifies them.

| Setting | Default | Description |
|---|---|---|
| `google.package_name` | (required) | Application id of the Android app. |
| `google.service_account_json` | (required) | JSON key (string or hash) of the service account that calls the Google Play Developer API. |
| `google.pubsub_service_account_email` | (required for notifications) | Service account the Pub/Sub push subscription signs its requests with. |
| `google.pubsub_audience` | endpoint URL | Audience of the Pub/Sub OIDC token. Set it when a proxy changes the URL Rails sees. |
| `current_owner` | `-> { current_user }` | Returns who is buying. Evaluated in the controller and in the view, so any helper available there works (`Current.user`, `current_account`, ...). |
| `parent_controller` | `"ApplicationController"` | Controller the purchase endpoint inherits from, to reuse your authentication, CSRF protection and error handling. |
| `plans` | `[]` | The plans you sell, lowest first: `[{ name: :solo, product_id: "app_solo", base_plan_id: "monthly" }, ...]`. `tillbell:check` verifies them, `subscription.plan` finds the one a subscription is on, and `Tillbell.replacement_mode` and `paywall.plan_change` use their order to tell an upgrade from a downgrade. |
| `subscription_name` | `->(product_id:, base_plan_id:) { Pay.default_product_name }` | Pay subscription `name` of a Google Play product, as used by `subscribed?(name:)`. |

## The paywall

```erb
<%= tillbell_paywall success_url: dashboard_path, class: "paywall" do |paywall| %>
  <%= paywall.plan_option product_id: "premium", base_plan_id: "monthly", checked: true do %>
    Monthly, <%= paywall.price %>
  <% end %>
  <%= paywall.plan_option product_id: "premium", base_plan_id: "yearly" do %>
    Yearly, <%= paywall.price %>
  <% end %>

  <%= paywall.submit %>
  <%= paywall.restore %>
  <%= paywall.manage %>
  <%= paywall.status %>
  <%= paywall.fallback %>
<% end %>
```

The markup is unstyled and every builder method accepts HTML attributes (`class:`, `data:`, ...). Texts default to the `tillbell.paywall` translations in [config/locales/en.yml](config/locales/en.yml). Override them in your locale files, or pass the text as the first argument (`paywall.submit "Go premium"`). English, French, Spanish and German are included (their locales become available in an app that does not set `config.i18n.available_locales`). A locale without translations falls back to English.

| Builder method | Renders |
|---|---|
| `plan_option(product_id:, base_plan_id: nil, checked: false, replacing: nil, replacement_mode: nil)` | A radio button wrapped in a label with the block's content. |
| `price(placeholder = "")` | Where the price localized by Google Play is written. Use it inside `plan_option`. |
| `submit(text)` | Starts the purchase of the checked plan. |
| `restore(text)` | Records again the purchases Google Play knows for the device, e.g. after a reinstall. |
| `manage(text)` | Opens the Play Store subscription page. |
| `status` | A polite live region for status messages ("We are checking your purchase", ...). |
| `fallback(text)` or `fallback { ... }` | Shown in a browser or in an app version without the native component. |

Prices always come from Google Play, never from your app.

**Without the native component** (a browser, or an old app version), the Stimulus controller does not connect. The buttons stay disabled, the fallback stays visible, and no purchase can start.

**Detecting the native app.** Hotwire Native lists the components an app registered in its user agent (`bridge-components: [haptic tillbell]`). To choose between the paywall and another way to pay, ask Tillbell instead of parsing it yourself:

```erb
<% if tillbell_native? %>
  <%= tillbell_paywall success_url: dashboard_path do |paywall| %> ... <% end %>
<% else %>
  <%= link_to "Subscribe on the web", checkout_path %>
<% end %>
```

In a controller, use `Tillbell.native?(request.user_agent)`. It only picks which page to show: a purchase is always verified with Google, so a forged user agent gains nothing. It answers `true` for any native app (Android today, iOS later) that registered the component, and `false` for browsers and for app versions without it.

**Plan changes.** Pass the current subscription and Google's [replacement mode](https://developer.android.com/google/play/billing/subscriptions#replacement-modes). Tillbell passes the mode through and never decides proration:

```erb
<%= tillbell_paywall success_url: settings_path do |paywall| %>
  <%= paywall.plan_option product_id: "family", base_plan_id: "monthly", checked: true,
        replacing: current_user.pay_subscriptions.google_play.active.first,   # the current Pay::GooglePlay::Subscription
        replacement_mode: "CHARGE_PRORATED_PRICE" do %>
    Switch to Family, <%= paywall.price %>
  <% end %>
  <%= paywall.submit "Switch to Family" %>
  <%= paywall.status %>
<% end %>
```

| Replacement mode | Use it for | Effect |
|---|---|---|
| `CHARGE_PRORATED_PRICE` | An upgrade to a more expensive plan (upgrades only) | Takes effect now. The customer pays the price difference for the rest of the period, and the billing date does not change. |
| `WITH_TIME_PRORATION` | An upgrade (Google's default) | Takes effect now. The value of the unused time is credited by pushing the next billing date forward. |
| `WITHOUT_PRORATION` | An upgrade that keeps a free period | Takes effect now. The new price applies from the next renewal. |
| `CHARGE_FULL_PRICE` | Switching to a longer billing period | Takes effect now. The customer is charged the full price of the new plan, and the remaining value of the old one is credited. |
| `DEFERRED` | A downgrade to a cheaper plan | Takes effect at the next renewal: the customer keeps what they paid for until then. |

Google recommends `CHARGE_PRORATED_PRICE` for an upgrade and `DEFERRED` for a downgrade. The server picks the mode, never the app, so a customer cannot choose a cheaper way to upgrade.

A purchase that replaces another (a plan change, or a customer who signs up again for a subscription that was canceled but had not lapsed) gets a new purchase token that points to the old one. Tillbell stores the new subscription, ends the old one, and emits `subscription_created` then `subscription_expired` (see [Events](#events)).

A `DEFERRED` change waits for the renewal. Google reports it on the **new** purchase: one line item for the entitlement that is about to end, carrying the product the customer is moving to, and one for the entitlement that follows. Until the renewal the new subscription keeps the current product as `processor_plan`, and `subscription.plan_change_pending?` and `subscription.deferred_product_id` tell where it is going, so the page can say "Switching to Solo on March 3" (`current_period_end`). After the renewal `processor_plan` is the new product. Only an active subscription that is still renewing can change plan: hide the option for a canceled (`on_grace_period?`) or held (`on_hold?`) one.

**JavaScript events.** The controller dispatches events on the paywall element:

- `tillbell:verified`: the purchase grants access. Call `event.preventDefault()` to stay on the page instead of visiting `success_url`.
- `tillbell:status`: a status message is shown (`event.detail` is `{ key, message }`).

The controller is copied into your app, so you can also change it.

## Subscriptions and statuses

Google states are mapped to Pay statuses, so Pay helpers behave as they do for Stripe:

| Google `subscriptionState` | Pay `status` | `active?` | Notes |
|---|---|---|---|
| `PENDING` | `incomplete` | no | Payment not confirmed yet (e.g. cash). |
| `ACTIVE` | `active` | yes | |
| `IN_GRACE_PERIOD` | `active` | yes | Google requires access during the grace period. `in_grace_period?` is true. |
| `ON_HOLD` | `past_due` | no | Payment failed after the grace period. `on_hold?` is true. |
| `PAUSED` | `paused` | no | |
| `CANCELED` | `active` with `ends_at` | until `ends_at` | Will not renew. `canceled?` and `on_grace_period?` are true. |
| `EXPIRED` | `canceled` | no | |
| refunded (revoked) | `canceled`, `ends_at` = now | no | `revoked?` is true. |

Whether a status grants access is your decision. The recommended default is `subscription.active?`, which follows Google's rules above.

A `Pay::GooglePlay::Subscription` stores:

- `processor_id`: the purchase token;
- `processor_plan`: the Google product id;
- `data`: `base_plan_id`, `subscription_state`, `auto_renewing` and `revoked_at`;
- `object`: Google's last answer.

**Details from Google.** These read Google's last answer, so they cost no API call:

| Method | Returns |
|---|---|
| `price_amount`, `price_currency` | The price of one renewal as a `BigDecimal` in the units of its currency (`12.99`, or `1200` yen) and its ISO currency (`"EUR"`), as Google bills it in the customer's country. For analytics and conversion events (e.g. a Meta or Google Ads purchase, which take a decimal value); show prices to customers from Google Play, as the paywall does. It is the price of the entitlement in force. `nil` when Google gave none. |
| `replacement?`, `linked_purchase_token` | Whether this purchase replaces an earlier one, and the token of that one. Google sets it for a plan change, for a customer who signs up again for a subscription that was canceled but had not lapsed, and for prepaid plans converted to or topped up as auto-renewing. Compare `processor_plan` with the replaced subscription's to tell a plan change. |
| `replaced?` | Whether a newer purchase replaced this subscription. Set when the replacement is recorded, so it is already true inside the `subscription_expired` callback; use it to tell a replaced subscription from a customer who left (see [Events](#events)). Subscriptions replaced before this was added are not flagged. |
| `plan_change_pending?`, `deferred_product_id` | A `DEFERRED` plan change waiting for the next renewal, and the product it goes to. |
| `manage_url` | The Play Store page where the customer manages this subscription (update the payment method, cancel, resubscribe). Same page as `paywall.manage`, for web pages and emails. `Tillbell::GooglePlay.manage_url(product_id)` gives it for any product, and without one the list of all subscriptions. `Tillbell::GooglePlay.store_url` is the page of the app itself, for a "Get it on Google Play" link. |
| `owned?` | Whether Google still counts the purchase as the customer's, even without access: a paused subscription or a pending purchase (a cash payment) too. Buying the same product again would be answered `ALREADY_OWNED`, so show `manage_url` instead of a paywall. False once refunded, replaced or expired. |
| `in_grace_period?`, `on_hold?`, `revoked?` | The Google states that Pay statuses merge. |

**Plans.** Declare what you sell in `config.plans` and Tillbell knows the rest:

```ruby
config.plans = [
  { name: :solo, product_id: "app_solo", base_plan_id: "monthly" },
  { name: :family, product_id: "app_family", base_plan_id: "monthly" }
]

subscription.plan                                     # => #<data Tillbell::Plan name=:family, ...>, or nil if it is not in the catalog
Tillbell.plan(:family)                                # by name, or Tillbell.plan(product_id: "app_family", base_plan_id: "monthly")
Tillbell.replacement_mode(from: :solo, to: :family)   # => "CHARGE_PRORATED_PRICE" (upgrade); a downgrade gives "DEFERRED"
```

A plan change from the settings page is then one option in a paywall:

```erb
<%= tillbell_paywall(success_url: settings_path) do |paywall| %>
  <%= paywall.plan_change(to: :family, from: current_user.google_play_subscription) { "Switch to Family" } %>
  <%= paywall.submit %>
  <%= paywall.status %>
  <%= paywall.fallback %>
<% end %>
```

`token_digest` is a stable identifier of a purchase that is safe to send to an analytics or advertising service (an event id that deduplicates); the purchase token itself must never leave your server.

**Owners with several processors.** `include Tillbell::Owner` in the model that declares `pay_customer`:

| Method | Returns |
|---|---|
| `google_play_subscription` | The Google Play subscription, whatever the default processor. |
| `google_play_on_hold?` | True when Google suspended the subscription for a failed payment: send the customer to `manage_url` rather than to a second subscription, which would bill twice if Google's retry succeeds. |
| `current_subscription` | The subscription to show and decide access from: the one that renews, then one that is canceled but running, then one whose payment is retried or that is paused; the most recent breaks a tie. |
| `billing_subscriptions` | What still bills or resumes by itself (`subscription.billing?`), Google Play first. |
| `cancel_billing_subscriptions!` | Cancels them: call it before closing or deleting an account. |

**Who has access.** `subscription.grants_access?`, on every Pay subscription, is true when it bills (`billing?`) and is not paused. A payment the processor retries keeps access, so the customer can reach the page where they fix it, except on Google Play: a subscription on hold comes after Google's grace period, and Google requires access to be suspended until the payment succeeds.

```ruby
def subscribed? = !!current_user.current_subscription&.grants_access?
```

A customer can have a Stripe subscription and a Google Play one (a web customer who later subscribes in the app, or the reverse). `Pay::GooglePlay::Customer` is never the owner's default payment processor, so `owner.payment_processor` does not see Google Play subscriptions: look at `owner.pay_subscriptions`, or at the Google Play customer (`owner.pay_customers.google_play.first`), to decide who has access.

Pay only knows its own processors, so Tillbell adds `google_play?` to customers and subscriptions, and a `google_play` scope next to Pay's `stripe` one (`Pay::Subscription.google_play`).

`subscription.cancel` stops the renewal through the Google Play Developer API; the customer keeps access until the end of the paid period. Google can only end a subscription immediately by refunding it, which Tillbell never does on its own, so `cancel_now!` (which Pay calls when an owner is destroyed) also just stops the renewal. Google answers 410 for a purchase token that expired more than 60 days ago: a subscription still stored as active (a missed notification) is then recorded as ended, with a `subscription_expired` event, instead of failing the deletion of its owner. Any other error is raised, a 404 from a wrong package name for example: the subscription may still be billing. A subscription ended or already canceled is left alone, and one that waits for a deferred plan change is cancelled like any other: whether it is renewing comes from Google's subscription state, not from the entitlement about to end. `swap`, `pause` and `resume` raise `Tillbell::Error`: plan changes go through the paywall, and the rest happens in the Play Store.

**Closing or deleting an account.** Cancel what still bills before you close the account, whatever the processor, and before changing anything in your database: an error raised after the account is closed leaves the subscription billing a closed account. Pay's own hook when an owner is destroyed only cancels `active` subscriptions. Google keeps retrying a held payment (`past_due`) and resumes a paused subscription by itself, so include both:

```ruby
user.cancel_billing_subscriptions!   # with Tillbell::Owner: what `billing?` says still bills, Google Play first
```

`billing?` is true for an active subscription (a canceled one that has not ended included), one whose payment is retried (`past_due`, `unpaid`) and a paused one, which resumes by itself, a Stripe pause (status `active`) included. A Google Play purchase still pending (a cash payment) is not: Google cannot cancel it until it completes. Google can fail (API error, revoked service account key): `cancel` raises a `Tillbell::Error`, a `Pay::Error` whose `cause` is Google's error, so rescuing `Pay::Error` next to your other processors' errors is enough. Tell the customer to try again.

## Events

```ruby
Tillbell.configure do |config|
  config.on(:subscription_created)  { |subscription| WelcomeMailer.with(user: subscription.owner).premium.deliver_later }
  config.on(:subscription_updated)  { |subscription| }  # renewal, grace period, hold, recovery, plan change
  config.on(:subscription_renewed)  { |subscription| }  # a new period started (also fires subscription_updated)
  config.on(:payment_failed)        { |subscription| }  # a payment failed: the grace period or the hold started (also fires subscription_updated)
  config.on(:payment_recovered)     { |subscription| }  # the payment went through after a failure
  config.on(:plan_changed)          { |subscription| }  # the customer is now on another product or base plan; subscription.replaced_subscription is the previous purchase, if any
  config.on(:subscription_canceled) { |subscription| }  # will not renew; access until ends_at
  config.on(:subscription_expired)  { |subscription| }
  config.on(:subscription_revoked)  { |subscription| }  # refunded or charged back
  config.on(:purchase_rejected)     { |details| }       # { owner:, purchase_token: } posted by another account
end
```

A plan change fires `subscription_created` for the new purchase (`replacement?` is true), `subscription_expired` for the old one (`replaced?` is true) and then `plan_changed` once. `subscription_updated` fires for every change, a renewal included; `subscription_renewed`, `payment_failed`, `payment_recovered` and `plan_changed` say which one happened (`payment_failed` fires on the first failure only, not again when the grace period turns into a hold), so you rarely need to filter it yourself. If you do, for example in a Slack or analytics subscriber:

```ruby
Tillbell.on(:subscription_updated) do |subscription|
  changes = subscription.saved_changes.keys
  notify("Payment on hold") if changes.include?("status") && subscription.on_hold?
end

Tillbell.on(:subscription_expired) do |subscription|
  notify("Subscription ended") unless subscription.replaced?   # not a plan change
end
```

Events go through Pay's webhook delegator, so `Pay::Webhooks.delegator.subscribe "tillbell.subscription_created", MyHandler.new` works too. An event fires once per actual change, after the subscription is saved. An error raised in a callback is reported to `Rails.error` and does not undo the change.

## Google Play setup

Tillbell needs two things from Google: **permission to read and acknowledge your customers' purchases**, and **a way to hear about renewals, cancellations and refunds**. Setting that up takes about 30 minutes of clicking in two Google websites:

| Website | What lives there | Called here |
|---|---|---|
| [Google Play Console](https://play.google.com/console) | Your app, your subscriptions, who may access them | **Play Console** |
| [Google Cloud Console](https://console.cloud.google.com) | Service accounts (the identities your server uses) and Pub/Sub (the mailbox Google drops notifications in) | **Cloud Console** |

You end up with **two values to give your app**: the JSON key of a service account, and the e-mail address of a second service account.

> [!NOTE]
> Google's menus move now and then. The names below are the ones to look for; if one has changed, search the console for it.

### Before you start

- A Google Play developer account, with your app created in the Play Console.
- A payments profile (merchant account) linked to the developer account: Google asks for it when you create a paid product.
- **A build of your app that includes the Google Play Billing Library, published to a testing track** (the Internal testing track is enough). Google does not let you create subscriptions until it has seen one. [tillbell-android](https://github.com/pmakerhq/tillbell-android) brings the Billing Library, so upload a build of your Hotwire Native app that includes it.
- Your Rails app deployed on a public HTTPS address (Google must be able to call it).

### The template to fill in

Put the two values in your Rails credentials (`bin/rails credentials:edit`, or `bin/rails credentials:edit --environment production`), under the `tillbell` key. The generated initializer reads them from there. Replace everything between `<` and `>`:

```yaml
tillbell:
  # Step 2: the whole JSON key file of the service account that calls Google.
  # Keep the "|" and the two-space indentation, or the key is unreadable.
  google_service_account: |
    {
      "type": "service_account",
      "project_id": "<your-cloud-project>",
      "private_key_id": "...",
      "private_key": "-----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----\n",
      "client_email": "<tillbell-api>@<your-cloud-project>.iam.gserviceaccount.com",
      "client_id": "...",
      "token_uri": "https://oauth2.googleapis.com/token"
    }
  # Step 4: the e-mail address of the service account Pub/Sub signs its notifications with.
  pubsub_service_account_email: <tillbell-push>@<your-cloud-project>.iam.gserviceaccount.com
```

Two more settings live in the initializer, not in the credentials: `config.google.package_name` (the application id of your Android app, for example `com.example.app`) and, only if a proxy changes the address Rails sees, `config.google.pubsub_audience` (see [Configuration](#configuration)).

`rails generate tillbell:install` prints this template when it finishes.

### The checklist

Copy it into your tracker and tick it as you go. Each step is explained below.

```markdown
- [ ] 0. Developer account, app created, payments profile, a build with the Billing Library on a testing track
- [ ] 1. Subscriptions created in the Play Console, base plan active (note the product and base plan ids)
- [ ] 2. Service account "tillbell-api" created, API enabled, JSON key downloaded
- [ ] 3. That service account invited in the Play Console with the two permissions (then wait, up to a day)
- [ ] 4. Service account "tillbell-push" created (no role, no key), e-mail copied
- [ ] 5. Pub/Sub topic created, Google Play allowed to publish to it
- [ ] 6. Push subscription created: your URL, authentication on, "tillbell-push"
- [ ] 7. Credentials filled in and deployed, `bin/rails tillbell:check` passes
- [ ] 8. Topic connected in the Play Console, test message sent and received
- [ ] 9. License testers added, test purchase made
```

### 1. Create your subscriptions (Play Console)

*Monetize with Play* → *Products* → *Subscriptions* → *Create subscription*.

- The **product ID** names the subscription (`premium`). You pass it as `product_id:` to `plan_option`.
- Each subscription has one or more **base plans** (`monthly`, `yearly`), with their own ID, billing period and price. You pass it as `base_plan_id:`. A base plan must be **Active** to be sold.
- Neither ID can be changed later, so pick them carefully.

### 2. Create the service account that calls Google (Cloud Console)

A *service account* is an identity for a program instead of a person. Your server uses this one to ask Google "what is the state of this purchase?" and to acknowledge it.

1. Pick (or create) a Cloud project. Any project works: what ties the service account to your app is the invitation of step 3.
2. *APIs & Services* → *Library* → search **Google Play Android Developer API** → *Enable*.
3. *IAM & Admin* → *Service Accounts* → *Create service account*. Name it `tillbell-api`. Give it **no role** here.
4. Open it → *Keys* → *Add key* → *Create new key* → **JSON**. A file downloads. **Google shows it only once**: that file is the `google_service_account` of the template. Treat it like a password, and never commit it.

Its e-mail address (`client_email` in the file) is needed in the next step. If *Create new key* is greyed out or refused, an organization policy blocks service account keys: see [If something is off](#if-something-is-off).

### 3. Let that service account into the Play Console

The Cloud Console knows the account exists. The Play Console must also allow it.

*Users and permissions* → *Invite new users* → paste the service account's e-mail address, then open the **App permissions** tab → *Add app* → your app, and tick:

- **View financial data** (the account-level tab calls it *View financial data, orders and cancellation survey responses*);
- **Manage orders and subscriptions**.

Send the invitation. A service account does not need to accept it, but Google can take **up to a day** to apply the permissions, so a `401` or `403` in step 7 right after this step is normal.

### 4. Create the account that signs notifications (Cloud Console)

When Google tells your server about a renewal, your server must know the call really comes from Google's Pub/Sub. Pub/Sub proves it by signing each call with a service account of your choice. You create that one now, and give your app its e-mail address so it can recognize the signature.

*IAM & Admin* → *Service Accounts* → *Create service account*, named `tillbell-push`. It needs **no role and no key**: it is only a name Pub/Sub signs with. Copy its e-mail address: that is `pubsub_service_account_email` of the template.

### 5. Create the Pub/Sub topic (Cloud Console)

A *topic* is the mailbox Google Play drops notifications in.

1. *Pub/Sub* → *Topics* → *Create topic* (enable the Pub/Sub API if asked). Name it `play-notifications`. Note its full name: `projects/<your-cloud-project>/topics/play-notifications`.
2. Open the topic → *Permissions* → *Add principal*: `google-play-developer-notifications@system.gserviceaccount.com`, role **Pub/Sub Publisher**. That is Google Play itself, allowed to write in your mailbox.

### 6. Make the topic call your server (Cloud Console)

A *push subscription* forwards each message to a URL.

Open the topic → *Create subscription*:

- **Delivery type**: *Push*.
- **Endpoint URL**: `https://<your-domain>/tillbell/notifications/google_play` (the path follows where you mounted the engine). It must be public HTTPS, with **no query string and no trailing slash**: the audience below is compared to it exactly. Behind a proxy that terminates TLS, Rails must know the request was HTTPS (`X-Forwarded-Proto`).
- **Enable authentication**: ticked, with the service account of step 4 (`tillbell-push`).
- **Audience**: leave empty. It then defaults to the endpoint URL, which is what Tillbell expects.

Two permissions can get in the way:

- If Google refuses to create the subscription with authentication, your own Google account needs the **Service Account User** role on `tillbell-push`.
- Pub/Sub's own service agent (`service-<project-number>@gcp-sa-pubsub.iam.gserviceaccount.com`) must be allowed to create tokens for `tillbell-push`: give it the **Service Account Token Creator** role on that account. Google's console steps say to check it, and projects that enabled Pub/Sub long ago need it explicitly. Without it, pushes fail silently.

### 7. Fill in the credentials, deploy and check

Put the two values in your credentials (see the template), set `config.google.package_name`, and **deploy**: the next step needs your server to be able to accept Google's notifications. Then run the check where the credentials are available. The simplest is on the server; locally, `RAILS_ENV=production` boots your production environment, which may need its other environment variables (database, `SECRET_KEY_BASE`) and your production key.

```sh
bin/rails tillbell:check                       # reads your configuration, asks nobody
ONLINE=1 PLANS=premium:monthly,premium:yearly bin/rails tillbell:check   # also asks Google
```

`PLANS` lists the `product_id:base_plan_id` pairs your app sells; each must exist in the Play Console with an active base plan. Without `PLANS`, `ONLINE=1` lists the subscriptions Google knows. With `ONLINE=1` the check also asks Google to read a purchase that cannot exist: "unknown purchase" means the service account may read purchases, a permission error means it may not. It changes nothing on Google and never prints a secret.

What it cannot try is acknowledging a purchase, which needs a real one: step 9 does. A healthy run:

```
OK   Android package name: com.example.app
OK   Service account key (config.google.service_account_json): tillbell-api@my-project.iam.gserviceaccount.com
OK   Engine mounted: /tillbell/purchases and /tillbell/notifications/google_play
OK   Notification sender (config.google.pubsub_service_account_email): tillbell-push@my-project.iam.gserviceaccount.com
OK   Notification audience: default: the notification URL as Rails sees it
OK   Reading purchases: allowed (Google answered that the test token is unknown, as expected)
OK   Subscription premium (base plan monthly): active
OK   Subscription premium (base plan yearly): active

Everything is in place.
```

Add `ONLINE=1` to your deploy checklist: it is the quickest way to learn that a key was revoked.

### 8. Connect Google Play to the topic (Play Console)

*Monetize with Play* → *Monetization setup* → *Real-time developer notifications*: tick **Enable real-time notifications**, enter the full topic name from step 5, choose the notification content that covers **subscriptions and all voided purchases** (Tillbell handles both), save, then click **Send test message**.

The Play Console's success message only means the message reached **your topic**. Whether it reached your server is shown by your logs: `[Tillbell] Google Play notification test_notification`, and a 200 answer. A 401 there is the sender or the audience (see below). Without these notifications your app still sells subscriptions, but renewals and cancellations are never seen, and a purchase your server did not acknowledge is refunded by Google after three days.

### 9. Test a purchase

1. Play Console → *Settings* → *License testing*: add the Google accounts of your testers. They buy with test payment methods (pick the test card in the purchase sheet) and are not charged. Test subscriptions renew much faster than real ones, so you can watch a renewal and a cancellation: a monthly subscription renews every 5 minutes, a yearly one every 30, at most 6 times.
2. Install your app on a device signed in with a tester account. License testers can install a build straight from their computer as long as the package name matches, or from the *Internal testing* opt-in link (a release on a testing track can take a few hours to reach testers).
3. Open the paywall, buy, and watch `Pay::GooglePlay::Subscription` appear in your database. Then check that Google did not mark the purchase as unacknowledged: it should stay in your database as active after a few minutes.

### If something is off

`bin/rails tillbell:check` names the cause of most problems. The rest:

| What you see | Likely cause | What to do |
|---|---|---|
| `not JSON`, or `private_key is missing or unreadable` | The key was pasted with a wrong indentation, or cut | Paste the whole key file again, with the `\|` and two spaces of indentation |
| `ONLINE=1`: *not authorized (401)* or *not allowed (403)* | Step 3 is missing or not applied yet, the permissions are not the two above, or (403) the API is not enabled in the project of the key | Check the invitation and the API (step 2.2), and wait up to a day |
| `ONLINE=1`: *not found (404)* | Wrong package name, or no such product in the Play Console | Compare with the Play Console |
| `ONLINE=1`: *key refused* | The key was deleted or rotated, or belongs to another project | Create a new JSON key and replace it |
| *Create new key* is greyed out or refused | An organization policy blocks service account keys (common on organizations created recently) | An organization administrator must allow key creation for this project |
| `Google was not asked` | An offline check failed | Fix the failures above it, then run again |
| The test message answers 401 in your logs | `pubsub_service_account_email` is not the account of step 4, or the audience differs | Compare the e-mails; if a proxy changes the URL Rails sees, set `config.google.pubsub_audience` to the same value as the subscription's *Audience* |
| Nothing arrives at your server | The endpoint URL is wrong, not public HTTPS, or the topic is not the one in the Play Console; or Pub/Sub's service agent cannot create tokens (step 6) | Check steps 5 to 8; the subscription's *Unacked messages* graph in the Cloud Console shows whether Google writes |
| The buy button stays disabled | The app does not register the `tillbell` component, or this is a browser | Use the app with [tillbell-android](https://github.com/pmakerhq/tillbell-android) |
| A purchase works, then Google refunds it after three days | Your server did not acknowledge it: the purchase endpoint failed | Look at your logs for the purchase request; run `bin/rails tillbell:check` |

## Security

- The purchase endpoint inherits from your `ApplicationController`, so your authentication and CSRF protection apply. It never trusts an owner or account id sent by the client.
- Every purchase is read back from Google, and the purchase's `obfuscatedAccountId` must match the signed-in owner's Google Play customer.
- Notifications must carry an OIDC token signed by Google for the configured service account. Anything else gets a 401.
- The account id sent to Google is a random UUID, never an e-mail or a database id.
- Purchase tokens are never logged in full.

Found a vulnerability? Please report it privately, as described in [SECURITY.md](SECURITY.md).

## Troubleshooting

Problems on Google's side (credentials, permissions, notifications) have their own table at the end of the [Google Play setup](#google-play-setup), and `bin/rails tillbell:check` names the cause of most of them.

**The paywall buttons stay disabled.** The page is not running inside an app that registers the `tillbell` bridge component (a browser, or an app without [tillbell-android](https://github.com/pmakerhq/tillbell-android)). This is expected: the fallback is shown instead.

**`POST /tillbell/purchases` answers 401.** `current_owner` returned `nil`: the request is not signed in, or `current_owner` does not match your authentication.

**A purchase is `rejected`.** It was made with the Google Play account id of another owner, for example after switching users on the same device.

**A purchase stays in `verifying`.** Google could not be reached. The purchase is verified by `Tillbell::SyncJob`, so check that your Active Job backend is running.

**Notifications answer 401.** The Pub/Sub token does not match the configuration. Check `google.pubsub_service_account_email`, and set `google.pubsub_audience` when a proxy or load balancer changes the URL Rails sees.

## The Tillbell family

| Repository | Purpose |
|---|---|
| **tillbell-rails** (this repo) | Rails engine: Pay processor, purchase verification, notifications, paywall helper |
| [tillbell-android](https://github.com/pmakerhq/tillbell-android) | Hotwire Native bridge component for Google Play Billing |
| [tillbell-ios](https://github.com/pmakerhq/tillbell-ios) | Hotwire Native bridge component for StoreKit 2 (planned) |

## Getting help

- Questions and bug reports: [open an issue](https://github.com/pmakerhq/tillbell-rails/issues/new/choose).
- Security issues: see [SECURITY.md](SECURITY.md). Do not open a public issue.
- Changes between versions: [CHANGELOG.md](CHANGELOG.md).

## Contributing

Bug reports, documentation fixes and pull requests are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) to set up the project, run the tests and open a pull request. In short:

```sh
git clone https://github.com/pmakerhq/tillbell-rails.git
cd tillbell-rails
bundle install
bin/rspec      # test suite, with a dummy app in spec/dummy; Google is stubbed
bin/rubocop    # rubocop-rails-omakase
```

## Acknowledgements

Tillbell stands on [Pay](https://github.com/pay-rails/pay), by Chris Oliver and contributors.

## License

Tillbell is open source under the [MIT License](MIT-LICENSE).
