class OnboardingsController < ApplicationController
  layout "wizard"

  before_action :set_user

  def show
  end

  def preferences
  end

  private
    def set_user
      @user = Current.user
    end
end
