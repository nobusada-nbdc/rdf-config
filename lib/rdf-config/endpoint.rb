class RDFConfig
  class Endpoint
    def initialize(config)
      @endpoint = config.endpoint
    end

    def primary_endpoint
      endpoints.first
    end

    def endpoints
      case @endpoint['endpoint']
      when String
        [@endpoint['endpoint']]
      when Array
        @endpoint['endpoint']
      else
        [@endpoint['endpoint'].to_s]
      end
    end
  end
end
