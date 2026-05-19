# Annotated Example — GenServer Envy

- **Smell name:** GenServer Envy
- **Expected smell location:** `CacheWarmerTask` — `Task` acting as a persistent cache management process
- **Affected function(s):** `start_warmer/1`, `warmer_loop/1`
- **Short explanation:** This `Task` maintains a cache, receives invalidation and refresh requests, responds to queries, and coordinates background warming — a full server lifecycle implemented inside a `Task`, which should only execute a single async operation.

```elixir
defmodule MyApp.CacheWarmerTask do
  @moduledoc """
  Proactively warms and manages an in-memory cache for expensive
  database queries (e.g. product catalogue, pricing tables).
  """

  alias MyApp.{Repo, MetricsCollector}
  alias MyApp.Catalogue.{Product, PriceTable}

  @warm_interval_ms 300_000
  @stale_after_ms 600_000

  def start_warmer(config) do
    # VALIDATION: SMELL START - GenServer Envy
    # VALIDATION: This is a smell because the Task is used to build a long-lived
    # cache management server: it receives get/invalidate/force-refresh commands,
    # maintains state (cache map + TTL metadata), sends replies, and schedules
    # periodic background operations. This pattern — stateful server with client
    # request handling — is precisely what GenServer provides. A Task should
    # handle only a single isolated computation.
    Task.start_link(fn ->
      state = %{
        config: config,
        cache: %{},
        last_warmed: %{},
        hits: 0,
        misses: 0
      }

      send(self(), :warm_all)
      warmer_loop(state)
    end)
  end

  defp warmer_loop(state) do
    receive do
      :warm_all ->
        new_cache = warm_catalogue(state.config)
        now = DateTime.utc_now()

        last_warmed =
          new_cache
          |> Map.keys()
          |> Enum.into(%{}, &{&1, now})

        MetricsCollector.gauge(:cache_size, map_size(new_cache))
        Process.send_after(self(), :warm_all, @warm_interval_ms)
        warmer_loop(%{state | cache: new_cache, last_warmed: last_warmed})

      {:get, from, key} ->
        case Map.fetch(state.cache, key) do
          {:ok, value} ->
            age_ms =
              state.last_warmed
              |> Map.get(key, DateTime.utc_now())
              |> then(&DateTime.diff(DateTime.utc_now(), &1, :millisecond))

            if age_ms > @stale_after_ms do
              fresh = fetch_one(key, state.config)
              now = DateTime.utc_now()
              send(from, {:ok, fresh})

              new_state = %{
                state
                | cache: Map.put(state.cache, key, fresh),
                  last_warmed: Map.put(state.last_warmed, key, now),
                  hits: state.hits + 1
              }

              warmer_loop(new_state)
            else
              send(from, {:ok, value})
              warmer_loop(%{state | hits: state.hits + 1})
            end

          :error ->
            fresh = fetch_one(key, state.config)
            now = DateTime.utc_now()
            send(from, {:ok, fresh})

            new_state = %{
              state
              | cache: Map.put(state.cache, key, fresh),
                last_warmed: Map.put(state.last_warmed, key, now),
                misses: state.misses + 1
            }

            warmer_loop(new_state)
        end

      {:invalidate, from, key} ->
        new_cache = Map.delete(state.cache, key)
        new_warmed = Map.delete(state.last_warmed, key)
        send(from, :ok)
        warmer_loop(%{state | cache: new_cache, last_warmed: new_warmed})

      {:invalidate_all, from} ->
        send(from, :ok)
        warmer_loop(%{state | cache: %{}, last_warmed: %{}})

      {:stats, from} ->
        send(from, {:ok, %{hits: state.hits, misses: state.misses, size: map_size(state.cache)}})
        warmer_loop(state)

      :stop ->
        :ok
    end
  end

  # VALIDATION: SMELL END

  defp warm_catalogue(config) do
    products = Repo.all(Product)
    prices = Repo.all(PriceTable)

    product_map = Enum.into(products, %{}, &{&1.sku, &1})
    price_map = Enum.into(prices, %{}, &{{&1.sku, &1.tier}, &1})

    if config.include_prices do
      Map.merge(product_map, price_map)
    else
      product_map
    end
  end

  defp fetch_one(key, config) do
    cond do
      is_binary(key) -> Repo.get(Product, key)
      is_tuple(key) -> Repo.get(PriceTable, key)
      true -> nil
    end
  end

  def get(pid, key) do
    send(pid, {:get, self(), key})

    receive do
      {:ok, value} -> {:ok, value}
    after
      5_000 -> {:error, :timeout}
    end
  end

  def invalidate(pid, key) do
    send(pid, {:invalidate, self(), key})

    receive do
      :ok -> :ok
    after
      2_000 -> {:error, :timeout}
    end
  end

  def stats(pid) do
    send(pid, {:stats, self()})

    receive do
      {:ok, s} -> {:ok, s}
    after
      2_000 -> {:error, :timeout}
    end
  end
end
```
