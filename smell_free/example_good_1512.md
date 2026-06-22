```elixir
defmodule Events.AggregateStore do
  @moduledoc """
  Append-only event store for domain aggregates backed by Ecto.

  Provides event sourcing primitives: appending events to an aggregate
  stream, loading an ordered event history, and replaying state from
  a sequence of persisted events.
  """

  import Ecto.Query, warn: false

  alias Events.Repo
  alias Events.StoredEvent
  alias Events.AggregateVersion

  @type aggregate_id :: String.t()
  @type event_type :: String.t()
  @type event_payload :: map()

  @doc """
  Appends a batch of events to an aggregate's stream.

  Enforces optimistic concurrency: the `expected_version` must match
  the current persisted version, or an `:version_conflict` error is
  returned.
  """
  @spec append(aggregate_id(), [map()], non_neg_integer()) ::
          {:ok, non_neg_integer()} | {:error, :version_conflict | :append_failed}
  def append(aggregate_id, events, expected_version)
      when is_binary(aggregate_id) and is_list(events) and is_integer(expected_version) do
    Repo.transaction(fn ->
      with {:ok, current_version} <- lock_and_get_version(aggregate_id),
           :ok <- assert_version(current_version, expected_version),
           {:ok, new_version} <- insert_events(aggregate_id, events, current_version) do
        update_version(aggregate_id, new_version)
        new_version
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> normalize_transaction_result()
  end

  @doc """
  Loads the full ordered event stream for an aggregate.
  """
  @spec load_stream(aggregate_id()) :: {:ok, [StoredEvent.t()]} | {:error, :not_found}
  def load_stream(aggregate_id) when is_binary(aggregate_id) do
    events =
      StoredEvent
      |> where([e], e.aggregate_id == ^aggregate_id)
      |> order_by([e], asc: e.sequence_number)
      |> Repo.all()

    case events do
      [] -> {:error, :not_found}
      list -> {:ok, list}
    end
  end

  @doc """
  Loads events from a given sequence number onward (inclusive).
  """
  @spec load_stream_from(aggregate_id(), non_neg_integer()) ::
          {:ok, [StoredEvent.t()]} | {:error, :not_found}
  def load_stream_from(aggregate_id, from_sequence)
      when is_binary(aggregate_id) and is_integer(from_sequence) and from_sequence >= 0 do
    events =
      StoredEvent
      |> where([e], e.aggregate_id == ^aggregate_id and e.sequence_number >= ^from_sequence)
      |> order_by([e], asc: e.sequence_number)
      |> Repo.all()

    case events do
      [] -> {:error, :not_found}
      list -> {:ok, list}
    end
  end

  @spec lock_and_get_version(aggregate_id()) ::
          {:ok, non_neg_integer()} | {:error, :lock_failed}
  defp lock_and_get_version(aggregate_id) do
    case Repo.get_by(AggregateVersion, aggregate_id: aggregate_id, lock: "FOR UPDATE") do
      nil -> {:ok, 0}
      %AggregateVersion{version: v} -> {:ok, v}
    end
  end

  @spec assert_version(non_neg_integer(), non_neg_integer()) ::
          :ok | {:error, :version_conflict}
  defp assert_version(current, expected) when current == expected, do: :ok
  defp assert_version(_current, _expected), do: {:error, :version_conflict}

  @spec insert_events(aggregate_id(), [map()], non_neg_integer()) ::
          {:ok, non_neg_integer()} | {:error, :append_failed}
  defp insert_events(aggregate_id, events, starting_version) do
    indexed = Enum.with_index(events, starting_version + 1)

    result =
      Enum.reduce_while(indexed, {:ok, starting_version}, fn {event, seq}, _acc ->
        attrs = Map.merge(event, %{aggregate_id: aggregate_id, sequence_number: seq})

        case Repo.insert(StoredEvent.changeset(%StoredEvent{}, attrs)) do
          {:ok, _} -> {:cont, {:ok, seq}}
          {:error, _} -> {:halt, {:error, :append_failed}}
        end
      end)

    result
  end

  @spec update_version(aggregate_id(), non_neg_integer()) :: :ok
  defp update_version(aggregate_id, new_version) do
    Repo.insert!(
      %AggregateVersion{aggregate_id: aggregate_id, version: new_version},
      on_conflict: [set: [version: new_version]],
      conflict_target: :aggregate_id
    )

    :ok
  end

  @spec normalize_transaction_result({:ok, term()} | {:error, term()}) ::
          {:ok, non_neg_integer()} | {:error, term()}
  defp normalize_transaction_result({:ok, version}), do: {:ok, version}
  defp normalize_transaction_result({:error, reason}), do: {:error, reason}
end
```
