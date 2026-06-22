```elixir
defmodule Compliance.AuditLogger do
  @moduledoc """
  Provides structured audit logging for compliance-sensitive operations.

  Log entries are written asynchronously to an Ecto-backed audit table
  via a supervised task, keeping the logging call non-blocking for
  callers in hot paths.

  All entry fields are explicitly typed and validated at the boundary;
  no raw maps are forwarded downstream.
  """

  alias Compliance.AuditEntry
  alias Compliance.Repo

  @type actor_id :: String.t()
  @type resource_type :: atom()
  @type resource_id :: String.t()
  @type action :: :create | :update | :delete | :view | :export
  @type outcome :: :success | :failure
  @type metadata :: map()

  @type log_params :: %{
          required(:actor_id) => actor_id(),
          required(:resource_type) => resource_type(),
          required(:resource_id) => resource_id(),
          required(:action) => action(),
          required(:outcome) => outcome(),
          optional(:metadata) => metadata()
        }

  @doc """
  Asynchronously records an audit event.

  The write is fire-and-forget from the caller's perspective.
  Failures are logged but do not propagate to the caller.
  """
  @spec log(log_params()) :: :ok
  def log(
        %{
          actor_id: actor_id,
          resource_type: resource_type,
          resource_id: resource_id,
          action: action,
          outcome: outcome
        } = params
      )
      when is_binary(actor_id) and is_atom(resource_type) and is_binary(resource_id) and
             action in [:create, :update, :delete, :view, :export] and
             outcome in [:success, :failure] do
    metadata = Map.get(params, :metadata, %{})
    entry_params = build_entry_params(actor_id, resource_type, resource_id, action, outcome, metadata)

    Task.Supervisor.start_child(Compliance.TaskSupervisor, fn ->
      persist_entry(entry_params)
    end)

    :ok
  end

  @doc """
  Retrieves paginated audit entries for a specific resource.
  """
  @spec entries_for_resource(resource_type(), resource_id(), keyword()) :: [AuditEntry.t()]
  def entries_for_resource(resource_type, resource_id, opts \\ [])
      when is_atom(resource_type) and is_binary(resource_id) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)

    AuditEntry
    |> Ecto.Query.where([e], e.resource_type == ^resource_type and e.resource_id == ^resource_id)
    |> Ecto.Query.order_by([e], desc: e.occurred_at)
    |> Ecto.Query.limit(^limit)
    |> Ecto.Query.offset(^offset)
    |> Repo.all()
  end

  @doc """
  Retrieves paginated audit entries for a given actor.
  """
  @spec entries_for_actor(actor_id(), keyword()) :: [AuditEntry.t()]
  def entries_for_actor(actor_id, opts \\ []) when is_binary(actor_id) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)

    AuditEntry
    |> Ecto.Query.where([e], e.actor_id == ^actor_id)
    |> Ecto.Query.order_by([e], desc: e.occurred_at)
    |> Ecto.Query.limit(^limit)
    |> Ecto.Query.offset(^offset)
    |> Repo.all()
  end

  @spec build_entry_params(
          actor_id(),
          resource_type(),
          resource_id(),
          action(),
          outcome(),
          metadata()
        ) :: map()
  defp build_entry_params(actor_id, resource_type, resource_id, action, outcome, metadata) do
    %{
      actor_id: actor_id,
      resource_type: resource_type,
      resource_id: resource_id,
      action: action,
      outcome: outcome,
      metadata: metadata,
      occurred_at: DateTime.utc_now()
    }
  end

  @spec persist_entry(map()) :: :ok
  defp persist_entry(params) do
    case Repo.insert(AuditEntry.changeset(%AuditEntry{}, params)) do
      {:ok, _entry} ->
        :ok

      {:error, changeset} ->
        require Logger
        Logger.error("Audit log write failed: #{inspect(changeset.errors)}")
        :ok
    end
  end
end
```
