// Tillbell paywall controller, copied into your app by `rails generate tillbell:install`.
// It is yours now: change it as you like. The messages it exchanges with the native app
// are documented in docs/bridge-contract.md of the tillbell gem.
//
// The controller only connects inside a Hotwire Native app that registers the
// "tillbell" bridge component. Everywhere else the paywall keeps its buttons disabled
// and shows its fallback, so a purchase can never start without the native app.
//
// Events dispatched on the paywall element, for your own code to listen to:
//   tillbell:verified  the purchase grants access. Cancel the event to stay on the page
//                      instead of going to the success URL.
//   tillbell:status    a status message is shown (detail: { key, message }).
import { BridgeComponent } from "@hotwired/hotwire-native-bridge"

export default class extends BridgeComponent {
  static component = "tillbell"
  static targets = ["plan", "price", "action", "status", "fallback"]
  static values = { accountId: String, purchaseUrl: String, successUrl: String, messages: Object }

  connect() {
    super.connect()
    this.fallbackTargets.forEach((element) => element.hidden = true)
    this.loadPrices()
  }

  // Asks Google Play for the localized price of every plan, then enables the paywall.
  loadPrices() {
    const products = this.planTargets.map((plan) => this.#productOf(plan))

    this.send("products", { products }, ({ data }) => {
      if (data.result !== "ok") return this.#showStatus(data.result === "unavailable" ? "unavailable" : "error")

      this.planTargets.forEach((plan) => {
        const { productId, basePlanId } = this.#productOf(plan)
        const product = data.products.find((p) => p.productId === productId && (p.basePlanId ?? null) === basePlanId)
        const price = plan.closest("label")?.querySelector("[data-tillbell-target~='price']")

        if (price && product) price.textContent = product.formattedPrice
        plan.disabled = !product
      })
      this.#setBusy(false)
    })
  }

  // Opens the Google Play purchase sheet for the checked plan.
  purchase() {
    const plan = this.planTargets.find((plan) => plan.checked && !plan.disabled)
    if (!plan) return

    const { oldPurchaseToken, replacementMode } = plan.dataset
    const message = { ...this.#productOf(plan), obfuscatedAccountId: this.accountIdValue }
    if (oldPurchaseToken) Object.assign(message, { oldPurchaseToken, replacementMode })

    this.#setBusy(true)
    this.send("purchase", message, ({ data }) => this.#handlePurchase(data))
  }

  // Records again the purchases Google Play knows for this device's account.
  restorePurchases() {
    this.#setBusy(true)
    this.send("restore", {}, async ({ data }) => {
      if (data.result !== "ok") return this.#fail(data.result === "unavailable" ? "unavailable" : "error")
      if (data.purchases.length === 0) return this.#fail("nothing_to_restore")

      const results = []
      for (const { purchaseToken } of data.purchases) results.push(await this.#record(purchaseToken))
      this.#finish(results.find((result) => result.active) ?? results[0])
    })
  }

  // Opens the Play Store page where the customer manages the subscription.
  manage() {
    const plan = this.planTargets.find((plan) => plan.checked) ?? this.planTargets[0]
    this.send("manage", { productId: plan ? plan.dataset.productId : null })
  }

  async #handlePurchase({ result, purchaseToken }) {
    switch (result) {
      case "purchased":
      case "pending":
        return this.#finish(await this.#record(purchaseToken))
      case "already_owned":
        return this.restorePurchases()
      case "canceled":
        return this.#setBusy(false)
      case "unavailable":
        return this.#fail("unavailable")
      default:
        return this.#fail("error")
    }
  }

  // Sends the purchase token to Rails, which verifies it with Google.
  async #record(purchaseToken) {
    this.#showStatus("verifying")
    try {
      const response = await fetch(this.purchaseUrlValue, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Accept": "application/json",
          "X-CSRF-Token": document.querySelector("meta[name='csrf-token']")?.content
        },
        body: JSON.stringify({ purchase_token: purchaseToken })
      })
      return await response.json()
    } catch {
      return { status: "error" }
    }
  }

  #finish(body) {
    if (body.status === "verified" && body.active) {
      const event = this.dispatch("verified", { detail: body, cancelable: true })
      event.defaultPrevented ? this.#setBusy(false) : this.#visit(this.successUrlValue)
    } else if (body.status === "verified") {
      this.#fail("pending")
    } else if (body.status === "verifying" || body.status === "rejected") {
      this.#fail(body.status)
    } else {
      this.#fail("error")
    }
  }

  #fail(key) {
    this.#showStatus(key)
    this.#setBusy(false)
  }

  #showStatus(key) {
    const message = this.messagesValue[key] ?? key
    this.statusTargets.forEach((element) => element.textContent = message)
    this.dispatch("status", { detail: { key, message } })
  }

  #setBusy(busy) {
    this.actionTargets.forEach((element) => element.disabled = busy)
  }

  #productOf(plan) {
    return { productId: plan.dataset.productId, basePlanId: plan.dataset.basePlanId ?? null }
  }

  #visit(url) {
    window.Turbo ? window.Turbo.visit(url) : window.location.assign(url)
  }
}
