# Megrez

Megrez is a pure Ruby Debug Adapter Protocol (DAP) client. It owns adapter
transport, protocol validation, session state, breakpoints, execution control,
and lazy variable expansion without depending on an editor or UI toolkit.

## Installation

```ruby
gem "megrez"
```

## Usage

```ruby
require "megrez"

session = Megrez::Session.stdio(command: ["rdbg", "--open=vscode", "app.rb"])
session.on(:stopped) { |event| puts "stopped: #{event.fetch("reason")}" }
session.start(adapter_id: "rdbg")
session.launch("program" => File.expand_path("app.rb"))
session.set_breakpoints("app.rb", [
  Megrez::SourceBreakpoint.new(
    line: 12, column: nil, condition: nil, hit_condition: nil,
    log_message: nil
  )
])
session.configuration_done
```

Requests return `Megrez::Future`; call `await(timeout:)` where a blocking
result is needed. Cancelling a future sends the DAP `cancel` request and
rejects the local wait. Event callbacks are delivered in adapter arrival order.

TCP adapters are supported with `Megrez::Session.tcp(host:, port:)`. Adapter
reverse requests such as `runInTerminal` and `startDebugging` can be handled
with `on_request`:

```ruby
session.on_request("startDebugging") { |arguments| start_child(arguments) }
```

Values returned as `variables_reference` embed the current stop generation.
Passing a value from an earlier stop to `variables` or `set_variable` raises
`Megrez::Error` instead of querying stale adapter state.

## Conformance

The bundled fake adapter is exercised by default. Set
`MEGREZ_ADAPTERS=ruby` to additionally run the installed `rdbg` conformance
scenario.

```sh
bundle install
bundle exec rake test
bundle exec rbs -I sig -r stringio validate
BUDGET=1 bundle exec rake bench
gem build --strict megrez.gemspec
```

Adapters are external programs and should be treated as untrusted input.
Megrez does not invoke a shell, caps frame/header/pending-request sizes, and
bounds retained stderr and callback errors. TCP is unencrypted; use it only on
a trusted interface or inside a secure tunnel.

## License

Megrez is available under the MIT License.
