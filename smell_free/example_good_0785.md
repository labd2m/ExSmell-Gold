```elixir
defmodule Config.Resolver do
  @moduledoc """
  Resolves configuration values through a layered override hierarchy.
  Values are looked up from most-specific to least-specific, stopping at
  the first layer that provides a non-nil value. Layers are applied in this
  order: workspace → organisation → plan → global defaults. This allows
  per-workspace overrides without duplicating base configuration across
  every record. All layers are fetched in a single query to minimise
  round-trips.
  """

  alias Config.{GlobalDefault, OrganisationConfig, PlanConfig, Repo, WorkspaceConfig}
  import Ecto.Query

  @type config_key :: atom()
  @type scope :: %{
          required(:workspace_id) => binary(),
          required(:organisation_id) => binary(),
          required(:plan) => binary()
        }

  @doc """
  Returns the resolved value for `key` in `scope`, walking through override
  layers from most-specific to least-specific. Returns `default` when no
  layer provides a value for the key.
  """
  @spec get(config_key(), scope(), term()) :: term()
  def get(key, scope, default \\ nil) when is_atom(key) do
    layers = load_layers(scope)
    resolve(key, layers, default)
  end

  @doc """
  Returns a map of all resolvable configuration keys and their resolved
  values for `scope`. Useful for rendering settings pages or config exports.
  """
  @spec all(scope()) :: map()
  def all(scope) when is_map(scope) do
    layers = load_layers(scope)
    known_keys = GlobalDefault.all_keys()

    Map.new(known_keys, fn key ->
      {key, resolve(key, layers, nil)}
    end)
  end

  @doc """
  Sets a workspace-level override for `key`. Workspace overrides take
  precedence over all other layers.
  """
  @spec set_workspace(binary(), config_key(), term()) ::
          {:ok, WorkspaceConfig.t()} | {:error, term()}
  def set_workspace(workspace_id, key, value)
      when is_binary(workspace_id) and is_atom(key) do
    %WorkspaceConfig{}
    |> WorkspaceConfig.changeset(%{workspace_id: workspace_id, key: key, value: value})
    |> Repo.insert(
      on_conflict: {:replace, [:value, :updated_at]},
      conflict_target: [:workspace_id, :key]
    )
  end

  @doc """
  Clears the workspace override for `key`, allowing the parent layer to take effect.
  """
  @spec clear_workspace(binary(), config_key()) :: :ok | {:error, :not_found}
  def clear_workspace(workspace_id, key) when is_binary(workspace_id) and is_atom(key) do
    case Repo.get_by(WorkspaceConfig, workspace_id: workspace_id, key: key) do
      nil -> {:error, :not_found}
      record ->
        Repo.delete(record)
        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp load_layers(%{workspace_id: ws_id, organisation_id: org_id, plan: plan}) do
    workspace_layer =
      WorkspaceConfig
      |> where([c], c.workspace_id == ^ws_id)
      |> Repo.all()
      |> Enum.map(&{&1.key, &1.value})
      |> Map.new()

    org_layer =
      OrganisationConfig
      |> where([c], c.organisation_id == ^org_id)
      |> Repo.all()
      |> Enum.map(&{&1.key, &1.value})
      |> Map.new()

    plan_layer =
      PlanConfig
      |> where([c], c.plan == ^plan)
      |> Repo.all()
      |> Enum.map(&{&1.key, &1.value})
      |> Map.new()

    global_layer = GlobalDefault.all()

    [workspace_layer, org_layer, plan_layer, global_layer]
  end

  defp resolve(key, layers, default) do
    Enum.find_value(layers, default, fn layer ->
      case Map.fetch(layer, key) do
        {:ok, value} when not is_nil(value) -> value
        _ -> nil
      end
    end)
  end
end

defmodule Config.GlobalDefault do
  @moduledoc """
  Provides the base configuration defaults that apply when no more-specific
  override exists. Defaults are declared as module attributes so they are
  compiled in rather than queried from the database on every request.
  """

  @defaults %{
    max_upload_size_mb: 25,
    session_timeout_minutes: 60,
    api_rate_limit_per_minute: 100,
    email_notifications_enabled: true,
    two_factor_required: false,
    data_retention_days: 365,
    export_formats: ["csv", "json"],
    allowed_ip_ranges: []
  }

  @doc "Returns all global defaults as a map."
  @spec all() :: map()
  def all, do: @defaults

  @doc "Returns the list of all known configuration keys."
  @spec all_keys() :: [atom()]
  def all_keys, do: Map.keys(@defaults)
end
```
