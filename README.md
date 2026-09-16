<h1 align="center">Megrez</h1>

<p align="center">
  <strong>Pure Ruby Debug Adapter Protocol client</strong>
</p>

<p align="center">
  <a href="https://rubygems.org/gems/megrez"><img src="https://img.shields.io/gem/v/megrez.svg?colorB=319e8c" alt="Gem Version"></a>
  <a href="https://rubygems.org/gems/megrez"><img src="https://img.shields.io/gem/dt/megrez.svg" alt="Downloads"></a>
  <img src="https://img.shields.io/badge/ruby-%3E%3D%203.1-ruby.svg" alt="Ruby Version">
  <a href="LICENSE.txt"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT License"></a>
</p>

<p align="center">
  <a href="#features">Features</a> ·
  <a href="#installation">Installation</a> ·
  <a href="#quick-start">Quick Start</a> ·
  <a href="#sessions">Sessions</a> ·
  <a href="#conformance">Conformance</a> ·
  <a href="#security">Security</a>
</p>

---

Megrez is a pure Ruby Debug Adapter Protocol (DAP) client. It owns adapter
transport, protocol validation, session state, breakpoints, execution control,
and lazy variable expansion without depending on an editor or UI toolkit.

## Features

- Debug Adapter Protocol sessions over stdio or TCP
- Breakpoints, execution control, stack frames, scopes, variables, and evaluation
- Ordered events and adapter reverse-request handlers
- Cancellable, timeout-aware futures for every request
- Generation-safe variable references that reject stale debugger state
- Built-in fake adapter and optional `rdbg` conformance testing

## Installation

```ruby
gem "megrez"
```

Megrez supports Ruby 3.1 and later.

## Quick Start

```ruby
require "megrez"

session = Megrez::Session.stdio(command: ["path/to/debug-adapter", "--stdio"])
session.on(:stopped) { |event| puts "stopped: #{event.fetch("reason")}" }
initialized = Queue.new
session.on(:initialized) { initialized << true }
session.start(adapter_id: "my-adapter")
launch = session.launch("program" => File.expand_path("app.rb"))
initialized.pop
session.set_breakpoints("app.rb", [
  Megrez::SourceBreakpoint.new(
    line: 12, column: nil, condition: nil, hit_condition: nil,
    log_message: nil
  )
]).await(timeout: 5)
session.configuration_done.await(timeout: 5)
launch.await(timeout: 5)
```

## Sessions

Requests return `Megrez::Future`; call `await(timeout:)` where a blocking
result is needed. Cancelling a future sends the DAP `cancel` request and
rejects the local wait. Event callbacks are delivered in adapter arrival order.

TCP adapters are supported with `Megrez::Session.tcp(host:, port:)`. Adapter
reverse requests such as `runInTerminal` and `startDebugging` can be handled
with `on_request`:

```ruby
session.on_request("startDebugging") { |arguments| start_child(arguments) }
```

Register reverse-request handlers before `start`; Megrez advertises only the
requests that have handlers.

Values returned as `variables_reference` embed the current stop generation.
Passing a value from an earlier stop to `variables` or `set_variable` raises
`Megrez::Error` instead of querying stale adapter state.

## Conformance

The bundled fake adapter is exercised by default. Set
`MEGREZ_ADAPTERS=ruby` to additionally run the installed `rdbg` conformance
scenario.

## Development

```sh
bundle install
bundle exec rake test
bundle exec rbs -I sig -r stringio validate
BUDGET=1 bundle exec rake bench
gem build --strict megrez.gemspec
```

## Security

Adapters are external programs and should be treated as untrusted input.
Megrez does not invoke a shell, caps frame/header/pending-request sizes, and
bounds retained stderr and callback errors. TCP is unencrypted; use it only on
a trusted interface or inside a secure tunnel.

## Contributing

Bug reports and pull requests are welcome at https://github.com/noxdea/megrez.

## License

Megrez is available under the [MIT License](LICENSE.txt).
