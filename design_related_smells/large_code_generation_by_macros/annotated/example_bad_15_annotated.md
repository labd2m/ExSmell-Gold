# Annotated Example 15 — Large Code Generation by Macros

## Metadata

- **Smell name:** Large code generation by macros
- **Expected smell location:** `defmacro defcache/2` inside `Caching.CacheDSL`
- **Affected function(s):** `defcache/2`
- **Short explanation:** The macro inlines a full block of TTL range checks, cache backend validation, key-prefix format checks, compression flag validation, and module-attribute writes on every call. Each declaration expands and compiles this entire body separately rather than calling a single helper function that is compiled once.

---

```elixir
defmodule Caching.CacheDSL do
  @moduledoc """
  Compile-time DSL for declaring named cache policies.

  Each cache policy describes how a resource should be cached: which
  backend to use, the TTL, key prefix conventions, optional compression,
  and eviction hints. Policies are validated and registered at compile time.
  """

  @valid_backends   [:redis, :ets, :memcached, :in_memory]
  @valid_evictions  [:lru, :lfu, :ttl_only, :none]

  # VALIDATION: SMELL START - Large code generation by macros
  # VALIDATION: This is a smell because defcache/2 inlines all validation—
  # VALIDATION: backend type, TTL bounds, prefix format, namespace,
  # VALIDATION: compression flag, max-size, and eviction policy—in the
  # VALIDATION: quoted block. Every cache policy declaration causes the
  # VALIDATION: compiler to expand and compile this large body again, instead
  # VALIDATION: of delegating to a helper function compiled only once.
  defmacro defcache(cache_name, opts) do
    quote do
      cache = unquote(cache_name)
      opts  = unquote(opts)

      unless is_atom(cache) do
        raise ArgumentError,
              "cache name must be an atom, got: #{inspect(cache)}"
      end

      backend = Keyword.get(opts, :backend, :redis)

      unless backend in unquote(@valid_backends) do
        raise ArgumentError,
              "cache #{inspect(cache)} :backend must be one of #{inspect(unquote(@valid_backends))}"
      end

      ttl_seconds = Keyword.fetch!(opts, :ttl_seconds)

      unless is_integer(ttl_seconds) and ttl_seconds > 0 do
        raise ArgumentError,
              "cache #{inspect(cache)} :ttl_seconds must be a positive integer"
      end

      unless ttl_seconds <= 86_400 * 30 do
        raise ArgumentError,
              "cache #{inspect(cache)} :ttl_seconds must be <= 30 days (#{86_400 * 30}s)"
      end

      prefix = Keyword.fetch!(opts, :prefix)

      unless is_binary(prefix) and byte_size(prefix) > 0 do
        raise ArgumentError,
              "cache #{inspect(cache)} :prefix must be a non-empty binary"
      end

      unless String.match?(prefix, ~r/\A[a-z][a-z0-9_]*\z/) do
        raise ArgumentError,
              "cache #{inspect(cache)} :prefix '#{prefix}' must be lowercase alphanumeric with underscores"
      end

      namespace = Keyword.get(opts, :namespace, :global)

      unless is_atom(namespace) do
        raise ArgumentError,
              "cache #{inspect(cache)} :namespace must be an atom"
      end

      compress = Keyword.get(opts, :compress, false)

      unless is_boolean(compress) do
        raise ArgumentError,
              "cache #{inspect(cache)} :compress must be a boolean"
      end

      max_entries = Keyword.get(opts, :max_entries)

      if max_entries != nil do
        unless is_integer(max_entries) and max_entries > 0 do
          raise ArgumentError,
                "cache #{inspect(cache)} :max_entries must be a positive integer"
        end
      end

      eviction = Keyword.get(opts, :eviction, :lru)

      unless eviction in unquote(@valid_evictions) do
        raise ArgumentError,
              "cache #{inspect(cache)} :eviction must be one of #{inspect(unquote(@valid_evictions))}"
      end

      @cache_policies %{
        name:        cache,
        backend:     backend,
        ttl_seconds: ttl_seconds,
        prefix:      prefix,
        namespace:   namespace,
        compress:    compress,
        max_entries: max_entries,
        eviction:    eviction
      }
    end
  end
  # VALIDATION: SMELL END

  defmacro __using__(_) do
    quote do
      import Caching.CacheDSL, only: [defcache: 2]
      Module.register_attribute(__MODULE__, :cache_policies, accumulate: true)
      @before_compile Caching.CacheDSL
    end
  end

  defmacro __before_compile__(env) do
    policies = Module.get_attribute(env.module, :cache_policies)

    quote do
      def cache_policies, do: unquote(Macro.escape(policies))

      def cache_policy(name) do
        Enum.find(cache_policies(), &(&1.name == name))
      end

      def caches_on_backend(backend) do
        Enum.filter(cache_policies(), &(&1.backend == backend))
      end
    end
  end
end

defmodule Caching.AppCaches do
  use Caching.CacheDSL

  defcache(:user_session,
    backend: :redis,
    ttl_seconds: 1_800,
    prefix: "session",
    namespace: :auth,
    compress: false,
    eviction: :ttl_only
  )

  defcache(:product_catalog,
    backend: :redis,
    ttl_seconds: 3_600,
    prefix: "catalog",
    namespace: :store,
    compress: true,
    max_entries: 50_000,
    eviction: :lru
  )

  defcache(:invoice_pdf,
    backend: :redis,
    ttl_seconds: 86_400,
    prefix: "invoice_pdf",
    namespace: :billing,
    compress: true,
    eviction: :ttl_only
  )

  defcache(:exchange_rates,
    backend: :ets,
    ttl_seconds: 300,
    prefix: "fx_rates",
    namespace: :finance,
    compress: false,
    eviction: :ttl_only
  )

  defcache(:user_permissions,
    backend: :ets,
    ttl_seconds: 60,
    prefix: "user_perms",
    namespace: :auth,
    compress: false,
    max_entries: 10_000,
    eviction: :lru
  )

  defcache(:report_results,
    backend: :redis,
    ttl_seconds: 21_600,
    prefix: "report_result",
    namespace: :reporting,
    compress: true,
    eviction: :lfu
  )

  defcache(:geo_lookup,
    backend: :in_memory,
    ttl_seconds: 604_800,
    prefix: "geo",
    namespace: :global,
    compress: false,
    max_entries: 5_000,
    eviction: :lru
  )
end
```
