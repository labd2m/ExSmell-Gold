# File: `example_good_610.md`

```elixir
defmodule Events.AggregateProjector do
  @moduledoc """
  Projects a stream of domain events onto a read-model by applying
  registered handler functions per event type.

  Projectors are stateless modules. Each handler receives the current
  read-model state and an event, returning an updated state. The
  projector can be replayed from any checkpoint by supplying the
  relevant event slice.
  """

  @type event_type :: atom()
  @type event :: %{required(:type) => event_type(), required(:payload) => map()}
  @type read_model :: map()
  @type handler_fn :: (read_model(), event() -> read_model())

  @type projection_result :: %{
          model: read_model(),
          events_applied: non_neg_integer(),
          last_event_type: event_type() | nil
        }

  @doc """
  Projects all `events` onto `initial_model` using the handlers in
  `projection_module`.

  The projection module must implement a `handlers/0` callback returning
  a map of `%{event_type => handler_fn}`. Unknown event types are skipped
  with a warning rather than raising.

  Returns a `projection_result` with the final model state.
  """
  @spec project([event()], read_model(), module()) :: projection_result()
  def project(events, initial_model, projection_module)
      when is_list(events) and is_map(initial_model) do
    handlers = projection_module.handlers()

    Enum.reduce(events, {initial_model, 0, nil}, fn event, {model, count, _last} ->
      case Map.fetch(handlers, event.type) do
        {:ok, handler_fn} ->
          updated = handler_fn.(model, event)
          {updated, count + 1, event.type}

        :error ->
          require Logger
          Logger.debug("#{projection_module}: no handler for event type #{inspect(event.type)}")
          {model, count, event.type}
      end
    end)
    |> then(fn {model, count, last_type} ->
      %{model: model, events_applied: count, last_event_type: last_type}
    end)
  end

  @doc """
  Re-projects from a known checkpoint state, applying only events
  with sequence numbers greater than `after_sequence`.
  """
  @spec replay_from(read_model(), [event()], non_neg_integer(), module()) :: projection_result()
  def replay_from(checkpoint_model, events, after_sequence, projection_module)
      when is_map(checkpoint_model) and is_list(events) and is_integer(after_sequence) do
    remaining = Enum.filter(events, fn event ->
      Map.get(event, :sequence, 0) > after_sequence
    end)

    project(remaining, checkpoint_model, projection_module)
  end

  @doc """
  Builds a snapshot map suitable for use as a future checkpoint,
  recording the highest applied sequence number alongside the model.
  """
  @spec to_snapshot(projection_result(), [event()]) :: %{
          model: read_model(),
          checkpoint_sequence: non_neg_integer(),
          snapshot_at: DateTime.t()
        }
  def to_snapshot(%{model: model}, events) do
    max_seq =
      events
      |> Enum.map(&Map.get(&1, :sequence, 0))
      |> Enum.max(fn -> 0 end)

    %{model: model, checkpoint_sequence: max_seq, snapshot_at: DateTime.utc_now()}
  end

  @doc """
  Validates that a projection module exports the required `handlers/0`
  callback and that all returned handlers are arity-2 functions.

  Returns `:ok` or `{:error, reasons}`.
  """
  @spec validate_module(module()) :: :ok | {:error, [String.t()]}
  def validate_module(mod) do
    errors =
      cond do
        not function_exported?(mod, :handlers, 0) ->
          ["#{mod} does not export handlers/0"]

        true ->
          handlers = mod.handlers()

          Enum.flat_map(handlers, fn {type, handler} ->
            if is_function(handler, 2) do
              []
            else
              ["handler for #{inspect(type)} must be an arity-2 function"]
            end
          end)
      end

    case errors do
      [] -> :ok
      _ -> {:error, errors}
    end
  end
end
```
