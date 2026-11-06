# Instrumentation

[Back to the README](../README.md)

Use `ActiveSupport::Notifications.instrument` for reusable Rails operations.
Register the notifications that should create spans in the gem's initializer:

```ruby
OtelLogging.configure do |config|
  config.instrumentation do
    subscribe "inventory.check"

    subscribe /\.store\z/ do |notification_name, payload|
      name notification_name.sub(/\.store\z/, "")
      attributes("product.id" => payload[:product_id])
    end

    subscribe ->(notification_name, payload) {
      notification_name == "request.client" && payload[:service] == "shipping"
    }
  end
end
```

Then instrument application work:

```ruby
ActiveSupport::Notifications.instrument("inventory.check", product_id: 123) do |payload|
  payload[:available] = check_inventory
  Rails.event.notify("inventory.checked", available: payload[:available])
end
```

## Matching and defaults

Strings match exact names. Regexes match notification names. Callables receive
`(notification_name, payload)` and return a truthy value to select an operation.
The first matching application rule wins; rules do not combine or create duplicate
spans. If none matches, enabled built-in framework mappings are considered.

Without a transformation block, the span name is the notification name and its
attributes are the filtered, normalized payload. Inside a transformation:

```ruby
subscribe "inventory.check" do |notification_name, payload|
  name notification_name.upcase
  attributes("product.id" => payload[:product_id])
end
```

`name` and `attributes` are optional. `attributes` replaces the default payload
selection; `attributes({})` selects no payload attributes. Internal logger tag
metadata is still retained. Choose stable operation names rather than names
containing user IDs, timestamps, or other unbounded values.

A catch-all uses only defaults:

```ruby
OtelLogging.configure do |config|
  config.instrumentation do
    # Put specific rules above this fallback.
    subscribe /.*/
  end
end
```

This overrides all built-in mappings with notification names and payloads, and
can produce substantially more output. The install generator includes it commented
out. Notifications that have neither an application rule nor a built-in mapping
continue to run and notify other subscribers normally, without creating gem spans.

## Lifecycle

Rules are selected once, at notification start, using the payload available then.
The selected transformation runs at start and again at completion. Keep it free
of side effects and allow for fields that do not exist until completion.

```ruby
subscribe "request.client" do |_notification_name, payload|
  name "#{payload.fetch(:service, 'client')}.request"
  attributes("response.status" => payload[:status])
end
```

The start evaluation supplies the initial span name and attributes. The final
evaluation updates that same span before it finishes. Added or changed attributes
are recorded; OpenTelemetry does not provide attribute deletion, so an attribute
recorded at start remains if the final mapping omits it. Live headings show the
initial name; completed trees show the final name and attributes. Sampling uses
the initial values.

Spans become current during the operation, so nested notifications, direct spans,
logger messages, and Rails events attach correctly. An operation without a parent
creates a root span. Exceptions in the operation are recorded and re-raised;
exceptions in matchers or transformations are reported to the original logger
without replacing the application's result or exception.

## Payload handling

Both automatic payload attributes and explicit mappings use the same policy:

- Apply the Rails application's `filter_parameters`. Standalone defaults filter
  password, password confirmation, secret, token, and authorization keys.
- Convert attribute keys to strings; preserve strings, finite numbers, and booleans.
- Preserve homogeneous scalar arrays; encode mixed arrays and nested hashes as JSON.
- Convert symbols to strings. Omit top-level nil and unsupported objects; nested
  unsupported values become JSON null. Do not call arbitrary object `inspect`.
- Handle notification `exception` and `exception_object` fields as exception data,
  rather than ordinary attributes. Reserve `log.severity`, `log.tags`, and
  `log.progname` for the logging system.

The original payload is not modified by the gem. Direct calls to the yielded
OpenTelemetry span, such as `span.set_attribute`, bypass this normalization and
filtering; callers are responsible for those values.

## Built-in Rails operations

Request middleware creates a server span and accepts W3C `traceparent` and
`tracestate` headers. Controller actions, SQL operations, templates, layouts,
partials, collections, and selected Action Cable operations become nested spans.
Schema and transaction bookkeeping SQL is omitted by the default mapping.

Existing view switches, allow/deny lists, and partial-depth limits apply to
built-in view spans. Cable mappings select operation metadata rather than copying
client messages. Application rules can override these defaults.

The event reporter integration omits Rails' duplicate completion events for
operations already represented by spans. Other subscribers still receive those
native events. Additional framework facts continue to be captured as events.

Subscriptions are installed once after configuration. Restart the application to
change rules. The gem captures notifications emitted by application work, not
notifications generated while its exporters write their formatted output.
