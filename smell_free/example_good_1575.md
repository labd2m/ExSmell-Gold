```elixir
defmodule EventStore.Event do
  @moduledoc """
  An immutable domain event recorded into the event stream of an aggregate.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          stream_id: String.t(),
          event_type: String.t(),
          data: map(),
          metadata: map(),
          version: pos_integer(),
          occurred_at: DateTime.t()
        }

  defstruct [:id, :stream_id, :event_type, :data, :version, :occurred_at, metadata: %{}]
end

defmodule EventStore.Stream do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias EventStore.Event
  alias MyApp.Repo

  @moduledoc """
  Provides append-only event stream persistence with optimistic concurrency
  control. Callers supply the expected current version to detect conflicts.
  """

  schema "event_store_events" do
    field :stream_id, :string
    field :event_type, :string
    field :data, :map
    field :metadata, :map, default: %{}
    field :version, :integer
    field :occurred_at, :utc_datetime
  end

  @type append_result :: {:ok, [Event.t()]} | {:error, :version_conflict | Ecto.Changeset.t()}

  @spec append(String.t(), [map()], pos_integer()) :: append_result()
  def append(stream_id, event_attrs, expected_version)
      when is_binary(stream_id) and is_list(event_attrs) and is_integer(expected_version) do
    Repo.transaction(fn ->
      current = current_version(stream_id)

      if current != expected_version do
        Repo.rollback(:version_conflict)
      else
        event_attrs
        |> Enum.with_index(expected_version + 1)
        |> Enum.map(fn {attrs, version} -> insert_event(stream_id, attrs, version) end)
        |> collect_results()
      end
    end)
    |> unwrap_transaction()
  end

  @spec read(String.t(), keyword()) :: [Event.t()]
  def read(stream_id, opts \\ []) when is_binary(stream_id) do
    from_version = Keyword.get(opts, :from_version, 1)
    limit = Keyword.get(opts, :limit, 1000)

    __MODULE__
    |> where([e], e.stream_id == ^stream_id and e.version >= ^from_version)
    |> order_by([e], asc: e.version)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.map(&to_event/1)
  end

  defp current_version(stream_id) do
    __MODULE__
    |> where([e], e.stream_id == ^stream_id)
    |> select([e], max(e.version))
    |> Repo.one()
    |> then(fn
      nil -> 0
      version -> version
    end)
  end

  defp insert_event(stream_id, attrs, version) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %__MODULE__{}
    |> cast(
      Map.merge(attrs, %{stream_id: stream_id, version: version, occurred_at: now}),
      [:stream_id, :event_type, :data, :metadata, :version, :occurred_at]
    )
    |> validate_required([:stream_id, :event_type, :data, :version, :occurred_at])
    |> Repo.insert()
  end

  defp collect_results(results) do
    Enum.reduce_while(results, [], fn
      {:ok, row}, acc -> {:cont, acc ++ [to_event(row)]}
      {:error, cs}, _acc -> {:halt, {:error, cs}}
    end)
  end

  defp unwrap_transaction({:ok, {:error, reason}}), do: {:error, reason}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}
  defp unwrap_transaction({:ok, events}), do: {:ok, events}

  defp to_event(row) do
    %Event{
      id: to_string(row.id),
      stream_id: row.stream_id,
      event_type: row.event_type,
      data: row.data,
      metadata: row.metadata,
      version: row.version,
      occurred_at: row.occurred_at
    }
  end
end
```
