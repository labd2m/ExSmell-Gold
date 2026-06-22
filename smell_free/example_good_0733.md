```elixir
defmodule Platform.ConfigLoader do
  @moduledoc """
  Loads application configuration from multiple sources and formats —
  environment variables, JSON files, and key=value dotenv files — merging
  them in priority order: env vars override file values, later sources
  override earlier ones.

  Useful for local development overrides, Docker secrets, and CI environments
  where config is injected through different mechanisms.
  """

  @type config_map :: %{optional(String.t()) => term()}
  @type source :: {:env, [String.t()]} | {:json_file, Path.t()} | {:dotenv_file, Path.t()}

  @doc """
  Loads and merges configuration from `sources` in order.
  Later sources take precedence over earlier ones.
  """
  @spec load([source()]) :: {:ok, config_map()} | {:error, term()}
  def load(sources) when is_list(sources) do
    Enum.reduce_while(sources, {:ok, %{}}, fn source, {:ok, acc} ->
      case load_source(source) do
        {:ok, values} -> {:cont, {:ok, Map.merge(acc, values)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc "Loads a single source and returns its key-value map."
  @spec load_source(source()) :: {:ok, config_map()} | {:error, term()}
  def load_source({:env, keys}) when is_list(keys) do
    values =
      keys
      |> Enum.flat_map(fn key ->
        case System.get_env(key) do
          nil -> []
          value -> [{key, value}]
        end
      end)
      |> Map.new()

    {:ok, values}
  end

  def load_source({:env_prefix, prefix}) when is_binary(prefix) do
    values =
      System.get_env()
      |> Enum.filter(fn {key, _} -> String.starts_with?(key, prefix) end)
      |> Enum.map(fn {key, value} ->
        stripped = String.replace_prefix(key, prefix, "")
        {stripped, value}
      end)
      |> Map.new()

    {:ok, values}
  end

  def load_source({:json_file, path}) when is_binary(path) do
    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, map} when is_map(map) -> {:ok, stringify_keys(map)}
          {:ok, _other} -> {:error, {:invalid_json_structure, path}}
          {:error, reason} -> {:error, {:json_parse_error, path, reason}}
        end

      {:error, :enoent} ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, {:file_read_error, path, reason}}
    end
  end

  def load_source({:dotenv_file, path}) when is_binary(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, parse_dotenv(content)}
      {:error, :enoent} -> {:ok, %{}}
      {:error, reason} -> {:error, {:file_read_error, path, reason}}
    end
  end

  @doc """
  Validates that all `required_keys` are present in `config`.
  Returns `:ok` or `{:error, {:missing_keys, [String.t()]}}`.
  """
  @spec validate_required(config_map(), [String.t()]) :: :ok | {:error, {:missing_keys, [String.t()]}}
  def validate_required(config, required_keys) when is_map(config) and is_list(required_keys) do
    missing = Enum.reject(required_keys, &Map.has_key?(config, &1))
    if missing == [], do: :ok, else: {:error, {:missing_keys, missing}}
  end

  defp parse_dotenv(content) do
    content
    |> String.split("\n")
    |> Enum.reject(&(String.trim(&1) == "" or String.starts_with?(String.trim(&1), "#")))
    |> Enum.flat_map(fn line ->
      case String.split(line, "=", parts: 2) do
        [key, value] ->
          clean_key = String.trim(key)
          clean_value = value |> String.trim() |> strip_quotes()
          if clean_key != "", do: [{clean_key, clean_value}], else: []

        _ ->
          []
      end
    end)
    |> Map.new()
  end

  defp strip_quotes(<<"\"", rest::binary>>) when binary_part(rest, byte_size(rest) - 1, 1) == "\"" do
    binary_part(rest, 0, byte_size(rest) - 1)
  end

  defp strip_quotes(<<"'", rest::binary>>) when binary_part(rest, byte_size(rest) - 1, 1) == "'" do
    binary_part(rest, 0, byte_size(rest) - 1)
  end

  defp strip_quotes(value), do: value

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end
end
```
