# frozen_string_literal: true

require 'json'

module OtelLogging
  class Output
    SUPPRESSED = Object.new.freeze
    attr_reader :logger

    def self.for(logger)
      output = logger.instance_variable_get(:@otel_output)
      return output if output && output.logger.equal?(logger)

      logger.instance_variable_set(:@otel_output, new(logger))
    end

    def self.severity(value)
      return value if value.is_a?(Integer)
      return ::Logger::UNKNOWN if value.nil?

      ::Logger::Severity.const_get(value.to_s.upcase, false)
    rescue NameError
      raise ArgumentError, "Invalid log severity: #{value.inspect}"
    end

    def initialize(logger)
      @logger = logger
      @methods = {}
      destinations.each { |sink| original_add(sink) }
    end

    def enabled?(severity)
      destinations.any? do |sink|
        has_device = !sink.instance_variable_defined?(:@logdev) || !sink.instance_variable_get(:@logdev).nil?
        has_device && severity >= sink.level
      end
    end

    def add(severity, message = nil, progname = nil, &block)
      destinations.each { |sink| original_add(sink).call(severity, message, progname, &block) }
      true
    end

    def write(message, severity: ::Logger::INFO, tags: nil, progname: nil, above: nil)
      tags = JSON.parse(tags) if tags.is_a?(String)
      destinations.each do |sink|
        next unless severity >= sink.level
        next if above && sink.level <= above

        sink_tags = tags.is_a?(Hash) ? tags.fetch(destination_id(sink), []) : tags
        with_exact_tags(sink, sink_tags) { original_add(sink).call(severity, message, progname) }
      end
      true
    end

    def tags
      snapshots = destinations.to_h do |sink|
        formatter = sink.formatter if sink.respond_to?(:formatter)
        values = formatter.respond_to?(:current_tags) ? formatter.current_tags : []
        [destination_id(sink), values.map { |tag| tag.to_s.dup }]
      end
      unique = snapshots.values.uniq
      unique.size <= 1 ? (unique.first || []) : JSON.generate(snapshots)
    end

    def tagged(*tags)
      pushed = []
      tag_formatters.each { |formatter| pushed << [formatter, formatter.push_tags(*tags).size] }
      yield
    ensure
      pushed&.reverse_each { |formatter, count| formatter.pop_tags(count) }
    end

    private

    def destinations(logger = @logger)
      return [logger] unless logger.respond_to?(:broadcasts)

      logger.broadcasts.flat_map { |sink| destinations(sink) }.uniq
    end

    def tag_formatters
      destinations.filter_map do |sink|
        formatter = sink.formatter if sink.respond_to?(:formatter)
        formatter if formatter.respond_to?(:current_tags)
      end.uniq
    end

    def destination_id(sink)
      sink.instance_variable_get(:@otel_destination_id) ||
        sink.instance_variable_set(:@otel_destination_id, sink.object_id.to_s)
    end

    def original_add(sink)
      destination_id(sink)
      @methods[sink] ||= begin
        method = sink.method(:add)
        method = method.super_method while method.owner == LoggerExtension
        method
      end
    end

    def with_exact_tags(sink, tags)
      formatter = sink.formatter if sink.respond_to?(:formatter)
      return yield if tags.nil? || !formatter.respond_to?(:current_tags)

      previous = formatter.current_tags.dup
      formatter.clear_tags!
      formatter.push_tags(*tags)
      begin
        yield
      ensure
        formatter.clear_tags!
        formatter.push_tags(*previous)
      end
    end
  end
end
