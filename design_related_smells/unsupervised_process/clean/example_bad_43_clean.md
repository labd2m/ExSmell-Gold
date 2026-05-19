```elixir
defmodule TenantConfigServer do
  use GenServer

  @moduledoc """
  Holds live configuration for a single tenant including feature flags,
  plan entitlements, custom branding, and integration settings.
  Hot-reloads config from the database when signalled.
  """

  @reload_interval_ms 5 * 60 * 1_000

  defstruct [
    :tenant_id,
    :plan,
    :feature_flags,
    :entitlements,
    :branding,
    :integrations,
    :loaded_at,
    :status
  ]

  def start(%{tenant_id: id} = attrs) do
    GenServer.start(__MODULE__, attrs, name: via(id))
  end

  def get_flag(tenant_id, flag) do
    GenServer.call(via(tenant_id), {:flag, flag})
  end

  def check_limit(tenant_id, resource) do
    GenServer.call(via(tenant_id), {:limit, resource})
  end

  def get_branding(tenant_id) do
    GenServer.call(via(tenant_id), :branding)
  end

  def update_flag(tenant_id, flag, value) do
    GenServer.call(via(tenant_id), {:set_flag, flag, value})
  end

  def reload(tenant_id) do
    GenServer.cast(via(tenant_id), :reload)
  end

  def full_config(tenant_id) do
    GenServer.call(via(tenant_id), :full_config)
  end

  defp via(id), do: {:via, Registry, {TenantConfigRegistry, id}}

  ## Callbacks

  @impl true
  def init(%{tenant_id: id} = attrs) do
    config = fetch_config_from_db(id)

    state = %__MODULE__{
      tenant_id: id,
      plan: Map.get(attrs, :plan, config.plan),
      feature_flags: config.feature_flags,
      entitlements: config.entitlements,
      branding: config.branding,
      integrations: config.integrations,
      loaded_at: DateTime.utc_now(),
      status: :active
    }

    schedule_reload()
    {:ok, state}
  end

  @impl true
  def handle_call({:flag, flag}, _from, state) do
    value = Map.get(state.feature_flags, flag, false)
    {:reply, {:ok, value}, state}
  end

  def handle_call({:limit, resource}, _from, state) do
    limit = get_in(state.entitlements, [state.plan, resource])
    {:reply, {:ok, limit}, state}
  end

  def handle_call(:branding, _from, state) do
    {:reply, {:ok, state.branding}, state}
  end

  def handle_call({:set_flag, flag, value}, _from, state) do
    updated_flags = Map.put(state.feature_flags, flag, value)
    persist_flag_override(state.tenant_id, flag, value)
    {:reply, :ok, %{state | feature_flags: updated_flags}}
  end

  def handle_call(:full_config, _from, state) do
    config = %{
      tenant_id: state.tenant_id,
      plan: state.plan,
      feature_flags: state.feature_flags,
      entitlements: state.entitlements,
      branding: state.branding,
      integrations: state.integrations,
      loaded_at: state.loaded_at
    }

    {:reply, {:ok, config}, state}
  end

  @impl true
  def handle_cast(:reload, state) do
    config = fetch_config_from_db(state.tenant_id)

    updated = %{state |
      feature_flags: config.feature_flags,
      entitlements: config.entitlements,
      branding: config.branding,
      integrations: config.integrations,
      loaded_at: DateTime.utc_now()
    }

    {:noreply, updated}
  end

  @impl true
  def handle_info(:scheduled_reload, state) do
    config = fetch_config_from_db(state.tenant_id)

    updated = %{state |
      feature_flags: config.feature_flags,
      entitlements: config.entitlements,
      loaded_at: DateTime.utc_now()
    }

    schedule_reload()
    {:noreply, updated}
  end

  defp fetch_config_from_db(_tenant_id) do
    %{
      plan: :growth,
      feature_flags: %{advanced_reporting: true, api_access: true, sso: false},
      entitlements: %{
        growth: %{seats: 25, storage_gb: 100, api_calls_per_month: 50_000},
        enterprise: %{seats: :unlimited, storage_gb: 1_000, api_calls_per_month: :unlimited}
      },
      branding: %{primary_color: "#4F46E5", logo_url: nil, custom_domain: nil},
      integrations: %{slack: false, jira: true, github: false}
    }
  end

  defp persist_flag_override(_tenant_id, _flag, _value), do: :ok

  defp schedule_reload do
    Process.send_after(self(), :scheduled_reload, @reload_interval_ms)
  end
end

defmodule TenantBootstrap do
  @moduledoc "Boots per-tenant infrastructure when a tenant becomes active."

  def boot(%{tenant_id: id} = attrs) do
    case TenantConfigServer.start(attrs) do
      {:ok, _pid} ->
        {:ok, id}

      {:error, {:already_started, _pid}} ->
        {:ok, id}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def boot_all(tenant_list) do
    results = Enum.map(tenant_list, &boot/1)

    failed = Enum.filter(results, &match?({:error, _}, &1))

    if Enum.empty?(failed) do
      {:ok, length(tenant_list)}
    else
      {:partial, length(tenant_list) - length(failed), failed}
    end
  end
end
```
