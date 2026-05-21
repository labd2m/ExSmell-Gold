# Code Smell Example — Annotated

## Metadata

- **Smell name:** Using exceptions for control-flow
- **Expected smell location:** `Audit.EventEmitter.emit/1`
- **Affected function(s):** `Audit.EventEmitter.emit/1` (library side); `Audit.ComplianceLogger.log_action/4` (client side)
- **Explanation:** `emit/1` raises `RuntimeError` when the event struct is missing required fields or contains an unrecognised event type. These are ordinary schema-validation issues that an application emitting audit events needs to handle gracefully — for example, by logging a meta-error or falling back. Raising forces the caller to use `try/rescue` as the only mechanism to detect and react to an invalid audit event.

```elixir
defmodule Audit.EventType do
  @moduledoc "Registry of recognised audit event types."

  @types [
    :user_login,
    :user_logout,
    :password_changed,
    :permission_granted,
    :permission_revoked,
    :data_exported,
    :record_deleted,
    :api_key_created,
    :api_key_revoked,
    :billing_updated,
    :subscription_changed
  ]

  def valid?(type), do: type in @types
  def all, do: @types
end

defmodule Audit.Event do
  @moduledoc "An audit event record destined for the compliance log."

  @enforce_keys [:type, :actor_id, :resource_type, :resource_id, :occurred_at]
  defstruct [
    :id,
    :type,
    :actor_id,
    :resource_type,
    :resource_id,
    :occurred_at,
    :ip_address,
    :session_id,
    :metadata
  ]
end

defmodule Audit.EventStore do
  @moduledoc "Simulated append-only event store."

  use Agent

  def start_link(_), do: Agent.start_link(fn -> [] end, name: __MODULE__)

  def append(event), do: Agent.update(__MODULE__, &[event | &1])

  def all, do: Agent.get(__MODULE__, &Enum.reverse(&1))

  def count, do: Agent.get(__MODULE__, &length(&1))
end

defmodule Audit.EventEmitter do
  @moduledoc """
  Validates and persists audit events to the append-only compliance store.
  All events must carry required fields and a recognised event type.
  """

  alias Audit.{Event, EventStore, EventType}
  require Logger

  @required_fields [:type, :actor_id, :resource_type, :resource_id, :occurred_at]

  # VALIDATION: SMELL START - Using exceptions for control-flow
  # VALIDATION: This is a smell because `emit/1` raises RuntimeError for two
  # VALIDATION: predictable validation problems: a missing required field and an
  # VALIDATION: unrecognised event type. Application code emitting audit events
  # VALIDATION: needs to handle validation failures gracefully (e.g., record the
  # VALIDATION: meta-error or emit to a dead-letter store). With no {:error, reason}
  # VALIDATION: path available, callers are forced to use try/rescue for this
  # VALIDATION: ordinary validation control-flow.
  def emit(%Event{} = event) do
    Enum.each(@required_fields, fn field ->
      value = Map.get(event, field)

      if is_nil(value) do
        raise RuntimeError,
          message:
            "Audit event is missing required field '#{field}'. " <>
              "All events must include: #{Enum.join(@required_fields, ", ")}"
      end
    end)

    unless EventType.valid?(event.type) do
      raise RuntimeError,
        message:
          "Unknown audit event type '#{event.type}'. " <>
            "Recognised types: #{Enum.map_join(EventType.all(), ", ", &":#{&1}")}"
    end

    stamped_event = %{event | id: "evt_#{:rand.uniform(9_999_999)}"}
    EventStore.append(stamped_event)

    Logger.info(
      "Audit event emitted: type=#{event.type} actor=#{event.actor_id} " <>
        "resource=#{event.resource_type}:#{event.resource_id}"
    )

    stamped_event
  end
  # VALIDATION: SMELL END
end

defmodule Audit.ComplianceLogger do
  @moduledoc """
  High-level compliance logging interface used across the application.
  Wraps EventEmitter and handles structural validation failures gracefully.
  """

  alias Audit.{Event, EventEmitter}
  require Logger

  def log_action(type, actor_id, resource_type, resource_id, opts \\ []) do
    event = %Event{
      type: type,
      actor_id: actor_id,
      resource_type: resource_type,
      resource_id: resource_id,
      occurred_at: DateTime.utc_now(),
      ip_address: Keyword.get(opts, :ip_address),
      session_id: Keyword.get(opts, :session_id),
      metadata: Keyword.get(opts, :metadata, %{})
    }

    # Client forced to use try/rescue because EventEmitter.emit/1 raises
    # on validation failures instead of returning {:error, reason}.
    try do
      emitted = EventEmitter.emit(event)
      {:ok, emitted.id}
    rescue
      e in RuntimeError ->
        Logger.error(
          "ComplianceLogger: failed to emit audit event type=#{type} " <>
            "actor=#{actor_id}: #{e.message}"
        )

        {:error, e.message}
    end
  end

  def log_batch(events) when is_list(events) do
    Enum.map(events, fn %{type: t, actor: a, resource_type: rt, resource_id: rid} ->
      %{result: log_action(t, a, rt, rid)}
    end)
  end
end
```
