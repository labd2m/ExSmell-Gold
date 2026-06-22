```elixir
defmodule Tenancy.ConfigStore do
  @moduledoc """
  A supervised GenServer that maintains an in-process cache of per-tenant
  runtime configuration. Values are loaded from the database on first access
  and invalidated on explicit update, avoiding repeated database hits for
  high-frequency config reads.
  """

  use GenServer

  alias Tenancy.{Repo, TenantConfig}

  @type tenant_id :: String.t()
  @type config_key :: atom()
  @type config_value :: term()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec get(tenant_id(), config_key()) :: {:ok, config_value()} | {:error, :not_found}
  def get(tenant_id, key) when is_binary(tenant_id) and is_atom(key) do
    GenServer.call(__MODULE__, {:get, tenant_id, key})
  end

  @spec get_all(tenant_id()) :: map()
  def get_all(tenant_id) when is_binary(tenant_id) do
    GenServer.call(__MODULE__, {:get_all, tenant_id})
  end

  @spec set(tenant_id(), config_key(), config_value()) ::
          {:ok, TenantConfig.t()} | {:error, Ecto.Changeset.t()}
  def set(tenant_id, key, value) when is_binary(tenant_id) and is_atom(key) do
    GenServer.call(__MODULE__, {:set, tenant_id, key, value})
  end

  @spec invalidate(tenant_id()) :: :ok
  def invalidate(tenant_id) when is_binary(tenant_id) do
    GenServer.cast(__MODULE__, {:invalidate, tenant_id})
  end

  @impl GenServer
  def init(_opts) do
    {:ok, %{}}
  end

  @impl GenServer
  def handle_call({:get, tenant_id, key}, _from, state) do
    {config, new_state} = ensure_loaded(tenant_id, state)
    result = Map.fetch(config, key)
    reply = case result do
      {:ok, value} -> {:ok, value}
      :error -> {:error, :not_found}
    end
    {:reply, reply, new_state}
  end

  def handle_call({:get_all, tenant_id}, _from, state) do
    {config, new_state} = ensure_loaded(tenant_id, state)
    {:reply, config, new_state}
  end

  def handle_call({:set, tenant_id, key, value}, _from, state) do
    result = persist_config(tenant_id, key, value)

    new_state =
      case result do
        {:ok, _} -> put_in(state, [Access.key(tenant_id, %{}), key], value)
        _ -> state
      end

    {:reply, result, new_state}
  end

  @impl GenServer
  def handle_cast({:invalidate, tenant_id}, state) do
    {:noreply, Map.delete(state, tenant_id)}
  end

  @spec ensure_loaded(tenant_id(), map()) :: {map(), map()}
  defp ensure_loaded(tenant_id, state) do
    case Map.fetch(state, tenant_id) do
      {:ok, config} ->
        {config, state}

      :error ->
        config = load_from_db(tenant_id)
        {config, Map.put(state, tenant_id, config)}
    end
  end

  @spec load_from_db(tenant_id()) :: map()
  defp load_from_db(tenant_id) do
    import Ecto.Query

    from(c in TenantConfig, where: c.tenant_id == ^tenant_id)
    |> Repo.all()
    |> Map.new(fn row -> {String.to_existing_atom(row.key), row.value} end)
  rescue
    _ -> %{}
  end

  @spec persist_config(tenant_id(), config_key(), config_value()) ::
          {:ok, TenantConfig.t()} | {:error, Ecto.Changeset.t()}
  defp persist_config(tenant_id, key, value) do
    existing = Repo.get_by(TenantConfig, tenant_id: tenant_id, key: to_string(key))
    params = %{tenant_id: tenant_id, key: to_string(key), value: value}

    case existing do
      nil -> %TenantConfig{} |> TenantConfig.creation_changeset(params) |> Repo.insert()
      record -> record |> TenantConfig.update_changeset(%{value: value}) |> Repo.update()
    end
  end
end
```
