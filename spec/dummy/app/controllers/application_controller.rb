class ApplicationController < ActionController::Base
  helper_method :current_user

  private
    # Test-only authentication: the signed-in user id comes from a header.
    def current_user
      User.find_by(id: request.headers["X-User-Id"])
    end
end
