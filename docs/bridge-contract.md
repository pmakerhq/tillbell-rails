# Bridge contract

This document specifies the messages exchanged between the Tillbell paywall (a Rails page
with the `tillbell` Stimulus controller) and the native `tillbell` bridge component of a
Hotwire Native app. It is the specification of
[tillbell-android](https://github.com/pmakerhq/tillbell-android) and of the future
tillbell-ios. You do not need to read the Ruby code to implement it.

Every message is described by a JSON Schema (draft 2020-12) in [`contract/`](../contract), with
examples in [`contract/examples/`](../contract/examples). The Rails test suite validates every
example against its schema; native libraries should validate their replies against the same
files (copy them or fetch them from this repository at a tagged version).

## Transport

Messages use the [Hotwire Native bridge](https://native.hotwired.dev/overview/bridge-components)
(`@hotwired/hotwire-native-bridge`, formerly Strada).

- **Component name:** `tillbell`. The native app registers a `BridgeComponent` with this
  name; it coexists with any other component.
- The page sends `products`, `purchase`, `restore` and `manage`. The native component answers
  the first three by replying to the same message (`replyTo(event, data)` on Android);
  `manage` gets no reply.
- The bridge adds a `metadata` object (`{ "url": ... }`) to every message the page sends.
  Native code ignores it.
- The page only loads the controller when the app's user agent lists the `tillbell`
  component. In a browser, or in an app version without the component, the paywall shows its
  fallback and no message is ever sent.

## Rules for native implementations

- **The server decides.** The native side runs the purchase flow and reports the result. It
  never decides who has access.
- **Never acknowledge purchases.** The server acknowledges after verifying them.
  Acknowledging on both sides is a bug.
- **Identifiers come from the server.** Pass `obfuscatedAccountId` unchanged to
  `BillingFlowParams.Builder.setObfuscatedAccountId`. Never derive an identifier on the device,
  and never use an e-mail.
- **Prices come from Google Play** (`ProductDetails`), never from the app or the page.
- **Pending purchases** must be enabled (`enablePendingPurchases`), as Play requires.
- **Always reply** to `products`, `purchase` and `restore`, including on errors, so the page
  never waits forever.

## Messages

### `products`

The page asks for the price of every plan it shows, as soon as it connects.

Request ([schema](../contract/products.request.json)):

```json
{ "products": [ { "productId": "premium", "basePlanId": "monthly" },
                { "productId": "premium", "basePlanId": "yearly" } ] }
```

`basePlanId` is `null` when the page does not name a base plan; the native side then uses the
product's only base plan.

Reply ([schema](../contract/products.reply.json)):

```json
{ "result": "ok",
  "products": [ { "productId": "premium", "basePlanId": "monthly", "formattedPrice": "€4.99" },
                { "productId": "premium", "basePlanId": "yearly", "formattedPrice": "€49.99" } ] }
```

- `formattedPrice` is the `formattedPrice` of the base plan's regular (last) pricing phase.
- Plans Google Play does not know are left out; the page disables them.
- `result` is `unavailable` when billing cannot be used on the device
  (`BILLING_UNAVAILABLE`), and `error` otherwise. `products` is then omitted and `message` may
  carry a developer-facing detail.

The page enables its buttons only after an `ok` reply.

### `purchase`

The customer tapped "Subscribe". The native side launches the Google Play purchase sheet.

Request ([schema](../contract/purchase.request.json)):

```json
{ "productId": "premium", "basePlanId": "monthly",
  "obfuscatedAccountId": "6f1c2a8e-3b7d-4e59-9a0c-2d4f8b1e7c35" }
```

**Plan change.** When the page replaces an existing subscription, it adds the old purchase
token and Google's replacement mode. Pass both to `SubscriptionUpdateParams`; never choose a
mode on the device:

```json
{ "productId": "premium", "basePlanId": "yearly",
  "obfuscatedAccountId": "6f1c2a8e-3b7d-4e59-9a0c-2d4f8b1e7c35",
  "oldPurchaseToken": "old-purchase-token", "replacementMode": "CHARGE_PRORATED_PRICE" }
```

`replacementMode` is one of `WITH_TIME_PRORATION`, `CHARGE_PRORATED_PRICE`,
`WITHOUT_PRORATION`, `CHARGE_FULL_PRICE`, `DEFERRED` (`SubscriptionUpdateParams.ReplacementMode`).

Reply ([schema](../contract/purchase.reply.json)):

```json
{ "result": "purchased", "productId": "premium", "purchaseToken": "..." }
```

| `result` | When | Fields |
|---|---|---|
| `purchased` | `PurchasesUpdatedListener` returns `OK` with a purchase in state `PURCHASED` | `productId`, `purchaseToken` |
| `pending` | `OK` with a purchase in state `PENDING` (e.g. cash payment) | `productId`, `purchaseToken` |
| `canceled` | `USER_CANCELED` | none |
| `already_owned` | `ITEM_ALREADY_OWNED` | none |
| `unavailable` | `BILLING_UNAVAILABLE`, `SERVICE_UNAVAILABLE`, `FEATURE_NOT_SUPPORTED` | `message` (optional) |
| `error` | any other code, or no purchase in the result (for a plan change, after looking the new purchase up, below) | `message` (optional) |

**Plan change without its new purchase in the result.** A plan change can succeed without the new
purchase in the result of the purchase sheet. When the request was a plan change and the result is
`OK` without that purchase, the native side asks Google Play for the purchases of the account
(`queryPurchases`) and replies with the new one, never with `oldPurchaseToken`: Google gives a
replacement a new purchase token, a `DEFERRED` one included, whose pending change is reported on
the new token. The new purchase is the one of the requested `productId`, or of the product being
replaced (a deferred replacement stays associated with it until the renewal), or, when the
replaced purchase is no longer listed, the only other purchase. When there is none, or several that
cannot be told apart, it replies `error`, so the page never shows a plan change that did not happen.
A failed lookup is replied like any failed query (`unavailable` or `error`).

If the activity is recreated while the purchase sheet is open, the native side must still
reply once the result arrives, or reply `error`. A purchase must never be lost silently.

What the page does next:

- `purchased` and `pending`: it posts the token to `POST /tillbell/purchases` (see below).
- `already_owned`: it sends `restore`.
- `canceled`: it re-enables the buttons.
- `unavailable` and `error`: it shows a message.

### `restore`

The customer tapped "Restore purchases", or the page received `already_owned`.

Request ([schema](../contract/restore.request.json)): `{}`

Reply ([schema](../contract/restore.reply.json)):

```json
{ "result": "ok", "purchases": [ { "productId": "premium", "purchaseToken": "..." } ] }
```

`purchases` lists the subscription purchases returned by `queryPurchasesAsync` (it can be
empty). The page posts each token to the server.

### `manage`

The customer tapped "Manage subscription". No reply.

Request ([schema](../contract/manage.request.json)):

```json
{ "productId": "premium" }
```

Open `https://play.google.com/store/account/subscriptions?sku=<productId>&package=<packageName>`,
or the page without parameters when `productId` is `null`.

## After the purchase: page to server

This part does not involve native code, and is documented for completeness. The page posts
the token to the Rails app:

```
POST /tillbell/purchases
Content-Type: application/json
X-CSRF-Token: <token>

{ "purchase_token": "..." }
```

| HTTP | `status` | Meaning | Page |
|---|---|---|---|
| 200 | `verified` | Recorded. `active` tells whether it grants access (a pending purchase does not). | Visits `success_url` when `active`, else shows the pending message. |
| 202 | `verifying` | Google could not be reached; verified in the background. | Shows the "checking" message. |
| 403 | `rejected` | The purchase belongs to another account. | Shows the rejected message. |
| 422 | `invalid` | Google does not know this token. | Shows the error message. |
