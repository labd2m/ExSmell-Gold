```elixir
defmodule Compliance.AuditTrail do
  @moduledoc """
  Append-only audit trail for compliance-sensitive operations.
  Records are immutable once written and queryable by actor, resource, or time range.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query, only: [from: 2, where: 3, order_by: 3, limit: 3]

  alias Compliance.{AuditTrail, Repo}

  @type t :: %__MODULE__{
    id: Ecto.UUID.t(),
    actor_id: String.t(),
    actor_type: String.t(),
    action: String.t(),
    resource_type: String.t(),
    resource_id: String.t(),
    metadata: map(),
    occurred_at: DateTime.t()
  }

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "audit_trail" do
    field :actor_id, :string
    field :actor_type, :string
    field :action, :string
    field :resource_type, :string
    field :resource_id, :string
    field :metadata, :map, default: %{}
    field :occurred_at, :utc_datetime_usec
  end

  @spec record(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def record(params) when is_map(params) do
    params
    |> Map.put_new(:occurred_at, DateTime.utc_now())
    |> creation_changeset()
    |> Repo.insert()
  end

  @spec query_by_actor(String.t(), keyword()) :: [t()]
  def query_by_actor(actor_id, opts \\ []) when is_binary(actor_id) do
    from(a in AuditTrail)
    |> where([a], a.actor_id == ^actor_id)
    |> apply_time_range(opts)
    |> apply_limit(opts)
    |> order_by([a], desc: a.occurred_at)
    |> Repo.all()
  end

  @spec query_by_resource(String.t(), String.t(), keyword()) :: [t()]
  def query_by_resource(resource_type, resource_id, opts \\ [])
      when is_binary(resource_type) and is_binary(resource_id) do
    from(a in AuditTrail)
    |> where([a], a.resource_type == ^resource_type and a.resource_id == ^resource_id)
    |> apply_time_range(opts)
    |> apply_limit(opts)
    |> order_by([a], desc: a.occurred_at)
    |> Repo.all()
  end

  @spec query_by_action(String.t(), keyword()) :: [t()]
  def query_by_action(action, opts \\ []) when is_binary(action) do
    from(a in AuditTrail)
    |> where([a], a.action == ^action)
    |> apply_time_range(opts)
    |> apply_limit(opts)
    |> order_by([a], desc: a.occurred_at)
    |> Repo.all()
  end

  @spec creation_changeset(map()) :: Ecto.Changeset.t()
  defp creation_changeset(params) do
    %__MODULE__{}
    |> cast(params, [:actor_id, :actor_type, :action, :resource_type, :resource_id, :metadata, :occurred_at])
    |> validate_required([:actor_id, :actor_type, :action, :resource_type, :resource_id, :occurred_at])
    |> validate_length(:action, min: 1, max: 100)
    |> validate_length(:resource_type, min: 1, max: 100)
  end

  @spec apply_time_range(Ecto.Query.t(), keyword()) :: Ecto.Query.t()
  defp apply_time_range(query, opts) do
    query
    |> apply_since(Keyword.get(opts, :since))
    |> apply_until(Keyword.get(opts, :until))
  end

  @spec apply_since(Ecto.Query.t(), DateTime.t() | nil) :: Ecto.Query.t()
  defp apply_since(query, nil), do: query
  defp apply_since(query, since), do: where(query, [a], a.occurred_at >= ^since)

  @spec apply_until(Ecto.Query.t(), DateTime.t() | nil) :: Ecto.Query.t()
  defp apply_until(query, nil), do: query
  defp apply_until(query, until), do: where(query, [a], a.occurred_at <= ^until)

  @spec apply_limit(Ecto.Query.t(), keyword()) :: Ecto.Query.t()
  defp apply_limit(query, opts) do
    case Keyword.get(opts, :limit) do
      nil -> query
      n when is_integer(n) and n > 0 -> limit(query, ^n)
      _ -> query
    end
  end
end
```
