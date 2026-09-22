# frozen_string_literal: true

require 'active_support/notifications'

module OtelLogging
  module Subscribers
    class ActiveRecord
      # SQL statements to ignore
      IGNORED_QUERIES = [
        /\AEXPLAIN /i,
        /\ASET /i,
        /\ASHOW /i,
        /\ABEGIN\z/i,
        /\ACOMMIT\z/i,
        /\AROLLBACK\z/i,
        /\ASAVEPOINT /i,
        /\ARELEASE SAVEPOINT /i,
        /schema_migrations/i,
        /ar_internal_metadata/i,
      ].freeze

      class << self
        def subscribe!
          subscriber = new
          ActiveSupport::Notifications.subscribe('sql.active_record') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            subscriber.handle_sql_event(event)
          end
        end
      end

      def handle_sql_event(event)
        return unless TraceContext.current.active?
        return if should_ignore?(event)

        payload = event.payload
        sql = payload[:sql]

        operation = extract_operation(sql)
        table = extract_table(sql)
        event_name = build_event_name(operation, table)

        attributes = build_attributes(payload, event, operation, table)

        OtelLogging.logger.event(event_name, **attributes)
      end

      private

      def should_ignore?(event)
        payload = event.payload
        return true if payload[:sql].nil? || payload[:sql].empty?
        return true if payload[:name] == 'SCHEMA'
        IGNORED_QUERIES.any? { |pattern| payload[:sql].match?(pattern) }
      end

      def extract_operation(sql)
        case sql.strip
        when /\ASELECT/i then 'select'
        when /\AINSERT/i then 'insert'
        when /\AUPDATE/i then 'update'
        when /\ADELETE/i then 'delete'
        else 'query'
        end
      end

      def extract_table(sql)
        case sql
        when /\bFROM\s+["`]?(\w+)["`]?/i then Regexp.last_match(1)
        when /\bINTO\s+["`]?(\w+)["`]?/i then Regexp.last_match(1)
        when /\bUPDATE\s+["`]?(\w+)["`]?/i then Regexp.last_match(1)
        else nil
        end
      end

      def build_event_name(operation, table)
        parts = ['db', operation]
        parts << table if table
        parts.join('.')
      end

      def build_attributes(payload, event, operation, table)
        attrs = {
          'db.duration_ms' => event.duration.round(2)
        }

        # Database system
        if payload[:connection]
          adapter = payload[:connection].adapter_name.downcase rescue 'unknown'
          attrs['db.system'] = normalize_adapter(adapter)
        end

        # SQL statement (truncated)
        attrs['db.statement'] = truncate_sql(payload[:sql])

        # Cached query
        attrs['db.cached'] = true if payload[:cached]

        attrs
      end

      def normalize_adapter(adapter)
        case adapter
        when /mysql/i then 'mysql'
        when /postgres/i, /pg/i then 'postgresql'
        when /sqlite/i then 'sqlite'
        else adapter
        end
      end

      def truncate_sql(sql)
        return sql if sql.nil? || sql.length <= 100
        "#{sql[0..97]}..."
      end
    end
  end
end
