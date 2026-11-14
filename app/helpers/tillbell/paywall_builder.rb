module Tillbell
  # Builds the parts of a paywall; yielded by +tillbell_paywall+.
  #
  # Every method takes HTML attributes, so the host app owns the markup and the styles.
  # Texts default to the +tillbell.paywall+ translations.
  class PaywallBuilder
    def initialize(template)
      @template = template
    end

    # A radio button for one product, wrapped in a label with the block's content: a Google
    # Play +product_id+ and +base_plan_id+, an App Store +product_id+, or a +plan+ of
    # +Tillbell.plans+ (a name or a plan), whose ids are those of the store of the app showing
    # the page (see +Tillbell.store+). Pass +replacing+ (the current
    # Pay::GooglePlay::Subscription) to make it a plan change; +replacement_mode+ is Google's
    # proration mode, e.g. "CHARGE_PRORATED_PRICE", and is passed through untouched.
    def plan_option(product_id: nil, base_plan_id: nil, plan: nil, checked: false, replacing: nil, replacement_mode: nil, **html_options, &block)
      product_id, base_plan_id = find_plan(plan).product_for(store).values_at(:product_id, :base_plan_id) if plan
      raise ArgumentError, "plan_option needs a product_id or a plan" if product_id.blank?
      raise ArgumentError, "a plan change needs a replacement_mode" if replacing && replacement_mode.blank?

      radio = tag.input(
        type: "radio", name: "tillbell_plan", value: [ product_id, base_plan_id ].compact.join(":"),
        checked: checked, disabled: true,
        data: {
          tillbell_target: "plan", product_id: product_id, base_plan_id: base_plan_id,
          old_purchase_token: replacing&.processor_id, replacement_mode: replacement_mode
        }.compact
      )
      tag.label(**html_options) { radio + @template.capture(&block) }
    end

    # The plan option for moving from the store subscription +from+ to the plan +to+ of
    # +Tillbell.plans+ (a name or a plan), checked. On Google Play it carries the replacement
    # mode Google needs: prorated for an upgrade, deferred to the next renewal for a downgrade
    # (see +Tillbell.replacement_mode+). On the App Store it is the target product alone: Apple
    # replaces the subscription of the same group by itself. Use it in a paywall that offers
    # this one plan.
    def plan_change(to:, from:, **html_options, &block)
      raise ArgumentError, "plan_change needs the current store subscription (from:)" if from.nil?

      target = find_plan(to)
      return plan_option(**target.product_for(:app_store), checked: true, **html_options, &block) if from.app_store?

      current = from.plan || raise(ArgumentError, "the current subscription (#{from.processor_plan}:#{from.base_plan_id}) is not in Tillbell.plans")
      plan_option(product_id: target.product_id, base_plan_id: target.base_plan_id, checked: true, replacing: from,
                  replacement_mode: Tillbell.replacement_mode(from: current, to: target), **html_options, &block)
    end

    # Placeholder for the localized price, filled in from Google Play. Use it inside a
    # +plan_option+ block.
    def price(placeholder = "", **html_options)
      tag.span(placeholder, **with_data(html_options, tillbell_target: "price"))
    end

    # Starts the purchase of the checked plan.
    def submit(text = t("submit"), **html_options)
      button(text, "purchase", **html_options)
    end

    # Asks Google Play for existing purchases and records them again, e.g. after a reinstall.
    def restore(text = t("restore"), **html_options)
      button(text, "restorePurchases", **html_options)
    end

    # Opens the Play Store subscription page.
    def manage(text = t("manage"), **html_options)
      button(text, "manage", **html_options)
    end

    # Live region where the controller writes status messages.
    def status(**html_options)
      tag.p(role: "status", aria: { live: "polite" }, **with_data(html_options, tillbell_target: "status"))
    end

    # Shown until the native component connects, i.e. in a browser or an outdated app.
    def fallback(text = t("fallback"), **html_options, &block)
      content = block ? @template.capture(&block) : text
      tag.div(content, **with_data(html_options, tillbell_target: "fallback"))
    end

    private
      def find_plan(plan)
        plan.is_a?(Tillbell::Plan) ? plan : Tillbell.plan(plan) || raise(ArgumentError, "#{plan.inspect} is not in Tillbell.plans")
      end

      # The store of the app showing the page; Google Play ids in a browser, where the paywall
      # never connects anyway.
      def store
        Tillbell.store(@template.request.user_agent)
      end

      def button(text, action, **html_options)
        tag.button(text, type: "button", disabled: true,
          **with_data(html_options, tillbell_target: "action", action: "tillbell##{action}"))
      end

      # Adds the data attributes the controller relies on to the caller's attributes,
      # keeping any data attribute the caller passed.
      def with_data(html_options, data)
        html_options.merge(data: data.merge(html_options.fetch(:data, {})))
      end

      def tag
        @template.tag
      end

      def t(key)
        Tillbell.translate(key)
      end
  end
end
