module Localize
  extend ActiveSupport::Concern

  included do
    around_action :switch_locale
    around_action :switch_timezone
  end

  private
    # Ballast is English only: every request renders in the default locale,
    # whatever the URL, browser, user or family asks for. The explicit reset
    # keeps a locale left on the thread by earlier work from leaking in.
    def switch_locale(&action)
      I18n.with_locale(I18n.default_locale, &action)
    end

    def switch_timezone(&action)
      Time.use_zone(resolved_timezone, &action)
    end

    # How often to write a DebugLogEntry for the same (family, bad value) pair.
    # switch_timezone runs on every request, so without this an affected
    # family would write one row per page view forever.
    INVALID_TIMEZONE_LOG_INTERVAL = 1.day

    # Family#timezone is a free-text IANA name (e.g. from an older DB dump, or
    # a zone the tzdata maintainers later renamed, like the historical
    # "Europe/Kiev" -> "Europe/Kyiv" switch). `Time.use_zone` raises
    # ArgumentError on anything it doesn't recognize, which would otherwise
    # take down every request/render for the affected family -- including the
    # login page, since this runs on every request. Validate first and fall
    # back to the app default instead of crashing.
    def resolved_timezone
      family = Current.family
      requested = family.try(:timezone)
      return Time.zone if requested.blank?

      zone = ActiveSupport::TimeZone[requested]
      return zone if zone.present?

      log_invalid_timezone_once(family, requested)
      Time.zone
    end

    def log_invalid_timezone_once(family, requested)
      cache_key = [ "invalid_family_timezone", family.id, requested ]

      # `fetch` is read-then-write, not atomic -- two concurrent requests could
      # both see a miss and both log. `write(unless_exist: true)` maps to
      # Redis's atomic SET NX in production, so only one request ever wins the
      # lease and logs.
      lease_acquired = Rails.cache.write(cache_key, true, expires_in: INVALID_TIMEZONE_LOG_INTERVAL, unless_exist: true)
      return unless lease_acquired

      DebugLogEntry.capture(
        category: "other",
        level: "warn",
        message: "Invalid family timezone #{requested.inspect}, falling back to #{Time.zone.name}",
        source: "Localize#switch_timezone",
        family: family
      )
    end
end
