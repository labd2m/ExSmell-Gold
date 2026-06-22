```elixir
defmodule Infra.Config.RuntimeResolver do
  @moduledoc """
  Resolves application runtime configuration from layered sources.

  Merges configuration from environment variables, mounted secrets, and
  application defaults according to a defined precedence order, providing
  a unified typed configuration interface for dependent services.
  """

  alias Infra.Config.{SecretStore, Schema, ValidationError}

  @type resolved_config :: map()
  @type config_error :: {:error, ValidationError.t()} | {:error, :secret_unavailable, String.t()}

  @doc """
  Resolves and validates the full runtime configuration map.

  Sources are merged in precedence order: environment variables override
  mounted secrets, which override compiled application defaults.
  Returns `{:ok, config}` or a tagged validation error.
  """
  @spec resolve(Schema.t()) :: {:ok, resolved_config()} | config_error()
  def resolve(%Schema{} = schema) do
    with {:ok, defaults} <- load_defaults(schema),
         {:ok, secrets} <- load_secrets(schema),
         {:ok, env_overrides} <- load_env_overrides(schema) do
      merged = defaults |> deep_merge(secrets) |> deep_merge(env_overrides)
      validate_config(merged, schema)
    end
  end

  @doc """
  Resolves a single named configuration key from the layered sources.

  Returns `{:ok, value}` or `{:error, :key_not_found}`.
  """
  @spec resolve_key(Schema.t(), atom()) :: {:ok, term()} | {:error, :key_not_found}
  def resolve_key(%Schema{} = schema, key) when is_atom(key) do
    with {:ok, config} <- resolve(schema) do
      case Map.fetch(config, key) do
        {:ok, value} -> {:ok, value}
        :error -> {:error, :key_not_found}
      end
    end
  end

  defp load_defaults(%Schema{defaults: defaults}), do: {:ok, defaults}

  defp load_secrets(%Schema{secret_keys: []}) do
    {:ok, %{}}
  end

  defp load_secrets(%Schema{secret_keys: keys}) do
    keys
    |> Enum.reduce_while({:ok, %{}}, fn key, {:ok, acc} ->
      case SecretStore.fetch(key) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
        {:error, :not_found} -> {:cont, {:ok, acc}}
        {:error, :unavailable} -> {:halt, {:error, :secret_unavailable, Atom.to_string(key)}}
      end
    end)
  end

  defp load_env_overrides(%Schema{env_mappings: mappings}) do
    resolved =
      Enum.reduce(mappings, %{}, fn {config_key, env_var}, acc ->
        case System.get_env(env_var) do
          nil -> acc
          value -> Map.put(acc, config_key, value)
        end
      end)

    {:ok, resolved}
  end

  defp validate_config(config, %Schema{required_keys: required, validators: validators}) do
    with :ok <- check_required_keys(config, required),
         :ok <- run_validators(config, validators) do
      {:ok, config}
    end
  end

  defp check_required_keys(config, required) do
    missing = Enum.reject(required, &Map.has_key?(config, &1))

    case missing do
      [] -> :ok
      keys -> {:error, ValidationError.missing_keys(keys)}
    end
  end

  defp run_validators(config, validators) do
    validators
    |> Enum.reduce_while(:ok, fn {key, validator_fn}, :ok ->
      value = Map.get(config, key)

      case validator_fn.(value) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, ValidationError.field_invalid(key, reason)}}
      end
    end)
  end

  defp deep_merge(base, override) do
    Map.merge(base, override, fn _key, base_val, override_val ->
      if is_map(base_val) and is_map(override_val) do
        deep_merge(base_val, override_val)
      else
        override_val
      end
    end)
  end
end
```
