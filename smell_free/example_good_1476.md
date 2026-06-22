```elixir
defmodule Config.Source do
  @moduledoc """
  Defines the behaviour that all configuration source adapters must implement.
  """

  @callback fetch(String.t()) :: {:ok, String.t()} | {:error, :not_found | term()}
  @callback fetch_all(prefix :: String.t()) :: {:ok, map()} | {:error, term()}
end

defmodule Config.EnvSource do
  @behaviour Config.Source

  @moduledoc """
  Resolves configuration values from OS environment variables.
  Key names are upper-cased before lookup.
  """

  @impl Config.Source
  def fetch(key) when is_binary(key) do
    env_key = String.upcase(key)

    case System.get_env(env_key) do
      nil -> {:error, :not_found}
      value -> {:ok, value}
    end
  end

  @impl Config.Source
  def fetch_all(prefix) when is_binary(prefix) do
    env_prefix = String.upcase(prefix) <> "_"

    result =
      System.get_env()
      |> Enum.filter(fn {key, _} -> String.starts_with?(key, env_prefix) end)
      |> Enum.map(fn {key, value} ->
        short_key = key |> String.replace_leading(env_prefix, "") |> String.downcase()
        {short_key, value}
      end)
      |> Map.new()

    {:ok, result}
  end
end

defmodule Config.Resolver do
  @moduledoc """
  Resolves typed configuration values from a prioritized list of sources.
  The first source to return a value wins. Supports optional coercion to
  integer, boolean, and list types.
  """

  @type coerce_type :: :string | :integer | :boolean | :list
  @type resolve_opts :: [type: coerce_type(), default: term(), separator: String.t()]

  @spec resolve(String.t(), [Config.Source.t()], resolve_opts()) ::
          {:ok, term()} | {:error, :not_found | :coercion_failed}
  def resolve(key, sources, opts \\ [])
      when is_binary(key) and is_list(sources) do
    type = Keyword.get(opts, :type, :string)
    default = Keyword.get(opts, :default)

    case find_value(key, sources) do
      {:ok, raw} -> coerce(raw, type, opts)
      {:error, :not_found} when not is_nil(default) -> {:ok, default}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  defp find_value(_key, []), do: {:error, :not_found}

  defp find_value(key, [source | rest]) do
    case source.fetch(key) do
      {:ok, value} -> {:ok, value}
      {:error, _} -> find_value(key, rest)
    end
  end

  defp coerce(raw, :string, _opts), do: {:ok, raw}

  defp coerce(raw, :integer, _opts) do
    case Integer.parse(raw) do
      {int, ""} -> {:ok, int}
      _ -> {:error, :coercion_failed}
    end
  end

  defp coerce(raw, :boolean, _opts) do
    case String.downcase(String.trim(raw)) do
      v when v in ["true", "1", "yes"] -> {:ok, true}
      v when v in ["false", "0", "no"] -> {:ok, false}
      _ -> {:error, :coercion_failed}
    end
  end

  defp coerce(raw, :list, opts) do
    separator = Keyword.get(opts, :separator, ",")
    items = raw |> String.split(separator) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
    {:ok, items}
  end
end
```
