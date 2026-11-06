# frozen_string_literal: true

require 'json'
require 'active_support/parameter_filter'

module OtelLogging
  module Attributes
    OMIT = Object.new.freeze
    RESERVED = %w[log.severity log.tags log.progname].freeze

    def self.normalize(attributes)
      raise ArgumentError, 'attributes must be a Hash' unless attributes.is_a?(Hash)

      filters = if defined?(Rails.application) && Rails.application
        Rails.application.config.filter_parameters
      else
        %i[password password_confirmation secret token authorization]
      end
      filtered = ActiveSupport::ParameterFilter.new(filters).filter(structured(attributes, []))
      filtered.each_with_object({}) do |(key, value), result|
        next if RESERVED.include?(key.to_s) || %w[exception exception_object].include?(key.to_s)

        normalized = value_for(value)
        result[key.to_s] = normalized unless normalized.equal?(OMIT)
      end
    end

    def self.value_for(value)
      case value
      when String then value.dup
      when Symbol then value.to_s
      when Integer, TrueClass, FalseClass then value
      when Float then value.finite? ? value : OMIT
      when Array
        scalar_array = value.all? { |item| item.is_a?(String) } || value.all? { |item| item.is_a?(Numeric) } ||
          value.all? { |item| item == true || item == false }
        scalar_array ? value.map { |item| value_for(item) } : JSON.generate(value)
      when Hash
        JSON.generate(structured(value, []))
      else OMIT
      end
    end

    def self.structured(value, parents)
      case value
      when Hash, Array
        return nil if parents.any? { |parent| parent.equal?(value) }
        parents = parents + [value]
        if value.is_a?(Hash)
          value.each_with_object({}) { |(key, item), result| result[key.to_s] = structured(item, parents) }
        else
          value.map { |item| structured(item, parents) }
        end
      when String, Integer, TrueClass, FalseClass, NilClass then value
      when Float then value.finite? ? value : nil
      when Symbol then value.to_s
      else nil
      end
    end
  end
end
