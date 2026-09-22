# Configuration reference

[Back to the README](../README.md)

Configure the gem in `config/initializers/rails_otel_logging.rb`. Restart the
application after changing the provider, instrumentation switches, or output mode.
Defaults below assume no environment overrides.

## Options

| Option | Default | Purpose |
| --- | --- | --- |
| `output_mode` | `:live_delayed_on_error` | Choose when trees are printed; see [output modes](../README.md#output-modes). |
| `rails_logs` | `:replace` | Suppress duplicate Rails subscribers during gem traces; `:preserve` keeps them active. |
| `service_name` | `'rails_app'` | Service name on the managed provider's resource. |
| `service_version` | `'1.0.0'` | Service version on the managed provider's resource. |
| `tracer_provider` | `nil` | Use the managed Rails provider, or supply an SDK provider instance or lambda. |
| `colorize` | `false` | Enable ANSI colors in output. |
| `theme` | `OtelLogging::Theme.new` | Customize colors and emphasis through the theme object. |
| `enable_active_record` | `true` | Capture SQL notifications. |
| `enable_action_controller` | `true` | Capture controller notifications. |
| `enable_action_cable` | `true` | Capture Action Cable notifications. |
| `enable_templates` | `true` | Trace view templates. |
| `enable_layouts` | `true` | Trace view layouts. |
| `enable_partials` | `true` | Trace partial rendering. |
| `enable_action_view` | `true` | Set templates, layouts, and partials together; reads as true if any is enabled. |
| `partial_max_depth` | `nil` | Limit nested partial tracing; `nil` means unlimited. |
| `view_allowlist` | `nil` | Include only matching view paths when a nonempty list is supplied. |
| `view_denylist` | `nil` | Exclude matching view paths; takes precedence over the allowlist. |
| `include_params_in_views` | `true` | Include filtered request parameters in template spans. |

View lists accept regular expressions or strings. Plain strings match substrings;
strings containing `*` use path patterns (`*` for one path segment, `**` across
segments).

## Colors and theme

Enable colors and customize individual styles in your initializer:

```ruby
OtelLogging.configure do |config|
  config.colorize = true
  config.theme.set(:duration, fg: :cyan)
  config.theme.set(:event_warn, fg: :yellow, bold: true)
end
```

## Provider ownership

Rails creates a private SDK provider by default, manages its lifecycle, and sets
its resource using `service_name` and `service_version`. It does not replace the
global OpenTelemetry provider.

`config.tracer_provider` can be an explicit provider instance or a lambda. A lambda
is resolved after application initializers, so an application can supply an
explicitly configured OpenTelemetry SDK provider after configuring exporters and
processors:

```ruby
OtelLogging.configure do |config|
  config.tracer_provider = -> { configured_sdk_provider }
end
```

`configured_sdk_provider` above represents your application's provider.
The lambda must return the application's configured SDK tracer provider with its
exporters and processors. Do not resolve the default OpenTelemetry API no-op
provider.

When an external provider is supplied, the application owns its lifecycle, including
shutdown. The gem adds its logging processors without replacing the global provider.
Exporters write through the logger's original `add` method so their formatted
output is not captured again.
The automatic middleware and lazy subscriber hooks remain enabled.

## Rails subscriber output

`rails_logs` defaults to `:replace`. Set it to `:preserve` when Rails' original
request, view, or SQL subscribers should continue to emit their logs during traces.
ActionCable's application-owned connection logger remains unchanged in both modes.
The environment variable `OTEL_RAILS_LOGS` accepts `replace` or `preserve` and is
overridden by `OtelLogging.configure`.

## Environment variables

Each variable sets the default for one configuration switch when the process
starts. A later `OtelLogging.configure` block wins over the variable. Boolean
variables read `true`, `1`, `yes`, or `on` (any letter case) as true, and every
other value as false.

| Variable | Config switch | Default |
| --- | --- | --- |
| `OTEL_RAILS_LOGS` | `rails_logs` (`replace` or `preserve`) | `replace` |
| `OTEL_ACTIVE_RECORD` | `enable_active_record` | `true` |
| `OTEL_ACTION_CONTROLLER` | `enable_action_controller` | `true` |
| `OTEL_ACTION_CABLE` | `enable_action_cable` | `true` |
| `OTEL_VIEW_TEMPLATES` | `enable_templates` | `true` |
| `OTEL_VIEW_LAYOUTS` | `enable_layouts` | `true` |
| `OTEL_VIEW_PARTIALS` | `enable_partials` | `true` |
| `OTEL_VIEW_PARAMS` | `include_params_in_views` | `true` |
| `OTEL_VIEW_PARTIAL_DEPTH` | `partial_max_depth` | unset, meaning unlimited depth |
| `OTEL_COLORIZE` | `colorize` | unset, meaning colors stay off |

Colors are off by default. `OTEL_COLORIZE` explicitly enables or disables them
and takes precedence over `NO_COLOR`. Without `OTEL_COLORIZE`, colors remain off,
including when `NO_COLOR` is present. Setting `config.colorize` in an initializer
overrides these environment defaults.

## Loading Rails explicitly

Normal Rails applications load the integration automatically. If you require the
core gem before Rails itself, require `rails_otel_logging/rails` after Rails has
loaded to register the Railtie. Middleware and notification hooks are installed
automatically; subscribers load when their Rails component is available.
