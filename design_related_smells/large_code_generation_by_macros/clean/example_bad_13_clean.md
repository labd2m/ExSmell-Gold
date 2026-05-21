```elixir
defmodule Events.EventDSL do
  @moduledoc """
  Compile-time DSL for declaring domain events published to the event bus.

  Each event carries a topic string, a schema version, a list of required
  payload keys, a retention policy, and optional ordering guarantees.
  Declarations are validated at compile time.
  """

  @valid_retention_policies [:ephemeral, :short_term, :long_term, :permanent]

  defmacro defevent(event_name, opts) do
    quote do
      event = unquote(event_name)
      opts  = unquote(opts)

      unless is_atom(event) do
        raise ArgumentError,
              "event name must be an atom, got: #{inspect(event)}"
      end

      topic = Keyword.fetch!(opts, :topic)

      unless is_binary(topic) do
        raise ArgumentError,
              "event #{inspect(event)} :topic must be a binary"
      end

      unless String.contains?(topic, ".") do
        raise ArgumentError,
              "event #{inspect(event)} :topic '#{topic}' must be namespaced with at least one dot"
      end

      schema_version = Keyword.get(opts, :schema_version, 1)

      unless is_integer(schema_version) and schema_version >= 1 do
        raise ArgumentError,
              "event #{inspect(event)} :schema_version must be a positive integer"
      end

      payload_keys = Keyword.get(opts, :payload_keys, [])

      unless is_list(payload_keys) and Enum.all?(payload_keys, &is_atom/1) do
        raise ArgumentError,
              "event #{inspect(event)} :payload_keys must be a list of atoms"
      end

      retention = Keyword.get(opts, :retention, :short_term)

      unless retention in unquote(@valid_retention_policies) do
        raise ArgumentError,
              "event #{inspect(event)} :retention must be one of #{inspect(unquote(@valid_retention_policies))}"
      end

      ordered = Keyword.get(opts, :ordered, false)

      unless is_boolean(ordered) do
        raise ArgumentError,
              "event #{inspect(event)} :ordered must be a boolean"
      end

      description = Keyword.get(opts, :description, "")

      unless is_binary(description) do
        raise ArgumentError,
              "event #{inspect(event)} :description must be a binary"
      end

      idempotency_key = Keyword.get(opts, :idempotency_key)

      if idempotency_key != nil do
        unless is_atom(idempotency_key) and idempotency_key in payload_keys do
          raise ArgumentError,
                "event #{inspect(event)} :idempotency_key must be an atom present in :payload_keys"
        end
      end

      @domain_events %{
        name:             event,
        topic:            topic,
        schema_version:   schema_version,
        payload_keys:     payload_keys,
        retention:        retention,
        ordered:          ordered,
        description:      description,
        idempotency_key:  idempotency_key
      }
    end
  end

  defmacro __using__(_) do
    quote do
      import Events.EventDSL, only: [defevent: 2]
      Module.register_attribute(__MODULE__, :domain_events, accumulate: true)
      @before_compile Events.EventDSL
    end
  end

  defmacro __before_compile__(env) do
    events = Module.get_attribute(env.module, :domain_events)

    quote do
      def events, do: unquote(Macro.escape(events))

      def event(name) do
        Enum.find(events(), &(&1.name == name))
      end

      def topic(name) do
        case event(name) do
          nil -> {:error, :not_found}
          e   -> {:ok, e.topic}
        end
      end
    end
  end
end

defmodule Events.AppEvents do
  use Events.EventDSL

  defevent(:user_registered,
    topic: "users.registered",
    schema_version: 2,
    payload_keys: [:user_id, :email, :inserted_at],
    retention: :long_term,
    ordered: true,
    description: "Fired when a new user completes registration",
    idempotency_key: :user_id
  )

  defevent(:payment_captured,
    topic: "payments.captured",
    schema_version: 1,
    payload_keys: [:payment_id, :amount, :currency, :gateway],
    retention: :permanent,
    ordered: true,
    description: "Fired when a payment capture succeeds",
    idempotency_key: :payment_id
  )

  defevent(:invoice_voided,
    topic: "billing.invoice_voided",
    schema_version: 1,
    payload_keys: [:invoice_id, :voided_by, :reason, :voided_at],
    retention: :long_term,
    ordered: false,
    description: "Fired when an invoice is voided"
  )

  defevent(:shipment_delivered,
    topic: "logistics.shipment_delivered",
    schema_version: 3,
    payload_keys: [:shipment_id, :delivered_at, :signature],
    retention: :long_term,
    ordered: true,
    description: "Fired when a shipment is marked delivered",
    idempotency_key: :shipment_id
  )

  defevent(:subscription_renewed,
    topic: "billing.subscription_renewed",
    schema_version: 1,
    payload_keys: [:subscription_id, :renewed_at, :next_billing_date],
    retention: :permanent,
    ordered: true,
    description: "Fired when a subscription renews successfully"
  )

  defevent(:password_reset_requested,
    topic: "auth.password_reset_requested",
    schema_version: 1,
    payload_keys: [:user_id, :token_hash, :expires_at],
    retention: :ephemeral,
    ordered: false,
    description: "Fired when a user requests a password reset"
  )
end
```
