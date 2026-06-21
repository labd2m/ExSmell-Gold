```elixir
defmodule MyApp.Pipeline.EventTransformer do
  @moduledoc """
  Applies a configurable sequence of field-level transformations to raw
  event maps arriving from external data sources before they are written
  to the warehouse. Each transformer is a named module implementing the
  `Transformer` behaviour; the pipeline is composed at startup from a
  configuration list, making it easy to add, reorder, or remove steps.

  Transformations are applied in order; if any step returns an error the
  event is routed to the dead-letter list rather than halting the entire
  batch.
  """

  @type raw_event :: map()
  @type transformed_event :: map()
  @type transformer :: module()

  @type batch_result :: %{
          transformed: [transformed_event()],
          dead_letters: [%{event: raw_event(), reason: term()}]
        }

  @doc """
  Applies all `transformers` to each event in `events`. Events that
  fail any step are collected in `dead_letters`; successfully transformed
  events are returned in `transformed`. Order is preserved.
  """
  @spec transform_batch([raw_event()], [transformer()]) :: batch_result()
  def transform_batch(events, transformers)
      when is_list(events) and is_list(transformers) do
    {transformed, dead_letters} =
      Enum.reduce(events, {[], []}, fn event, {ok_acc, dl_acc} ->
        case apply_transformers(event, transformers) do
          {:ok, result} -> {[result | ok_acc], dl_acc}
          {:error, reason} -> {ok_acc, [%{event: event, reason: reason} | dl_acc]}
        end
      end)

    %{
      transformed: Enum.reverse(transformed),
      dead_letters: Enum.reverse(dead_letters)
    }
  end

  @spec apply_transformers(raw_event(), [transformer()]) ::
          {:ok, transformed_event()} | {:error, term()}
  defp apply_transformers(event, transformers) do
    Enum.reduce_while(transformers, {:ok, event}, fn transformer, {:ok, current} ->
      case transformer.transform(current) do
        {:ok, updated} -> {:cont, {:ok, updated}}
        {:error, reason} -> {:halt, {:error, {transformer, reason}}}
      end
    end)
  end
end

defmodule MyApp.Pipeline.Transformer do
  @moduledoc "Behaviour contract for event transformation step modules."

  @callback transform(map()) :: {:ok, map()} | {:error, term()}
end

defmodule MyApp.Pipeline.Transformers.TimestampNormaliser do
  @moduledoc "Normalises `occurred_at` values to UTC `DateTime` structs."

  @behaviour MyApp.Pipeline.Transformer

  @impl MyApp.Pipeline.Transformer
  def transform(%{"occurred_at" => ts} = event) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _offset} ->
        {:ok, Map.put(event, "occurred_at", DateTime.shift_zone!(dt, "Etc/UTC"))}

      {:error, _} ->
        {:error, :invalid_timestamp}
    end
  end

  def transform(event), do: {:ok, event}
end

defmodule MyApp.Pipeline.Transformers.SchemaEnforcer do
  @moduledoc "Rejects events missing required top-level fields."

  @behaviour MyApp.Pipeline.Transformer

  @required_fields ~w(event_id source occurred_at)

  @impl MyApp.Pipeline.Transformer
  def transform(event) when is_map(event) do
    missing = Enum.reject(@required_fields, &Map.has_key?(event, &1))

    if missing == [] do
      {:ok, event}
    else
      {:error, {:missing_fields, missing}}
    end
  end
end
```
