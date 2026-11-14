Rails.application.configure do
  # `.presence` so an empty PRODUCT_NAME (as .env.example ships it) still gives the default.
  config.x.product_name = ENV["PRODUCT_NAME"].presence || "Ballast"
  config.x.brand_name = ENV.fetch("BRAND_NAME", "FOSS")
end
