class Provider
  module Metadata
    REGISTRY = {
      simplefin:      { region: "US",      kinds: %w[Bank Investment], maturity: :stable, logo_text: "SF", logo_color: "#2563eb", domain: "simplefin.org" },
      # Property valuation (AVM) providers
      rentcast:       { region: "US",      kinds: %w[Property],        maturity: :beta,   logo_text: "RC", logo_color: "#2563eb", domain: "rentcast.io", name: "RentCast" },
      realie:         { region: "US",      kinds: %w[Property],        maturity: :beta,   logo_text: "RE", logo_color: "#0d9488", domain: "realie.ai" },
      chimnie:        { region: "UK",      kinds: %w[Property],        maturity: :beta,   logo_text: "CH", logo_color: "#db2777", domain: "chimnie.com" }
    }.freeze

    def self.for(provider_key)
      REGISTRY[provider_key.to_sym] || { logo_text: provider_key.to_s.first(2).upcase, logo_color: nil }
    end

    # Brandfetch icon URL for the provider's own brand, or nil when the provider
    # has no domain or Brandfetch isn't configured. Unknown brands 404 instead of
    # returning Brandfetch's lettermark, so ProviderLogo keeps its own fallback.
    def self.logo_url(provider_key)
      domain = self.for(provider_key)[:domain]
      Setting.brand_fetch_icon_url(domain, fallback: "404")
    end
  end
end
