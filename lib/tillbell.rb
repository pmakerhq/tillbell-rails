require "pay"
require "tillbell/version"
require "tillbell/engine"
require "tillbell/google_play"
require "tillbell/app_store"
require "tillbell/check"
require "tillbell/owner"

# Tillbell adds Google Play subscriptions to Rails apps that use the Pay gem.
#
# Store subscriptions are regular Pay records (a +Pay::GooglePlay::Customer+ and its
# +Pay::GooglePlay::Subscription+ rows), so they live next to Stripe or any other Pay
# processor and every Pay helper (+pay_subscriptions.active+, +subscribed?+, ...) sees them.
#
# Configure it in an initializer:
#
#   Tillbell.configure do |config|
#     config.google.package_name = "com.example.app"
#     config.google.service_account_json = Rails.application.credentials.dig(:tillbell, :google_service_account)
#     config.google.pubsub_service_account_email = Rails.application.credentials.dig(:tillbell, :pubsub_service_account_email)
#
#     config.on(:subscription_created) { |pay_subscription| ... }
#   end
module Tillbell
  # Base class for every error raised by Tillbell.
  class Error < Pay::Error; end

  # The events Tillbell emits, in the order a subscription usually goes through them.
  # +subscription_updated+ fires for any change; +subscription_renewed+, +payment_failed+,
  # +payment_recovered+ and +plan_changed+ say which one happened.
  # +subscription_reactivated+ follows a +subscription_canceled+ the customer took back
  # before the end of the period.
  EVENTS = %i[subscription_created subscription_updated subscription_renewed payment_failed payment_recovered plan_changed
              subscription_canceled subscription_reactivated subscription_expired subscription_revoked purchase_rejected].freeze

  # A plan the app sells, under a name of your own: a Google Play product and its base plan,
  # and the App Store product of the same plan. The App Store product id defaults to the Google
  # Play one; an app sold on one store only leaves the other's id out.
  Plan = Data.define(:name, :product_id, :base_plan_id, :app_store_product_id) do
    def initialize(name:, product_id: nil, base_plan_id: nil, app_store_product_id: product_id)
      raise ArgumentError, "plan #{name.inspect} needs a product_id or an app_store_product_id" if product_id.blank? && app_store_product_id.blank?

      super(name: name.to_sym, product_id: product_id, base_plan_id: base_plan_id, app_store_product_id: app_store_product_id)
    end

    # The ids the app of +store+ (+:app_store+ or +:google_play+) buys this plan with, as the
    # +product_id+ and +base_plan_id+ of a paywall option. The App Store has no base plans.
    def product_for(store)
      store == :app_store ? { product_id: app_store_product_id, base_plan_id: nil } : { product_id: product_id, base_plan_id: base_plan_id }
    end
  end

  # Google Play settings, see the README for where each value comes from.
  #
  # [package_name] Application id of the Android app, e.g. "com.example.app".
  # [service_account_json] JSON key of a service account with access to the Play Console.
  # [pubsub_service_account_email] Service account Pub/Sub signs its push requests with.
  # [pubsub_audience] Audience of those requests; defaults to the notification endpoint URL.
  mattr_accessor :google, default: ActiveSupport::OrderedOptions.new

  # App Store settings.
  #
  # [bundle_id] Bundle identifier of the iOS app, e.g. "com.example.app". Transactions and
  #             notifications signed for another app are refused.
  # [allow_xcode_transactions] Accept the transactions Xcode signs locally for StoreKit
  #                            Testing (a +.storekit+ configuration file), in the development
  #                            and test environments only. See
  #                            +Tillbell::AppStore.verify_transaction!+.
  # [stale_after] How long after the end of its period an App Store subscription that no
  #               notification renewed or ended keeps giving access, e.g. +16.days+ (set it at
  #               least to the billing grace period of your subscriptions). Nil, the default,
  #               trusts the last state Apple notified forever.
  mattr_accessor :apple, default: ActiveSupport::OrderedOptions.new

  # Returns the Pay owner (usually a User) the current request acts for, or nil.
  # Evaluated with +instance_exec+ in the controller and in the view, so any helper
  # available there (+current_user+, +Current.user+, ...) can be used.
  mattr_accessor :current_owner, default: -> { current_user }

  # Controller the purchase endpoint inherits from, so it gets the host app's
  # authentication, CSRF protection and error handling.
  mattr_accessor :parent_controller, default: "ApplicationController"

  # Returns the Pay subscription +name+ for a Google Play product. Pay helpers such as
  # +subscribed?(name:)+ look subscriptions up by name, "default" unless you change it.
  mattr_accessor :subscription_name, default: ->(product_id:, base_plan_id:) { Pay.default_product_name }

  # The plans the app sells, from the lowest to the highest: the order decides whether a plan
  # change is an upgrade or a downgrade (see +replacement_mode+). Assign hashes:
  #
  #   config.plans = [
  #     { name: :solo, product_id: "app_solo", base_plan_id: "monthly" },
  #     { name: :family, product_id: "app_family", base_plan_id: "monthly", app_store_product_id: "app.family.monthly" }
  #   ]
  #
  # +tillbell:check+ checks the Google Play ones with Google, and +plan+ on a store subscription
  # finds the one it is on.
  mattr_reader :plans, default: [].freeze

  # What Hotwire Native writes in the user agent for the bridge components the app
  # registered, e.g. "bridge-components: [haptic tillbell]". +tillbell+ must be in that
  # list for the paywall to work.
  NATIVE_USER_AGENT = /bridge-components: \[(?:[^\]]*\s)?tillbell[\s\]]/

  # What Hotwire Native writes in the user agent of each platform, and the store its in-app
  # purchases go through.
  NATIVE_STORES = {
    /\b(?:Hotwire|Turbo) Native iOS\b/ => :app_store,
    /\b(?:Hotwire|Turbo) Native Android\b/ => :google_play
  }.freeze

  class << self
    # The store in-app purchases go through in the Hotwire Native app +user_agent+ comes from:
    # +:app_store+ (iOS), +:google_play+ (Android), or nil in a browser. Unlike +native?+, it
    # does not need the +tillbell+ component, so it also answers for app versions that cannot
    # buy yet. Use it for the store rules that apply to the whole app, e.g. the App Store
    # forbids linking to another way to pay:
    #
    #   Tillbell.store(request.user_agent) == :app_store
    #
    # Like +native?+, it only picks what to show: a forged user agent gains nothing.
    def store(user_agent)
      NATIVE_STORES.find { |pattern, _store| pattern.match?(user_agent.to_s) }&.last
    end

    # True when +user_agent+ comes from a native app that registered the +tillbell+ bridge
    # component (Android today, iOS later), so a Google Play purchase can start from the
    # page. Use it to choose between the paywall and another way to pay, e.g. a web checkout:
    #
    #   Tillbell.native?(request.user_agent)
    #
    # An app version without the component, and every browser, answer false. The check
    # only picks which page to show: purchases are always verified with Google, so a
    # forged user agent gains nothing.
    def native?(user_agent)
      NATIVE_USER_AGENT.match?(user_agent.to_s)
    end

    # Sets the catalog of +plans+ from hashes with +name+, +product_id+ and optionally
    # +base_plan_id+ and +app_store_product_id+ (or from +Tillbell::Plan+ objects).
    #
    # A Google Play product with several base plans is several plans, while each App Store
    # product is one duration: such plans do not default their App Store product id to the
    # shared Google Play one. Give them their own +app_store_product_id+.
    def plans=(list)
      built = list.map do |plan|
        next [ plan, false ] if plan.is_a?(Plan)
        raise ArgumentError, "a plan is a hash with :name and :product_id or :app_store_product_id, got #{plan.inspect}" unless plan.respond_to?(:to_h) && !plan.nil?

        attributes = plan.to_h.symbolize_keys
        [ Plan.new(**attributes), !attributes.key?(:app_store_product_id) ]
      end
      shared = built.filter_map { |plan, _defaulted| plan.app_store_product_id }.tally.select { |_id, count| count > 1 }.keys
      @@plans = built.map do |plan, defaulted|
        defaulted && shared.include?(plan.app_store_product_id) ? plan.with(app_store_product_id: nil) : plan
      end.freeze
    end

    # Finds a plan of +plans+ by +name+ (a symbol or string), by App Store product id (nil when
    # several plans share it), or by Google ids. With a +base_plan_id+ that no plan has, falls
    # back to the product's plan when it has only one.
    def plan(name = nil, product_id: nil, base_plan_id: nil, app_store_product_id: nil)
      return plans.find { |plan| plan.name == name.to_sym } if name
      return plans.select { |plan| plan.app_store_product_id == app_store_product_id }.then { |matches| matches.first if matches.one? } if app_store_product_id
      return if product_id.blank?

      matches = plans.select { |plan| plan.product_id == product_id }
      matches.find { |plan| plan.base_plan_id == base_plan_id } || (matches.first if matches.one?)
    end

    # The Google replacement mode for moving from plan +from+ to plan +to+ (plans, or their
    # names): +CHARGE_PRORATED_PRICE+ for an upgrade, charged now for the difference with the
    # renewal date unchanged, and +DEFERRED+ for a downgrade, which takes effect at the next
    # renewal because the customer already paid the current period and Google does not
    # refund it. Raises +ArgumentError+ for a plan that is not in +plans+ or a move to the
    # same plan.
    def replacement_mode(from:, to:)
      ranks = [ from, to ].map do |plan|
        plans.index { |candidate| candidate == plan || candidate.name == plan.try(:to_sym) } || raise(ArgumentError, "#{plan.inspect} is not in Tillbell.plans")
      end
      raise ArgumentError, "#{from.inspect} and #{to.inspect} are the same plan" if ranks.first == ranks.last

      ranks.last > ranks.first ? "CHARGE_PRORATED_PRICE" : "DEFERRED"
    end

    # Yields the Tillbell module so settings can be assigned in a block.
    def configure
      yield self
    end

    # Subscribes to a Tillbell event. The block receives the +Pay::GooglePlay::Subscription+
    # (or, for +:purchase_rejected+, a hash describing the refused purchase).
    #
    # Events go through Pay's webhook delegator, so +Pay::Webhooks.delegator.subscribe
    # "tillbell.subscription_created"+ works too.
    def on(event, callable = nil, &block)
      raise ArgumentError, "unknown Tillbell event #{event.inspect}" unless EVENTS.include?(event.to_sym)

      Pay::Webhooks.delegator.subscribe("tillbell.#{event}", callable || block)
    end

    # Emits a Tillbell event. Errors raised by subscribers are reported to +Rails.error+
    # instead of propagating: by the time an event fires, the subscription is already
    # saved, and a failing callback must not turn a recorded purchase into an error.
    def instrument(event, payload)
      Pay::Webhooks.instrument(type: "tillbell.#{event}", event: payload)
    rescue StandardError => error
      Rails.error.report(error, handled: true, context: { tillbell_event: event })
    end

    # Paywall text +key+ (see config/locales/en.yml) in the current locale. A locale without
    # the text, or with only part of the status messages, falls back to English instead of
    # rendering a "translation missing" marker the Stimulus controller cannot parse.
    def translate(key)
      english = I18n.t("tillbell.paywall.#{key}", locale: :en)
      localized = I18n.t("tillbell.paywall.#{key}", default: english)
      english.is_a?(Hash) ? english.merge(localized) : localized
    end

    # Shortens a purchase token for logs: tokens grant access to a subscription and
    # must never be written in full.
    def redact(token)
      token.to_s.first(8) + "..."
    end
  end
end
