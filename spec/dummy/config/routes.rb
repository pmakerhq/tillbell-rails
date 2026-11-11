Rails.application.routes.draw do
  mount Tillbell::Engine, at: "/tillbell"

  get "paywall", to: "paywalls#show"
  get "dashboard", to: "paywalls#show", as: :dashboard
end
