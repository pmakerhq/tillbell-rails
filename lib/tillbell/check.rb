require "openssl"

module Tillbell
  # Checks that the configuration Tillbell needs is complete, and optionally that Google
  # accepts it, so an app knows whether purchases and notifications can work before a
  # customer tries. Run by +bin/rails tillbell:check+ (see the README, "Google Play setup").
  #
  # It changes nothing and never shows a secret: only the key names and the e-mail address
  # of the service accounts.
  #
  #   check = Tillbell::Check.new(online: true, plans: [ "premium:monthly", "premium:yearly" ])
  #   check.call.each { |result| puts "#{result.status} #{result.label} #{result.detail}" }
  #   check.ok? # false when something will not work
  class Check
    # One line of the report. +status+ is +:ok+, +:warn+ (worth a look) or +:fail+ (it will
    # not work).
    Result = Data.define(:status, :label, :detail)

    # The shape of a Google Cloud service account e-mail address.
    SERVICE_ACCOUNT_EMAIL = /\A[^@\s]+@[^@\s]+\.iam\.gserviceaccount\.com\z/

    # [online] Also ask Google (Android Publisher API): the key, its rights and the
    #          subscriptions of the Play Console.
    # [plans] Plans the app sells, as +"product_id:base_plan_id"+ strings or
    #         +{ product_id:, base_plan_id: }+ hashes. With +online+, each must exist in the
    #         Play Console with an active base plan. Defaults to +Tillbell.plans+; without
    #         any, +online+ lists what the Play Console has.
    def initialize(online: false, plans: Tillbell.plans)
      @online = online
      @plans = Array(plans).map { |plan| normalize(plan) }
      @results = []
    end

    # Runs every check and returns the results, in the order to read them.
    def call
      @results = []
      check_package_name
      key_email = check_service_account_json
      check_engine_mount
      check_pubsub(key_email)
      if @online && ok?
        check_online
      elsif @online
        add :warn, "Google was not asked", "fix the failures above first, then run again"
      end
      @results
    end

    # True when nothing failed (warnings are fine).
    def ok? = @results.none? { |result| result.status == :fail }

    private

    def google = Tillbell.google

    def add(status, label, detail = nil)
      @results << Result.new(status, label, detail)
      nil
    end

    def normalize(plan)
      return plan.to_h.symbolize_keys.slice(:product_id, :base_plan_id) if plan.respond_to?(:to_h)

      product_id, base_plan_id = plan.to_s.split(":", 2)
      { product_id: product_id, base_plan_id: base_plan_id.presence }
    end

    def check_package_name
      if google.package_name.present?
        add :ok, "Android package name", google.package_name
      else
        add :fail, "Android package name", "config.google.package_name is not set"
      end
    end

    # Returns the e-mail address of the service account of the key, when it could be read.
    def check_service_account_json
      label = "Service account key (config.google.service_account_json)"
      raw = google.service_account_json
      return add(:fail, label, "not set: put the key file in your credentials") if raw.blank?

      key = raw.is_a?(String) ? JSON.parse(raw) : raw
      return add(:fail, label, "not a key file: expected a JSON object") unless key.respond_to?(:to_h) && !key.is_a?(Array)

      key = key.to_h.stringify_keys
      problems = []
      problems << "\"type\" is not service_account" unless key["type"] == "service_account"
      problems << "\"client_email\" is missing" if key["client_email"].blank?
      problems << "\"private_key\" is missing or unreadable" unless private_key?(key["private_key"])
      return add(:fail, label, problems.join(", ")) if problems.any?

      add :ok, label, key["client_email"]
      key["client_email"]
    rescue JSON::ParserError
      add :fail, label, "not JSON: paste the whole key file as Google gave it (mind the YAML indentation)"
    end

    # A key that parses: a mangled one (lost line breaks, truncated) is caught here, offline.
    def private_key?(pem)
      OpenSSL::PKey.read(pem.to_s)
      true
    rescue OpenSSL::PKey::PKeyError
      false
    end

    def check_engine_mount
      mount = Rails.application.routes.routes.find { |route| route.app.try(:app) == Tillbell::Engine }
      if mount
        add :ok, "Engine mounted", "#{mount.path.spec}/purchases and #{mount.path.spec}/notifications/google_play"
      else
        add :fail, "Engine mounted", "add `mount Tillbell::Engine, at: \"/tillbell\"` to config/routes.rb"
      end
    end

    def check_pubsub(key_email)
      label = "Notification sender (config.google.pubsub_service_account_email)"
      email = google.pubsub_service_account_email
      if email.blank?
        add :fail, label, "not set: every notification is refused with 401, so renewals and cancellations are never synced"
      elsif !SERVICE_ACCOUNT_EMAIL.match?(email)
        add :fail, label, "#{email} does not look like a service account (name@project.iam.gserviceaccount.com)"
      elsif email == key_email
        add :warn, label, "#{email} also calls the Google Play API: prefer a dedicated account with no role"
      else
        add :ok, label, email
      end

      add :ok, "Notification audience", google.pubsub_audience.presence || "default: the notification URL as Rails sees it"
    end

    # Only reads: nothing is created, changed or acknowledged on Google.
    def check_online
      service = Tillbell::GooglePlay.service
      return unless check_purchase_access(service)

      @plans.any? ? @plans.each { |plan| check_plan(service, plan) } : list_subscriptions(service)
    rescue StandardError => error
      add :fail, "Google Play API access", describe(error)
    end

    # What the gem does all day is read a purchase, so ask for one that cannot exist. Google
    # answers "unknown purchase" when the account may read purchases, and a permission error
    # when it may not. Acknowledging and cancelling ("Manage orders and subscriptions")
    # cannot be tried without a real purchase: step 9 of the README does. Returns whether
    # reading is allowed.
    def check_purchase_access(service)
      service.get_purchase_subscriptionsv2(google.package_name, "tillbell-check")
      add :ok, "Reading purchases", "allowed"
      true
    rescue Google::Apis::ClientError => error
      if Tillbell::GooglePlay::INVALID_TOKEN_STATUSES.include?(error.status_code)
        add :ok, "Reading purchases", "allowed (Google answered that the test token is unknown, as expected)"
        true
      else
        add :fail, "Reading purchases", describe(error)
        false
      end
    rescue Google::Apis::AuthorizationError, Signet::AuthorizationError => error
      add :fail, "Reading purchases", describe(error)
      false
    end

    def check_plan(service, plan)
      label = "Subscription #{plan[:product_id]}#{" (base plan #{plan[:base_plan_id]})" if plan[:base_plan_id]}"
      subscription = service.get_monetization_subscription(google.package_name, plan[:product_id])
      base_plans = Array(subscription.base_plans)
      base_plan = if plan[:base_plan_id]
        base_plans.find { |candidate| candidate.base_plan_id == plan[:base_plan_id] }
      else
        base_plans.find { |candidate| candidate.state == "ACTIVE" } || base_plans.first
      end

      if base_plan.nil?
        add :fail, label, "the product exists but not this base plan (it has: #{base_plans.map(&:base_plan_id).join(', ').presence || 'none'})"
      elsif base_plan.state == "ACTIVE"
        add :ok, label, "active"
      else
        add :fail, label, "base plan is #{base_plan.state}: activate it in the Play Console"
      end
    rescue Google::Apis::ClientError, Google::Apis::AuthorizationError => error
      add :fail, label, describe(error, catalog: true)
    end

    def list_subscriptions(service)
      subscriptions = []
      token = nil
      loop do
        page = service.list_monetization_subscriptions(google.package_name, page_size: 1000, page_token: token)
        subscriptions.concat(Array(page.subscriptions))
        token = page.next_page_token.presence
        break unless token
      end
      return add(:warn, "Subscriptions in the Play Console", "none found: create them under Monetize with Play, Products, Subscriptions") if subscriptions.empty?

      subscriptions.each do |subscription|
        plans = Array(subscription.base_plans).map { |base_plan| "#{base_plan.base_plan_id} (#{base_plan.state.to_s.downcase})" }
        add :ok, "Subscription #{subscription.product_id}", plans.join(", ")
      end
    rescue Google::Apis::ClientError, Google::Apis::AuthorizationError => error
      add :fail, "Subscriptions in the Play Console", describe(error, catalog: true)
    end

    # What to do about an error from Google. +catalog+: the error comes from reading the product
    # catalog, which may need one more permission than reading purchases.
    def describe(error, catalog: false)
      case error
      when Signet::AuthorizationError
        "key refused by Google (revoked, deleted, or from another project): create a new JSON key"
      when Google::Apis::AuthorizationError
        "not authorized (401): invite the service account in the Play Console with the \"View financial data\" and " \
          "\"Manage orders and subscriptions\" permissions, and allow up to a day for Google to apply them#{catalog_hint(catalog)}"
      when Google::Apis::ClientError
        client_error(error, catalog)
      else
        "#{error.class}: #{error.message}"
      end
    end

    def client_error(error, catalog)
      case error.status_code
      when 403
        "not allowed (403): enable the Google Play Android Developer API in the Cloud project of the key, and invite the " \
          "service account in the Play Console with the \"View financial data\" and \"Manage orders and subscriptions\" " \
          "permissions (Google can take up to a day to apply them)#{catalog_hint(catalog)}"
      when 404 then "not found (404): wrong package name, or no such product in the Play Console"
      else "Google answered #{error.status_code}: #{error.message}"
      end
    end

    def catalog_hint(catalog)
      catalog ? "; reading the product catalog may also need \"View app information (read-only)\"" : ""
    end
  end
end
