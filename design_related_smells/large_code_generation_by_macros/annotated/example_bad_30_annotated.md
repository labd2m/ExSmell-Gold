# Annotated Example — Bad Code

## Metadata

- **Smell name:** Large code generation by macros
- **Expected smell location:** `defmacro cached/3` inside `MyApp.Cache.FunctionDSL`
- **Affected function(s):** `cached/3` macro
- **Short explanation:** Every use of `cached/3` expands a large `quote` block inline: it validates the cache name, TTL, serialiser, eviction strategy, and tag list, then generates a wrapper function. All of this code is duplicated at every call site instead of being delegated to a shared `__define__` function, causing unnecessary bytecode bloat and slower compilation.

---

```elixir
defmodule MyApp.Cache.FunctionDSL do
  @moduledoc """
  DSL for wrapping functions with automatic caching behaviour.

  Example:

      defmodule MyApp.Catalogue.ProductService do
        use MyApp.Cache.FunctionDSL, store: MyApp.Cache.RedisStore

        cached :fetch_product, ttl: 300, tags: [:products] do
          fn id ->
            MyApp.Repo.get!(MyApp.Product, id)
          end
        end

        cached :list_categories, ttl: 600, tags: [:categories, :products] do
          fn ->
            MyApp.Repo.all(MyApp.Category)
          end
        end
      end
  """

  defmacro __using__(opts) do
    store = Keyword.get(opts, :store, MyApp.Cache.ETSStore)

    quote do
      import MyApp.Cache.FunctionDSL, only: [cached: 3]
      Module.register_attribute(__MODULE__, :cache_entries, accumulate: true)
      @cache_store unquote(store)
      @before_compile MyApp.Cache.FunctionDSL
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      def cache_entries, do: @cache_entries
      def cache_store,   do: @cache_store
    end
  end

  # VALIDATION: SMELL START - Large code generation by macros
  # VALIDATION: This is a smell because every call to cached/3 expands the
  # VALIDATION: entire validation pipeline inline: name atom check, TTL integer
  # VALIDATION: check, tags list check, eviction strategy check, serialiser
  # VALIDATION: module check, deduplication guard, entry struct construction,
  # VALIDATION: and the full wrapper-function definition. A module with many
  # VALIDATION: cached functions compiles all of this code at each call site
  # VALIDATION: rather than delegating to a shared helper.
  defmacro cached(name, opts, do: body) do
    quote do
      name = unquote(name)
      opts = unquote(opts)

      unless is_atom(name) do
        raise ArgumentError,
              "cached/3: function name must be an atom, got #{inspect(name)}"
      end

      ttl = Keyword.get(opts, :ttl, 60)

      unless is_integer(ttl) and ttl > 0 do
        raise ArgumentError,
              "cached/3: :ttl must be a positive integer (seconds), got #{inspect(ttl)}"
      end

      tags = Keyword.get(opts, :tags, [])

      unless is_list(tags) and Enum.all?(tags, &is_atom/1) do
        raise ArgumentError,
              "cached/3: :tags must be a list of atoms, got #{inspect(tags)}"
      end

      valid_evictions = [:lru, :lfu, :ttl_only]
      eviction = Keyword.get(opts, :eviction, :ttl_only)

      unless eviction in valid_evictions do
        raise ArgumentError,
              "cached/3: :eviction must be one of #{inspect(valid_evictions)}, " <>
                "got #{inspect(eviction)}"
      end

      serialiser = Keyword.get(opts, :serialiser, :term)

      unless serialiser in [:term, :json, :msgpack] or is_atom(serialiser) do
        raise ArgumentError,
              "cached/3: :serialiser must be :term, :json, :msgpack, or a module atom, " <>
                "got #{inspect(serialiser)}"
      end

      existing = Module.get_attribute(__MODULE__, :cache_entries)

      if Enum.any?(existing, fn e -> e.name == name end) do
        raise ArgumentError,
              "cached/3: duplicate cache entry #{inspect(name)} in #{inspect(__MODULE__)}"
      end

      entry = %{
        name:       name,
        ttl:        ttl,
        tags:       tags,
        eviction:   eviction,
        serialiser: serialiser
      }

      @cache_entries entry

      def unquote(name)(args) do
        cache_key = {__MODULE__, unquote(name), args}
        store     = @cache_store

        case store.get(cache_key) do
          {:ok, value} ->
            value

          :miss ->
            func   = unquote(body)
            result = apply(func, List.wrap(args))
            store.put(cache_key, result, unquote(ttl))
            result
        end
      end
    end
  end
  # VALIDATION: SMELL END

  @doc """
  Invalidates all cache entries tagged with any of the provided tags
  across the given `cache_module`.
  """
  @spec invalidate_by_tag(module(), [atom()]) :: :ok
  def invalidate_by_tag(cache_module, tags) when is_list(tags) do
    store = cache_module.cache_store()

    cache_module.cache_entries()
    |> Enum.filter(fn entry -> Enum.any?(entry.tags, &(&1 in tags)) end)
    |> Enum.each(fn entry ->
      store.evict_by_prefix({cache_module, entry.name})
    end)
  end
end
```
