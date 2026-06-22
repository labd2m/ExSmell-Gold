# File: `example_good_820.md`

```elixir
defmodule Auth.PermissionCache do
  @moduledoc """
  ETS-backed cache for resolved permission sets, reducing repeated
  calls to the access control context during high-traffic request handling.

  Entries are cached with a short TTL. The cache is populated on first
  access and invalidated explicitly when a user's roles or permissions change.
  """

  use GenServer

  @table __MODULE__
  @default_ttl_seconds 30
  @sweep_interval_ms 60_000

  @type user_id :: String.t()
  @type permission :: atom()
  @type resource_type :: String.t()
  @type cache_key :: {user_id(), resource_type(), String.t() | nil}

  @type opts :: [ttl_seconds: pos_integer()]

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Checks whether `user_id` has `permission` on the given resource,
  using the cache and falling back to `resolver_fn/0` on a miss.

  `resolver_fn` must return `{:ok, permissions_list}` or `{:error, reason}`.
  """
  @spec permitted?(
          user_id(),
          permission(),
          resource_type(),
          String.t() | nil,
          (-> {:ok, [permission()]} | {:error, term()})
        ) :: {:ok, boolean()} | {:error, term()}
  def permitted?(user_id, permission, resource_type, resource_id \\ nil, resolver_fn)
      when is_binary(user_id) and is_atom(permission) and is_function(resolver_fn, 0) do
    key = {user_id, resource_type, resource_id}

    case lookup(key) do
      {:ok, permissions} ->
        {:ok, permission in permissions}

      :miss ->
        case resolver_fn.() do
          {:ok, permissions} ->
            store(key, permissions)
            {:ok, permission in permissions}

          {:error, _} = error ->
            error
        end
    end
  end

  @doc """
  Fetches the full permission set for a user-resource combination,
  populating the cache on a miss.
  """
  @spec fetch_permissions(user_id(), resource_type(), String.t() | nil,
          (-> {:ok, [permission()]} | {:error, term()})
        ) :: {:ok, [permission()]} | {:error, term()}
  def fetch_permissions(user_id, resource_type, resource_id \\ nil, resolver_fn)
      when is_binary(user_id) and is_function(resolver_fn, 0) do
    key = {user_id, resource_type, resource_id}

    case lookup(key) do
      {:ok, permissions} ->
        {:ok, permissions}

      :miss ->
        case resolver_fn.() do
          {:ok, permissions} ->
            store(key, permissions)
            {:ok, permissions}

          {:error, _} = error ->
            error
        end
    end
  end

  @doc """
  Invalidates all cached entries for `user_id`, forcing re-resolution
  on the next access.
  """
  @spec invalidate_user(user_id()) :: non_neg_integer()
  def invalidate_user(user_id) when is_binary(user_id) do
    GenServer.call(__MODULE__, {:invalidate_user, user_id})
  end

  @doc """
  Returns the current number of entries in the cache.
  """
  @spec size() :: non_neg_integer()
  def size do
    :ets.info(@table, :size)
  end

  @impl GenServer
  def init(opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    ttl_seconds = Keyword.get(opts, :ttl_seconds, @default_ttl_seconds)
    schedule_sweep()
    {:ok, %{ttl_seconds: ttl_seconds}}
  end

  @impl GenServer
  def handle_call({:invalidate_user, user_id}, _from, state) do
    count =
      :ets.tab2list(@table)
      |> Enum.filter(fn {{uid, _rt, _rid}, _v} -> uid == user_id end)
      |> Enum.reduce(0, fn {key, _v}, acc ->
        :ets.delete(@table, key)
        acc + 1
      end)

    {:reply, count, state}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    now = System.system_time(:second)

    :ets.tab2list(@table)
    |> Enum.each(fn {key, {_permissions, expires_at}} ->
      if expires_at < now, do: :ets.delete(@table, key)
    end)

    schedule_sweep()
    {:noreply, state}
  end

  defp lookup(key) do
    now = System.system_time(:second)

    case :ets.lookup(@table, key) do
      [{^key, {permissions, expires_at}}] when expires_at > now ->
        {:ok, permissions}

      [{^key, _expired}] ->
        :ets.delete(@table, key)
        :miss

      [] ->
        :miss
    end
  end

  defp store(key, permissions) do
    ttl_seconds = Application.get_env(:my_app, :permission_cache_ttl, @default_ttl_seconds)
    expires_at = System.system_time(:second) + ttl_seconds
    :ets.insert(@table, {key, {permissions, expires_at}})
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end
end
```
