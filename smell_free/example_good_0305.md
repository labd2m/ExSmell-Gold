```elixir
defmodule Geo.PostalCodeLookup do
  @moduledoc """
  In-process lookup service for postal code metadata. Records are loaded
  from a CSV fixture at startup into ETS for O(1) access. Supports exact
  lookup and prefix-based search for autocomplete features. The table is
  owned by the GenServer so it is destroyed automatically on crash and
  rebuilt on restart.
  """

  use GenServer

  @table :postal_code_data
  @fixture_path Application.compile_env(:my_app, :postal_code_fixture, "priv/data/postal_codes.csv")

  @type postal_code :: String.t()
  @type record :: %{
          code: postal_code(),
          city: String.t(),
          state: String.t(),
          country: String.t(),
          latitude: float(),
          longitude: float()
        }

  @doc "Starts the lookup service and loads data from the CSV fixture."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Looks up a postal code. Returns `{:error, :not_found}` for unknown codes."
  @spec lookup(postal_code()) :: {:ok, record()} | {:error, :not_found}
  def lookup(code) when is_binary(code) do
    case :ets.lookup(@table, String.upcase(code)) do
      [{_code, record}] -> {:ok, record}
      [] -> {:error, :not_found}
    end
  end

  @doc "Returns all records whose code starts with `prefix`, up to `limit` results."
  @spec search_prefix(String.t(), pos_integer()) :: [record()]
  def search_prefix(prefix, limit \\ 10)
      when is_binary(prefix) and is_integer(limit) and limit > 0 do
    upcased = String.upcase(prefix)

    :ets.tab2list(@table)
    |> Stream.filter(fn {code, _} -> String.starts_with?(code, upcased) end)
    |> Stream.map(fn {_code, record} -> record end)
    |> Enum.take(limit)
  end

  @doc "Returns the total number of loaded records."
  @spec record_count() :: non_neg_integer()
  def record_count, do: :ets.info(@table, :size)

  @impl GenServer
  def init(opts) do
    path = Keyword.get(opts, :fixture_path, @fixture_path)
    table = :ets.new(@table, [:set, :protected, :named_table, read_concurrency: true])
    count = load_fixture(path, table)
    {:ok, %{table: table, record_count: count}}
  end

  defp load_fixture(path, table) do
    if File.exists?(path) do
      path
      |> File.stream!([], :line)
      |> Stream.drop(1)
      |> Stream.map(&parse_line/1)
      |> Stream.reject(&is_nil/1)
      |> Enum.reduce(0, fn record, count ->
        :ets.insert(table, {record.code, record})
        count + 1
      end)
    else
      0
    end
  end

  defp parse_line(line) do
    case line |> String.trim() |> String.split(",") do
      [code, city, state, country, lat_raw, lng_raw] ->
        with {lat, ""} <- Float.parse(lat_raw),
             {lng, ""} <- Float.parse(lng_raw) do
          %{code: String.upcase(code), city: city, state: state,
            country: country, latitude: lat, longitude: lng}
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end
end
```
