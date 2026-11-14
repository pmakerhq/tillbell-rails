module Tillbell
  # View helper rendering the Google Play paywall, available in every view of the host app.
  module PaywallHelper
    # True when the app showing the page registered the +tillbell+ bridge component, i.e.
    # when the paywall can start a purchase. Same check as +Tillbell.native?+.
    #
    #   <% if tillbell_native? %>
    #     <%= tillbell_paywall ... %>
    #   <% else %>
    #     <%= link_to "Subscribe on the web", checkout_path %>
    #   <% end %>
    def tillbell_native?
      Tillbell.native?(request.user_agent)
    end

    # The store of the native app showing the page (+:app_store+, +:google_play+) or nil in a
    # browser. Same check as +Tillbell.store+.
    #
    #   <% unless tillbell_store == :app_store %>
    #     <%= link_to "Subscribe on the web", checkout_path %>
    #   <% end %>
    def tillbell_store
      Tillbell.store(request.user_agent)
    end

    # Renders an unstyled paywall driven by the +tillbell+ Stimulus controller, which
    # talks to the +tillbell+ Hotwire Native bridge component.
    #
    #   <%= tillbell_paywall success_url: dashboard_path, class: "paywall" do |paywall| %>
    #     <%= paywall.plan_option product_id: "premium", base_plan_id: "monthly", checked: true do %>
    #       Monthly, <%= paywall.price %>
    #     <% end %>
    #     <%= paywall.submit %>
    #     <%= paywall.restore %>
    #     <%= paywall.manage %>
    #     <%= paywall.status %>
    #     <%= paywall.fallback %>
    #   <% end %>
    #
    # Outside the native app (or in an app version without the component) the controller
    # never connects: the buttons stay disabled and only the fallback is shown.
    #
    # [success_url] Where to go once a purchase grants access.
    # [owner] The Pay owner buying; defaults to +Tillbell.current_owner+.
    # [html_options] Attributes of the wrapping +div+.
    def tillbell_paywall(success_url:, owner: instance_exec(&Tillbell.current_owner), **html_options, &block)
      raise ArgumentError, "tillbell_paywall needs a signed-in owner" if owner.nil?

      data = {
        controller: "tillbell",
        tillbell_account_id_value: Pay::GooglePlay::Customer.for(owner).processor_id,
        tillbell_purchase_url_value: tillbell.purchases_path,
        tillbell_success_url_value: success_url,
        tillbell_messages_value: Tillbell.translate("messages").to_json
      }

      tag.div(**html_options, data: data.merge(html_options.fetch(:data, {}))) do
        capture(PaywallBuilder.new(self), &block)
      end
    end
  end
end
