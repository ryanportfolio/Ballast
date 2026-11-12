# Registry to store all provider configurations
module Provider::ConfigurationRegistry
  class << self
    def register(provider_key, configuration, adapter_class = nil)
      registry[provider_key] = configuration
      adapter_registry[provider_key] = adapter_class if adapter_class
    end

    def get(provider_key)
      registry[provider_key]
    end

    def all
      registry.values
    end

    def providers
      registry.keys
    end

    # Get the adapter class for a provider key
    def get_adapter_class(provider_key)
      adapter_registry[provider_key]
    end

    private
      def registry
        @registry ||= {}
      end

      def adapter_registry
        @adapter_registry ||= {}
      end
  end
end
