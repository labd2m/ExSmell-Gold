**File:** `example_good_1313.md`

```elixir
defmodule WeatherAPI.Config do
  @moduledoc "Runtime configuration for the weather service API client."

  @enforce_keys [:base_url, :api_key]
  defstruct [:base_url, :api_key, timeout_ms: 8_000]

  @type t :: %__MODULE__{
          base_url: String.t(),
          api_key: String.t(),
          timeout_ms: pos_integer()
        }

  @spec new(String.t(), String.t(), keyword()) :: t()
  def new(base_url, api_key, opts \\ []) do
    %__MODULE__{
      base_url: base_url,
      api_key: api_key,
      timeout_ms: Keyword.get(opts, :timeout_ms, 8_000)
    }
  end
end

defmodule WeatherAPI.Condition do
  @moduledoc "Represents a parsed weather condition for a location."

  @enforce_keys [:location, :temperature_c, :humidity_pct, :description, :fetched_at]
  defstruct [:location, :temperature_c, :humidity_pct, :description, :wind_speed_kph, :fetched_at]

  @type t :: %__MODULE__{
          location: String.t(),
          temperature_c: float(),
          humidity_pct: non_neg_integer(),
          description: String.t(),
          wind_speed_kph: float() | nil,
          fetched_at: DateTime.t()
        }
end

defmodule WeatherAPI.Client do
  @moduledoc """
  Typed HTTP client for a weather data REST API.
  All configuration is passed explicitly at call time.
  """

  alias WeatherAPI.{Config, Condition}

  @type client_error :: {:error, :not_found} | {:error, :unauthorized} | {:error, :rate_limited} | {:error, term()}

  @spec current_conditions(Config.t(), String.t()) :: {:ok, Condition.t()} | client_error()
  def current_conditions(%Config{} = config, location) when is_binary(location) do
    path = "/v1/current?location=#{URI.encode(location)}&key=#{config.api_key}"

    case get(config, path) do
      {:ok, body} -> parse_condition(body, location)
      {:error, _} = err -> err
    end
  end

  @spec forecast(Config.t(), String.t(), pos_integer()) ::
          {:ok, [Condition.t()]} | client_error()
  def forecast(%Config{} = config, location, days) when is_integer(days) and days in 1..7 do
    path = "/v1/forecast?location=#{URI.encode(location)}&days=#{days}&key=#{config.api_key}"

    case get(config, path) do
      {:ok, %{"forecast" => items}} ->
        conditions = Enum.flat_map(items, &parse_forecast_item(&1, location))
        {:ok, conditions}

      {:ok, _unexpected} ->
        {:error, :unexpected_response_format}

      {:error, _} = err ->
        err
    end
  end

  defp get(%Config{base_url: base, timeout_ms: timeout}, path) do
    url = base <> path

    case :httpc.request(:get, {String.to_charlist(url), []}, [{:timeout, timeout}], []) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        Jason.decode(IO.iodata_to_binary(body))

      {:ok, {{_, 401, _}, _, _}} ->
        {:error, :unauthorized}

      {:ok, {{_, 404, _}, _, _}} ->
        {:error, :not_found}

      {:ok, {{_, 429, _}, _, _}} ->
        {:error, :rate_limited}

      {:ok, {{_, status, _}, _, _}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, {:network_error, reason}}
    end
  end

  defp parse_condition(%{"current" => current}, location) do
    with {:ok, temp} <- fetch_float(current, "temp_c"),
         {:ok, humidity} <- fetch_integer(current, "humidity"),
         {:ok, description} <- fetch_string(current, "condition") do
      {:ok, %Condition{
        location: location,
        temperature_c: temp,
        humidity_pct: humidity,
        description: description,
        wind_speed_kph: Map.get(current, "wind_kph"),
        fetched_at: DateTime.utc_now()
      }}
    end
  end

  defp parse_condition(_, _), do: {:error, :unexpected_response_format}

  defp parse_forecast_item(%{"hour" => hours}, location) do
    Enum.flat_map(hours, fn hour ->
      case parse_condition(%{"current" => hour}, location) do
        {:ok, condition} -> [condition]
        {:error, _} -> []
      end
    end)
  end

  defp parse_forecast_item(_, _), do: []

  defp fetch_float(map, key) do
    case Map.get(map, key) do
      v when is_float(v) -> {:ok, v}
      v when is_integer(v) -> {:ok, v / 1}
      _ -> {:error, {:missing_field, key}}
    end
  end

  defp fetch_integer(map, key) do
    case Map.get(map, key) do
      v when is_integer(v) -> {:ok, v}
      _ -> {:error, {:missing_field, key}}
    end
  end

  defp fetch_string(map, key) do
    case Map.get(map, key) do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:error, {:missing_field, key}}
    end
  end
end
```
