```elixir
defmodule EventStore.CommandHandler do
  @moduledoc """
  Processes domain commands in an event-sourced system:
  schema validation, aggregate loading, business rule evaluation,
  event generation, and event stream appending.
  """

  alias EventStore.{
    CommandSchema,
    AggregateLoader,
    BusinessRules,
    EventFactory,
    StreamAppender
  }

  require Logger

  @doc """
  Handles `command` dispatched to aggregate `aggregate_id`.

  `command` must have a `:type` and a `:payload` field.

  Returns `{:ok, events}` or a structured command error.
  """
  @spec handle_command(String.t(), map()) ::
          {:ok, list(map())}
          | {:error, :schema_invalid, list()}
          | {:error, :aggregate_not_found}
          | {:error, :rule_violation, String.t()}
          | {:error, :event_factory_failed}
          | {:error, :stream_conflict}
  def handle_command(aggregate_id, command) do
    with {:ok, validated}  <- CommandSchema.validate(command),
         {:ok, aggregate}  <- AggregateLoader.load(aggregate_id, validated.type),
         :ok               <- BusinessRules.evaluate(aggregate, validated),
         {:ok, new_events} <- EventFactory.build(aggregate, validated),
         {:ok, _version}   <- StreamAppender.append(aggregate_id, new_events, aggregate.version) do
      Logger.info("Command #{validated.type} applied to #{aggregate_id}, #{length(new_events)} event(s)")
      {:ok, new_events}
    else
      {:error, :schema, violations} ->
        Logger.debug("Command schema violations: #{inspect(violations)}")
        {:error, :schema_invalid, violations}

      {:error, :not_found} ->
        Logger.warn("Aggregate #{aggregate_id} not found")
        {:error, :aggregate_not_found}

      {:error, :rule, message} ->
        Logger.info("Business rule violation: #{message}")
        {:error, :rule_violation, message}

      {:error, :factory, detail} ->
        Logger.error("Event factory failure: #{inspect(detail)}")
        {:error, :event_factory_failed}

      {:error, :conflict, expected} ->
        Logger.warn("Stream version conflict, expected #{expected}")
        {:error, :stream_conflict}
    end
  end
end
```
