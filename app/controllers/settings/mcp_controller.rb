class Settings::McpController < ApplicationController
  layout "settings"

  def show
    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("breadcrumbs.mcp"), nil ]
    ]
    @mcp_url = "#{(ENV["APP_URL"].presence || request.base_url).chomp("/")}/mcp"
  end
end
