Tillbell::Engine.routes.draw do
  # Called by the paywall with the purchase token returned by the native app.
  resources :purchases, only: :create

  # Pub/Sub push endpoint for Google Play real-time developer notifications.
  post "notifications/google_play", to: "notifications#create", as: :google_play_notifications
end
