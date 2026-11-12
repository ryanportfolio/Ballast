# frozen_string_literal: true

module FeatureFlags
  class << self
    def intro_ui?
      Rails.configuration.x.ui.default_layout.to_s.in?(%w[intro dashboard])
    end
  end
end
