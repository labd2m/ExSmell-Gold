```elixir
defmodule Events.AggregateStore do
  @moduledoc """
  An event-sourced aggregate store that appends domain events to
  a persistent stream and rebuilds aggregate state by replaying events.
  """

  alias Events.{Repo, EventRecord, Aggregate}

  @type aggregate_id :: String.t()
  @type aggregate_type :: atom()
  @type domain_event :: map()

  @spec append(aggregate_id(), aggregate_type(), [domain_event()], non_neg_integer()) ::
          {:ok, non_neg_integer()} | {:error, :version_conflict | Ecto.Changeset.t()}
  def append(aggregate_id, aggregate_type, events, expected_version)
      when is_binary(aggregate_id) and is_atom(aggregate_type) and is_list(events) do
    current_version = fetch_current_version(aggregate_id)

    if current_version == expected_version do
      write_events(aggregate_id, aggregate_type, events, current_version)
    else
      {:error, :version_conflict}
    end
  end

  @spec rebuild(aggregate_id(), module()) :: {:ok, Aggregate.t()} | {:error, :not_found}
  def rebuild(aggregate_id, aggregate_module) when is_binary(aggregate_id) do
    events = load_events(aggregate_id)

    case events do
      [] ->
        {:error, :not_found}

      _ ->
        state =
          Enum.reduce(events, aggregate_module.initial_state(), fn event, acc ->
            aggregate_module.apply_event(acc, event.event_type, event.payload)
          end)

        {:ok, state}
    end
  end

  @spec load_events(aggregate_id()) :: [EventRecord.t()]
  defp load_events(aggregate_id) do
    import Ecto.Query

    from(e in EventRecord,
      where: e.aggregate_id == ^aggregate_id,
      order_by: [asc: e.sequence_number]
    )
    |> Repo.all()
  end

  @spec fetch_current_version(aggregate_id()) :: non_neg_integer()
  defp fetch_current_version(aggregate_id) do
    import Ecto.Query

    from(e in EventRecord,
      where: e.aggregate_id == ^aggregate_id,
      select: coalesce(max(e.sequence_number), 0)
    )
    |> Repo.one()
  end

  @spec write_events(aggregate_id(), aggregate_type(), [domain_event()], non_neg_integer()) ::
          {:ok, non_neg_integer()} | {:error, Ecto.Changeset.t()}
  defp write_events(aggregate_id, aggregate_type, events, start_version) do
    records =
      events
      |> Enum.with_index(start_version + 1)
      |> Enum.map(fn {event, seq} ->
        %{
          aggregate_id: aggregate_id,
          aggregate_type: to_string(aggregate_type),
          event_type: event.type,
          payload: event.payload,
          sequence_number: seq,
          inserted_at: DateTime.utc_now()
        }
      end)

    case Repo.insert_all(EventRecord, records) do
      {count, _} -> {:ok, start_version + count}
    end
  end
end
```
