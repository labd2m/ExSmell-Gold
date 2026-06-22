```elixir
defmodule Replication.EventStore do
  @moduledoc """
  Append-only event store backed by Ecto. Events are partitioned by
  aggregate type and aggregate ID. A global sequence number enables
  deterministic replication consumers to track their position.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query, warn: false

  alias Replication.Repo

  @type t :: %__MODULE__{}

  schema "domain_events" do
    field :sequence, :integer
    field :aggregate_type, :string
    field :aggregate_id, :string
    field :event_type, :string
    field :payload, :map
    field :metadata, :map, default: %{}
    field :occurred_at, :utc_datetime_usec
    timestamps(updated_at: false)
  end

  @spec append(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def append(attrs) when is_map(attrs) do
    attrs
    |> changeset()
    |> Repo.insert()
  end

  @spec stream_from(non_neg_integer(), keyword()) :: list(t())
  def stream_from(after_sequence, opts \\ []) when is_integer(after_sequence) do
    limit = Keyword.get(opts, :limit, 500)
    aggregate_type = Keyword.get(opts, :aggregate_type)

    __MODULE__
    |> where([e], e.sequence > ^after_sequence)
    |> maybe_filter_type(aggregate_type)
    |> order_by([e], asc: e.sequence)
    |> limit(^limit)
    |> Repo.all()
  end

  @spec for_aggregate(String.t(), String.t()) :: list(t())
  def for_aggregate(aggregate_type, aggregate_id)
      when is_binary(aggregate_type) and is_binary(aggregate_id) do
    __MODULE__
    |> where([e], e.aggregate_type == ^aggregate_type and e.aggregate_id == ^aggregate_id)
    |> order_by([e], asc: e.sequence)
    |> Repo.all()
  end

  @spec latest_sequence() :: non_neg_integer()
  def latest_sequence do
    __MODULE__
    |> select([e], max(e.sequence))
    |> Repo.one()
    |> Kernel.||(0)
  end

  @spec count_by_type() :: %{String.t() => integer()}
  def count_by_type do
    __MODULE__
    |> group_by([e], e.event_type)
    |> select([e], {e.event_type, count(e.id)})
    |> Repo.all()
    |> Map.new()
  end

  defp changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:aggregate_type, :aggregate_id, :event_type, :payload, :metadata, :occurred_at])
    |> validate_required([:aggregate_type, :aggregate_id, :event_type, :payload, :occurred_at])
    |> validate_length(:aggregate_type, min: 1, max: 80)
    |> validate_length(:aggregate_id, min: 1, max: 255)
    |> validate_length(:event_type, min: 1, max: 120)
  end

  defp maybe_filter_type(query, nil), do: query
  defp maybe_filter_type(query, type), do: where(query, [e], e.aggregate_type == ^type)
end

defmodule Replication.ConsumerCheckpoint do
  @moduledoc """
  Persists the last processed sequence number for each named consumer.
  Consumers use this to resume after restart without reprocessing events.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Replication.Repo

  @type t :: %__MODULE__{}

  schema "consumer_checkpoints" do
    field :consumer_id, :string
    field :last_sequence, :integer, default: 0
    timestamps()
  end

  @spec save(String.t(), non_neg_integer()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def save(consumer_id, sequence)
      when is_binary(consumer_id) and is_integer(sequence) and sequence >= 0 do
    case Repo.get_by(__MODULE__, consumer_id: consumer_id) do
      nil ->
        %__MODULE__{}
        |> cast(%{consumer_id: consumer_id, last_sequence: sequence}, [:consumer_id, :last_sequence])
        |> validate_required([:consumer_id])
        |> Repo.insert()

      record ->
        record
        |> cast(%{last_sequence: sequence}, [:last_sequence])
        |> Repo.update()
    end
  end

  @spec fetch(String.t()) :: non_neg_integer()
  def fetch(consumer_id) when is_binary(consumer_id) do
    case Repo.get_by(__MODULE__, consumer_id: consumer_id) do
      nil -> 0
      %__MODULE__{last_sequence: seq} -> seq
    end
  end
end
```
