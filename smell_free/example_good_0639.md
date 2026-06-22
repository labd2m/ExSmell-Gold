```elixir
defmodule Infra.SecretManager do
  @moduledoc """
  Provides a unified interface for reading application secrets at runtime.
  The backend is swappable via application configuration, supporting
  environment variables, HashiCorp Vault, and AWS Secrets Manager.
  All backends implement the `Infra.SecretBackend` behaviour. Secrets are
  cached briefly to reduce latency on hot paths while limiting stale windows.
  """

  @cache_ttl_ms :timer.seconds(30)

  @type secret_name :: String.t()
  @type secret_value :: String.t()

  @doc """
  Fetches `secret_name` from the configured backend. Caches the result
  for #{div(@cache_ttl_ms, 1_000)} seconds to reduce backend calls on hot paths.
  """
  @spec fetch(secret_name()) :: {:ok, secret_value()} | {:error, :not_found | term()}
  def fetch(name) when is_binary(name) do
    case :persistent_term.get({__MODULE__, name}, :miss) do
      :miss -> fetch_and_cache(name)
      {value, cached_at} ->
        if System.monotonic_time(:millisecond) - cached_at < @cache_ttl_ms do
          {:ok, value}
        else
          :persistent_term.erase({__MODULE__, name})
          fetch_and_cache(name)
        end
    end
  end

  @doc "Fetches `secret_name` or raises `RuntimeError` if unavailable."
  @spec fetch!(secret_name()) :: secret_value()
  def fetch!(name) when is_binary(name) do
    case fetch(name) do
      {:ok, value} -> value
      {:error, reason} -> raise RuntimeError, "Secret '#{name}' unavailable: #{inspect(reason)}"
    end
  end

  @doc "Removes the cached value for `secret_name`, forcing the next fetch to hit the backend."
  @spec invalidate(secret_name()) :: :ok
  def invalidate(name) when is_binary(name) do
    :persistent_term.erase({__MODULE__, name})
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp fetch_and_cache(name) do
    case backend().fetch(name) do
      {:ok, value} ->
        :persistent_term.put({__MODULE__, name}, {value, System.monotonic_time(:millisecond)})
        {:ok, value}

      {:error, _} = err ->
        err
    end
  end

  defp backend do
    Application.get_env(:my_app, :secret_backend, Infra.EnvSecretBackend)
  end
end

defmodule Infra.SecretBackend do
  @moduledoc "Behaviour for secret storage backends."

  @doc "Fetches `secret_name` from the backend."
  @callback fetch(secret_name :: String.t()) :: {:ok, String.t()} | {:error, :not_found | term()}
end

defmodule Infra.EnvSecretBackend do
  @moduledoc "Reads secrets from OS environment variables."

  @behaviour Infra.SecretBackend

  @impl Infra.SecretBackend
  def fetch(name) when is_binary(name) do
    env_key = name |> String.upcase() |> String.replace("-", "_")
    case System.get_env(env_key) do
      nil -> {:error, :not_found}
      value -> {:ok, value}
    end
  end
end
```
