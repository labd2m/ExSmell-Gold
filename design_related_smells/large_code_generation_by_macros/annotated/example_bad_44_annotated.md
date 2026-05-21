# Annotated Example — Code Smell: Large code generation by macros

## Metadata

| Field                    | Detail                                                                                          |
|--------------------------|-------------------------------------------------------------------------------------------------|
| **Smell name**           | Large code generation by macros                                                                 |
| **Expected smell location** | `defmacro on_event/3`, lines ~55–120                                                        |
| **Affected function(s)** | `on_event/3`                                                                                    |
| **Explanation**          | Every call to `on_event/3` expands a large `quote` block into the calling module: event-name and topic validation, retry-option normalisation, module-attribute accumulation, a full `handle_event/2` clause, and a `retry_policy/1` clause. In a real notification dispatcher that registers 15–25 event types, all this code is individually compiled for each handler registration, producing a significantly larger `.beam` file and slower compilation compared to delegating to a plain function. |

---

```elixir
defmodule MyApp.Notifications.Dispatcher do
  @moduledoc """
  DSL for registering event-driven notification handlers.

  Each `on_event/3` declaration wires an event name to a handler module,
  optionally configuring retry behaviour and the delivery topic.

  ## Usage

      defmodule MyApp.Notifications.Handlers do
        use MyApp.Notifications.Dispatcher

        on_event "invoice.created",  MyApp.Notifications.InvoiceCreatedHandler,
                 topic: :billing,  retries: 3

        on_event "invoice.paid",     MyApp.Notifications.InvoicePaidHandler,
                 topic: :billing,  retries: 5

        on_event "user.registered",  MyApp.Notifications.WelcomeEmailHandler,
                 topic: :identity, retries: 2

        on_event "shipment.updated", MyApp.Notifications.ShipmentHandler,
                 topic: :logistics
      end
  """

  @valid_topics [:billing, :identity, :logistics, :payments, :reporting, :internal]
  @max_retries 10

  defmacro __using__(_opts) do
    quote do
      import MyApp.Notifications.Dispatcher, only: [on_event: 3]
      Module.register_attribute(__MODULE__, :event_handlers, accumulate: true)
      @before_compile MyApp.Notifications.Dispatcher
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      def registered_events do
        @event_handlers |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
      end

      def handler_for(event_name) do
        case Enum.find(@event_handlers, fn {e, _, _} -> e == event_name end) do
          {_event, handler, _opts} -> {:ok, handler}
          nil -> {:error, :not_found}
        end
      end

      def handle_event(_event, _payload), do: {:error, :unhandled_event}
      def retry_policy(_event), do: {0, :no_retry}
    end
  end

  # VALIDATION: SMELL START - Large code generation by macros
  # VALIDATION: This is a smell because on every call to on_event/3 the entire quote block
  # is expanded inside the caller's module. This includes: a binary check on the event name,
  # a string-length guard, a topic membership check, a retries boundary validation, opts
  # normalisation logic, a module-attribute write, and two complete overriding function
  # clauses (handle_event/2 and retry_policy/1) each with their own pattern matching and
  # inline logic. With 15–25 registrations in a typical dispatcher, all of this code is
  # expanded and compiled that many times. Delegating the validation and attribute writing
  # to a plain helper function would keep the macro footprint minimal.
  defmacro on_event(event_name, handler_module, opts \\ []) do
    quote do
      unless is_binary(unquote(event_name)) do
        raise ArgumentError,
              "on_event/3: event_name must be a binary, got: #{inspect(unquote(event_name))}"
      end

      unless String.length(unquote(event_name)) > 0 do
        raise ArgumentError, "on_event/3: event_name must not be an empty string"
      end

      unless String.contains?(unquote(event_name), ".") do
        raise ArgumentError,
              "on_event/3: event_name must be namespaced (e.g. \"invoice.created\"), " <>
                "got: #{inspect(unquote(event_name))}"
      end

      topic   = Keyword.get(unquote(opts), :topic, :internal)
      retries = Keyword.get(unquote(opts), :retries, 0)

      unless topic in unquote(@valid_topics) do
        raise ArgumentError,
              "on_event/3: unknown topic #{inspect(topic)}. " <>
                "Valid topics: #{inspect(unquote(@valid_topics))}"
      end

      unless is_integer(retries) and retries >= 0 and retries <= unquote(@max_retries) do
        raise ArgumentError,
              "on_event/3: retries must be an integer between 0 and #{unquote(@max_retries)}, " <>
                "got: #{inspect(retries)}"
      end

      @event_handlers {unquote(event_name), unquote(handler_module), [topic: topic, retries: retries]}

      def handle_event(unquote(event_name), payload) do
        unquote(handler_module).call(payload)
      end

      def retry_policy(unquote(event_name)) do
        retries = unquote(retries)
        backoff = if retries > 3, do: :exponential, else: :linear
        {retries, backoff}
      end
    end
  end
  # VALIDATION: SMELL END

  @doc "Returns all topics known to the dispatcher."
  def valid_topics, do: @valid_topics
end
```
