# File: `example_good_902.md`

```elixir
defmodule Network.DnsCache do
  @moduledoc """
  GenServer providing TTL-aware DNS resolution caching for outbound
  service connections.

  Resolved addresses are cached for the duration of the record's TTL.
  A fallback resolver function is injected so the cache is testable
  without live DNS queries. Stale entries are evicted on a periodic
  sweep to prevent unbounded growth.
  """

  use GenServer

  require Logger

  @sweep_interval_ms 60_000
  @default_ttl_seconds 300
  @default_resolver &:inet.getaddr(&1, :inet)

  @type hostname :: charlist() | String.t()
  @type ip_address :: :inet.ip_address()

  @type cache_entry :: %{
          addresses: [ip_address()],
          expires_at: integer(),
          resolved_at: integer()
        }

  @type resolver_fn :: (hostname() -> {:ok, ip_address()} | {:error, term()})

  @type opts :: [
          resolver: resolver_fn(),
          default_ttl_seconds: pos_integer()
        ]

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Resolves `hostname` to its IP addresses, returning a cached result
  when available and not expired.

  Returns `{:ok, [ip_address]}` or `{:error, reason}`.
  """
  @spec resolve(hostname()) :: {:ok, [ip_address()]} | {:error, term()}
  def resolve(hostname) when is_binary(hostname) or is_list(hostname) do
    GenServer.call(__MODULE__, {:resolve, normalize_hostname(hostname)})
  end

  @doc """
  Pre-warms the cache for a list of hostnames by resolving them eagerly.

  Errors for individual hostnames are logged but do not abort the batch.
  Returns `{:ok, resolved_count}`.
  """
  @spec prewarm([hostname()]) :: {:ok, non_neg_integer()}
  def prewarm(hostnames) when is_list(hostnames) do
    count =
      Enum.reduce(hostnames, 0, fn hostname, acc ->
        case resolve(hostname) do
          {:ok, _} -> acc + 1
          {:error, reason} ->
            Logger.warning("DnsCache prewarm failed for #{hostname}: #{inspect(reason)}")
            acc
        end
      end)

    {:ok, count}
  end

  @doc """
  Invalidates the cached entry for `hostname`, forcing re-resolution
  on the next call.
  """
  @spec invalidate(hostname()) :: :ok
  def invalidate(hostname) do
    GenServer.cast(__MODULE__, {:invalidate, normalize_hostname(hostname)})
  end

  @doc """
  Returns the number of entries currently in the cache.
  """
  @spec size() :: non_neg_integer()
  def size do
    GenServer.call(__MODULE__, :size)
  end

  @impl GenServer
  def init(opts) do
    resolver = Keyword.get(opts, :resolver, @default_resolver)
    default_ttl = Keyword.get(opts, :default_ttl_seconds, @default_ttl_seconds)
    schedule_sweep()
    {:ok, %{cache: %{}, resolver: resolver, default_ttl_seconds: default_ttl}}
  end

  @impl GenServer
  def handle_call({:resolve, hostname}, _from, state) do
    now = System.system_time(:second)

    case Map.get(state.cache, hostname) do
      %{addresses: addresses, expires_at: exp} when exp > now ->
        {:reply, {:ok, addresses}, state}

      _stale_or_missing ->
        case do_resolve(hostname, state.resolver) do
          {:ok, addresses} ->
            expires_at = now + state.default_ttl_seconds
            entry = %{addresses: addresses, expires_at: expires_at, resolved_at: now}
            new_state = put_in(state, [:cache, hostname], entry)
            {:reply, {:ok, addresses}, new_state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl GenServer
  def handle_call(:size, _from, state) do
    {:reply, map_size(state.cache), state}
  end

  @impl GenServer
  def handle_cast({:invalidate, hostname}, state) do
    {:noreply, update_in(state, [:cache], &Map.delete(&1, hostname))}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    now = System.system_time(:second)
    live = Map.reject(state.cache, fn {_host, entry} -> entry.expires_at <= now end)
    schedule_sweep()
    {:noreply, %{state | cache: live}}
  end

  defp do_resolve(hostname, resolver) do
    host_charlist = if is_binary(hostname), do: String.to_charlist(hostname), else: hostname

    case resolver.(host_charlist) do
      {:ok, address} -> {:ok, [address]}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_hostname(hostname) when is_list(hostname), do: List.to_string(hostname)
  defp normalize_hostname(hostname) when is_binary(hostname), do: hostname

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end
end
```
