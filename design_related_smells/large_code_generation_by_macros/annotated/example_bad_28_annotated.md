# Annotated Example — Bad Code

## Metadata

- **Smell name:** Large code generation by macros
- **Expected smell location:** `defmacro endpoint/3` inside `MyApp.ApiClient.DSL`
- **Affected function(s):** `endpoint/3` macro
- **Short explanation:** Every call to `endpoint/3` expands a large `quote` block that validates the HTTP method, path format, response module, timeout, retry policy, and authentication flag — and also defines a named public function — entirely at the call site. The validation logic and function generation should be split: light `quote` plus delegation to a `__define__` helper.

---

```elixir
defmodule MyApp.ApiClient.DSL do
  @moduledoc """
  DSL for declaring typed HTTP API endpoints on a client module.

  Example:

      defmodule MyApp.ApiClient.BillingService do
        use MyApp.ApiClient.DSL, base_url: "https://billing.internal"

        endpoint :get_invoice,  :get,  "/invoices/:id",
          response: MyApp.Schemas.Invoice,
          timeout_ms: 3_000

        endpoint :create_invoice, :post, "/invoices",
          response: MyApp.Schemas.Invoice,
          timeout_ms: 5_000,
          retry: 2

        endpoint :delete_invoice, :delete, "/invoices/:id",
          timeout_ms: 2_000,
          auth: :service_token
      end
  """

  defmacro __using__(opts) do
    base_url = Keyword.get(opts, :base_url, "")

    quote do
      import MyApp.ApiClient.DSL, only: [endpoint: 3, endpoint: 4]
      Module.register_attribute(__MODULE__, :endpoints, accumulate: true)
      @base_url unquote(base_url)
      @before_compile MyApp.ApiClient.DSL
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      def __endpoints__, do: @endpoints
      def __base_url__,  do: @base_url
    end
  end

  # VALIDATION: SMELL START - Large code generation by macros
  # VALIDATION: This is a smell because every call to endpoint/3 or endpoint/4
  # VALIDATION: expands this entire block at the call site: HTTP method
  # VALIDATION: enumeration check, path binary check, timeout integer check,
  # VALIDATION: retry integer check, auth option check, response module check,
  # VALIDATION: deduplication guard, and the definition of a public function
  # VALIDATION: for that endpoint. All of this code is inlined and compiled
  # VALIDATION: separately for each endpoint declaration rather than delegating
  # VALIDATION: to a shared helper.
  defmacro endpoint(name, method, path, opts \\ []) do
    quote do
      name   = unquote(name)
      method = unquote(method)
      path   = unquote(path)
      opts   = unquote(opts)

      unless is_atom(name) do
        raise ArgumentError, "endpoint/3: name must be an atom, got #{inspect(name)}"
      end

      valid_methods = [:get, :post, :put, :patch, :delete, :head]

      unless method in valid_methods do
        raise ArgumentError,
              "endpoint/3: method must be one of #{inspect(valid_methods)}, " <>
                "got #{inspect(method)}"
      end

      unless is_binary(path) and String.starts_with?(path, "/") do
        raise ArgumentError,
              "endpoint/3: path must be a binary starting with '/', got #{inspect(path)}"
      end

      timeout_ms = Keyword.get(opts, :timeout_ms, 5_000)

      unless is_integer(timeout_ms) and timeout_ms > 0 do
        raise ArgumentError,
              "endpoint/3: :timeout_ms must be a positive integer, got #{inspect(timeout_ms)}"
      end

      retry = Keyword.get(opts, :retry, 0)

      unless is_integer(retry) and retry >= 0 do
        raise ArgumentError,
              "endpoint/3: :retry must be a non-negative integer, got #{inspect(retry)}"
      end

      valid_auth = [:none, :bearer, :service_token, :basic]
      auth = Keyword.get(opts, :auth, :bearer)

      unless auth in valid_auth do
        raise ArgumentError,
              "endpoint/3: :auth must be one of #{inspect(valid_auth)}, got #{inspect(auth)}"
      end

      existing = Module.get_attribute(__MODULE__, :endpoints)

      if Enum.any?(existing, fn e -> e.name == name end) do
        raise ArgumentError,
              "endpoint/3: duplicate endpoint name #{inspect(name)} in #{inspect(__MODULE__)}"
      end

      entry = %{
        name:       name,
        method:     method,
        path:       path,
        timeout_ms: timeout_ms,
        retry:      retry,
        auth:       auth
      }

      @endpoints entry
    end
  end
  # VALIDATION: SMELL END

  @doc """
  Executes the named endpoint on `client_module` with the provided parameters.
  """
  @spec call(module(), atom(), keyword()) :: {:ok, any()} | {:error, any()}
  def call(client_module, endpoint_name, params \\ []) do
    case Enum.find(client_module.__endpoints__(), fn e -> e.name == endpoint_name end) do
      nil ->
        {:error, {:unknown_endpoint, endpoint_name}}

      entry ->
        url = build_url(client_module.__base_url__(), entry.path, params)
        MyApp.ApiClient.HTTP.request(entry.method, url,
          timeout: entry.timeout_ms,
          auth:    entry.auth,
          retry:   entry.retry
        )
    end
  end

  defp build_url(base, path, params) do
    interpolated =
      Regex.replace(~r/:([a-z_]+)/, path, fn _, key ->
        params
        |> Keyword.get(String.to_existing_atom(key), "")
        |> to_string()
      end)

    base <> interpolated
  end
end
```
