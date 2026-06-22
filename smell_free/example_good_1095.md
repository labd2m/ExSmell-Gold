```elixir
defmodule Config.RuntimeProvider do
  @moduledoc """
  Reads application runtime configuration from environment variables,
  validates required keys, parses typed values, and surfaces structured errors
  before application startup.
  """

  @type config_spec :: %{
          key: atom(),
          env_var: String.t(),
          type: :string | :integer | :boolean | :uri,
          required: boolean(),
          default: term()
        }

  @type config_value :: String.t() | integer() | boolean() | URI.t()
  @type load_result :: {:ok, map()} | {:error, [{atom(), atom()}]}

  @spec load([config_spec()]) :: load_result()
  def load(specs) when is_list(specs) do
    {values, errors} =
      Enum.reduce(specs, {%{}, []}, fn spec, {acc_values, acc_errors} ->
        case resolve(spec) do
          {:ok, value} -> {Map.put(acc_values, spec.key, value), acc_errors}
          {:error, reason} -> {acc_values, [{spec.key, reason} | acc_errors]}
        end
      end)

    case errors do
      [] -> {:ok, values}
      _ -> {:error, Enum.reverse(errors)}
    end
  end

  @spec resolve(config_spec()) :: {:ok, config_value()} | {:error, atom()}
  defp resolve(%{env_var: env_var, type: type, required: required, default: default}) do
    case System.get_env(env_var) do
      nil when required == true -> {:error, :missing_required}
      nil -> {:ok, default}
      raw -> parse(raw, type)
    end
  end

  @spec parse(String.t(), atom()) :: {:ok, config_value()} | {:error, atom()}
  defp parse(raw, :string), do: {:ok, raw}

  defp parse(raw, :integer) do
    case Integer.parse(raw) do
      {value, ""} -> {:ok, value}
      _ -> {:error, :invalid_integer}
    end
  end

  defp parse("true", :boolean), do: {:ok, true}
  defp parse("false", :boolean), do: {:ok, false}
  defp parse(_, :boolean), do: {:error, :invalid_boolean}

  defp parse(raw, :uri) do
    uri = URI.parse(raw)

    if is_binary(uri.scheme) and is_binary(uri.host) do
      {:ok, uri}
    else
      {:error, :invalid_uri}
    end
  end

  defp parse(_raw, unknown_type) do
    {:error, {:unsupported_type, unknown_type}}
  end
end
```
