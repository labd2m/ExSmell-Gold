```elixir
defmodule Saas.Tenants.QuotaEnforcer do
  @moduledoc """
  Enforces resource usage quotas per tenant.
  Quota consumption is tracked in-process and validated before each resource operation.
  Quotas are configured per tenant at registration time.
  """

  use GenServer

  @type tenant_id :: String.t()
  @type resource :: :api_calls | :storage_mb | :active_users | :exports
  @type quota_config :: %{resource() => pos_integer()}
  @type usage :: %{resource() => non_neg_integer()}
  @type tenant_record :: %{quota: quota_config(), usage: usage()}
  @type state :: %{tenants: %{tenant_id() => tenant_record()}}

  @doc """
  Starts the QuotaEnforcer linked to the calling process.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Registers a tenant with its quota configuration.
  Returns `{:error, :already_registered}` if the tenant exists.
  """
  @spec register(tenant_id(), quota_config()) ::
          :ok | {:error, :already_registered | String.t()}
  def register(tenant_id, quota) when is_binary(tenant_id) and is_map(quota) do
    case validate_quota(quota) do
      :ok -> GenServer.call(__MODULE__, {:register, tenant_id, quota})
      {:error, _} = err -> err
    end
  end

  @doc """
  Checks whether `tenant_id` may consume `amount` units of `resource`.
  Returns `:ok` or `{:error, :quota_exceeded}`.
  """
  @spec check(tenant_id(), resource(), pos_integer()) ::
          :ok | {:error, :quota_exceeded | :not_found}
  def check(tenant_id, resource, amount)
      when is_binary(tenant_id) and is_atom(resource) and is_integer(amount) and amount > 0 do
    GenServer.call(__MODULE__, {:check, tenant_id, resource, amount})
  end

  @doc """
  Records consumption of `amount` units of `resource` for `tenant_id`.
  Does not enforce limits; call `check/3` first when enforcement is required.
  """
  @spec consume(tenant_id(), resource(), pos_integer()) :: :ok | {:error, :not_found}
  def consume(tenant_id, resource, amount)
      when is_binary(tenant_id) and is_atom(resource) and is_integer(amount) and amount > 0 do
    GenServer.call(__MODULE__, {:consume, tenant_id, resource, amount})
  end

  @doc """
  Returns current usage and quota for a tenant.
  """
  @spec report(tenant_id()) :: {:ok, tenant_record()} | {:error, :not_found}
  def report(tenant_id) when is_binary(tenant_id) do
    GenServer.call(__MODULE__, {:report, tenant_id})
  end

  @impl GenServer
  def init(_opts), do: {:ok, %{tenants: %{}}}

  @impl GenServer
  def handle_call({:register, tenant_id, quota}, _from, state) do
    if Map.has_key?(state.tenants, tenant_id) do
      {:reply, {:error, :already_registered}, state}
    else
      record = %{quota: quota, usage: Map.new(Map.keys(quota), fn r -> {r, 0} end)}
      {:reply, :ok, %{state | tenants: Map.put(state.tenants, tenant_id, record)}}
    end
  end

  @impl GenServer
  def handle_call({:check, tenant_id, resource, amount}, _from, state) do
    case Map.fetch(state.tenants, tenant_id) do
      :error ->
        {:reply, {:error, :not_found}, state}

      {:ok, record} ->
        current = Map.get(record.usage, resource, 0)
        limit = Map.get(record.quota, resource, 0)
        reply = if current + amount <= limit, do: :ok, else: {:error, :quota_exceeded}
        {:reply, reply, state}
    end
  end

  @impl GenServer
  def handle_call({:consume, tenant_id, resource, amount}, _from, state) do
    case Map.fetch(state.tenants, tenant_id) do
      :error ->
        {:reply, {:error, :not_found}, state}

      {:ok, record} ->
        new_usage = Map.update(record.usage, resource, amount, fn u -> u + amount end)
        updated = %{record | usage: new_usage}
        {:reply, :ok, %{state | tenants: Map.put(state.tenants, tenant_id, updated)}}
    end
  end

  @impl GenServer
  def handle_call({:report, tenant_id}, _from, state) do
    case Map.fetch(state.tenants, tenant_id) do
      {:ok, record} -> {:reply, {:ok, record}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  defp validate_quota(quota) do
    invalid = Enum.find(quota, fn {_k, v} -> not (is_integer(v) and v > 0) end)

    if is_nil(invalid) do
      :ok
    else
      {:error, "all quota values must be positive integers"}
    end
  end
end
```
