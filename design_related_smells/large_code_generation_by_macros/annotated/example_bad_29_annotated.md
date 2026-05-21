# Annotated Example — Bad Code

## Metadata

- **Smell name:** Large code generation by macros
- **Expected smell location:** `defmacro on_event/2` inside `MyApp.Events.HandlerDSL`
- **Affected function(s):** `on_event/2` macro
- **Short explanation:** The macro expands a large `quote` block on every call, inlining event-name validation, handler-module compilation checks, callback verification, filter option validation, priority checks, deduplication guards, and struct registration. A module handling many event types causes the compiler to expand and compile all of this logic repeatedly at each call site.

---

```elixir
defmodule MyApp.Events.HandlerDSL do
  @moduledoc """
  DSL for registering domain event handlers within a subscriber module.

  Example:

      defmodule MyApp.Events.OrderSubscriber do
        use MyApp.Events.HandlerDSL

        on_event MyApp.Events.OrderPlaced,
          handler:  MyApp.Handlers.NotifyWarehouse,
          priority: :high

        on_event MyApp.Events.OrderShipped,
          handler:  MyApp.Handlers.NotifyCustomer,
          priority: :medium,
          filter:   &match?(%{express: true}, &1)

        on_event MyApp.Events.OrderCancelled,
          handler:  MyApp.Handlers.RefundPayment,
          priority: :critical
      end
  """

  defmacro __using__(_opts) do
    quote do
      import MyApp.Events.HandlerDSL, only: [on_event: 2]
      Module.register_attribute(__MODULE__, :event_subscriptions, accumulate: true)
      @before_compile MyApp.Events.HandlerDSL
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      def subscriptions, do: @event_subscriptions

      def handlers_for(event_type) do
        @event_subscriptions
        |> Enum.filter(fn s -> s.event == event_type end)
        |> Enum.sort_by(fn s ->
          %{critical: 0, high: 1, medium: 2, low: 3}[s.priority]
        end)
      end
    end
  end

  # VALIDATION: SMELL START - Large code generation by macros
  # VALIDATION: This is a smell because every call to on_event/2 causes the
  # VALIDATION: compiler to expand this entire block: event-module checks,
  # VALIDATION: Code.ensure_compiled!, handle_event/1 callback check, priority
  # VALIDATION: enumeration check, filter-function arity check, async-flag check,
  # VALIDATION: deduplication guard, and struct construction. A subscriber module
  # VALIDATION: with many event types compiles all of this code at every call site
  # VALIDATION: instead of delegating to a single shared function.
  defmacro on_event(event_module, opts) do
    quote do
      event_module = unquote(event_module)
      opts         = unquote(opts)

      unless is_atom(event_module) do
        raise ArgumentError,
              "on_event/2: first argument must be an event module atom, " <>
                "got #{inspect(event_module)}"
      end

      :ok = Code.ensure_compiled!(event_module)

      handler = Keyword.fetch!(opts, :handler)

      unless is_atom(handler) do
        raise ArgumentError,
              "on_event/2: :handler must be a module atom, got #{inspect(handler)}"
      end

      :ok = Code.ensure_compiled!(handler)

      unless function_exported?(handler, :handle_event, 1) do
        raise ArgumentError,
              "on_event/2: #{inspect(handler)} must export handle_event/1"
      end

      valid_priorities = [:low, :medium, :high, :critical]
      priority = Keyword.get(opts, :priority, :medium)

      unless priority in valid_priorities do
        raise ArgumentError,
              "on_event/2: :priority must be one of #{inspect(valid_priorities)}, " <>
                "got #{inspect(priority)}"
      end

      filter = Keyword.get(opts, :filter)

      if not is_nil(filter) do
        unless is_function(filter, 1) do
          raise ArgumentError,
                "on_event/2: :filter must be a 1-arity function, got #{inspect(filter)}"
        end
      end

      async = Keyword.get(opts, :async, false)

      unless is_boolean(async) do
        raise ArgumentError,
              "on_event/2: :async must be a boolean, got #{inspect(async)}"
      end

      existing = Module.get_attribute(__MODULE__, :event_subscriptions)

      if Enum.any?(existing, fn s ->
           s.event == event_module and s.handler == handler
         end) do
        raise ArgumentError,
              "on_event/2: #{inspect(handler)} is already registered for " <>
                "#{inspect(event_module)} in #{inspect(__MODULE__)}"
      end

      subscription = %{
        event:    event_module,
        handler:  handler,
        priority: priority,
        filter:   filter,
        async:    async
      }

      @event_subscriptions subscription
    end
  end
  # VALIDATION: SMELL END

  @doc """
  Dispatches `event` to all matching handlers registered in `subscriber_module`.
  Passes the event through the handler's filter before invoking `handle_event/1`.
  """
  @spec dispatch(module(), struct()) :: :ok
  def dispatch(subscriber_module, event) do
    event_type = event.__struct__

    subscriber_module.handlers_for(event_type)
    |> Enum.each(fn sub ->
      if is_nil(sub.filter) or sub.filter.(event) do
        if sub.async do
          Task.start(fn -> sub.handler.handle_event(event) end)
        else
          sub.handler.handle_event(event)
        end
      end
    end)
  end
end
```
