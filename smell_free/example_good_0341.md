```elixir
defmodule Platform.EventStore do
  @moduledoc """
  An append-only event store for domain events, built on top of Ecto.

  Events are immutable once written. The store supports appending with
  optimistic concurrency control (via expected version), stream-level
  subscriptions via PubSub, and efficient positional reads.
  """

  import Ecto.Query, only: [from: 2]
  alias Ecto.Multi
  alias Platform.{Repo, EventStore.StoredEvent}

  @type stream_id :: String.t()
  @type event_type :: String.t()
  @type event_data :: map()
  @type version :: non_neg_integer()

  @type append_opts :: [{:expected_version, version() | :any | :no_stream}]
  @type read_opts :: [from_version: version(), limit: pos_integer()]

  @doc """
  Appends a list of events to `stream_id`.

  Pass `expected_version: n` for optimistic concurrency — the append fails
  with `{:error, :wrong_expected_version}` if the stream's current version
  does not equal `n`. Use `:any` to skip the check or `:no_stream` to assert
  the stream does not yet exist.
  """
  @spec append(stream_id(), [{event_type(), event_data()}], append_opts()) ::
          {:ok, [StoredEvent.t()]} | {:error, :wrong_expected_version | Ecto.Changeset.t()}
  def append(stream_id, events, opts \\ []) when is_binary(stream_id) and is_list(events) do
    expected_version = Keyword.get(opts, :expected_version, :any)

    Multi.new()
    |> Multi.run(:version_check, fn _repo, _ -> check_version(stream_id, expected_version) end)
    |> Multi.run(:events, fn _repo, %{version_check: current_version} ->
      insert_events(stream_id, events, current_version)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{events: stored}} -> {:ok, stored}
      {:error, :version_check, reason, _} -> {:error, reason}
      {:error, _step, changeset, _} -> {:error, changeset}
    end
  end

  @doc """
  Reads events from `stream_id` in append order.
  Optionally starts from a specific version and limits the result count.
  """
  @spec read_stream(stream_id(), read_opts()) :: [StoredEvent.t()]
  def read_stream(stream_id, opts \\ []) when is_binary(stream_id) do
    from_version = Keyword.get(opts, :from_version, 0)
    limit = Keyword.get(opts, :limit, 1000)

    from(e in StoredEvent,
      where: e.stream_id == ^stream_id and e.stream_version >= ^from_version,
      order_by: [asc: e.stream_version],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc "Returns the current version (event count) of a stream, or 0 if it does not exist."
  @spec stream_version(stream_id()) :: version()
  def stream_version(stream_id) when is_binary(stream_id) do
    from(e in StoredEvent,
      where: e.stream_id == ^stream_id,
      select: max(e.stream_version)
    )
    |> Repo.one()
    |> Kernel.||(0)
  end

  defp check_version(_stream_id, :any), do: {:ok, nil}

  defp check_version(stream_id, :no_stream) do
    case stream_version(stream_id) do
      0 -> {:ok, 0}
      _ -> {:error, :wrong_expected_version}
    end
  end

  defp check_version(stream_id, expected) when is_integer(expected) do
    current = stream_version(stream_id)
    if current == expected, do: {:ok, current}, else: {:error, :wrong_expected_version}
  end

  defp insert_events(stream_id, events, current_version) do
    base_version = current_version || 0

    stored =
      events
      |> Enum.with_index(base_version + 1)
      |> Enum.map(fn {{event_type, data}, version} ->
        %StoredEvent{}
        |> StoredEvent.changeset(%{
          stream_id: stream_id,
          event_type: event_type,
          data: data,
          stream_version: version,
          occurred_at: DateTime.utc_now()
        })
        |> Repo.insert!()
      end)

    {:ok, stored}
  end
end
```
