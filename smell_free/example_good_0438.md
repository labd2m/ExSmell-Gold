```elixir
defmodule Geo.IpLookup do
  @moduledoc """
  Provides country and city-level geolocation for IPv4 and IPv6 addresses
  using a locally loaded MaxMind GeoLite2 database. The database is read
  into memory on startup and refreshed on a weekly schedule, keeping
  lookup latency under 1 ms without any network round-trips.
  The GenServer owns the database state; all lookups are served directly
  from a public ETS table for maximum read throughput.
  """

  use GenServer

  require Logger

  @table :geo_ip_db
  @db_key :current_db
  @refresh_interval_ms 7 * 24 * 60 * 60 * 1000

  @type ip_address :: binary()
  @type geo_result :: %{
          country_code: binary(),
          country_name: binary(),
          city: binary() | nil,
          latitude: float() | nil,
          longitude: float() | nil,
          timezone: binary() | nil
        }

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns geolocation data for `ip_address`.
  Returns `{:ok, geo_result}` or `{:error, :not_found | :invalid_ip | :db_not_loaded}`.
  """
  @spec lookup(ip_address()) :: {:ok, geo_result()} | {:error, atom()}
  def lookup(ip_address) when is_binary(ip_address) do
    case :ets.lookup(@table, @db_key) do
      [{@db_key, db}] ->
        perform_lookup(db, ip_address)

      [] ->
        {:error, :db_not_loaded}
    end
  end

  @doc """
  Returns the ISO 3166-1 alpha-2 country code for `ip_address`, or `nil`.
  Convenience wrapper around `lookup/1` for call sites that only need the code.
  """
  @spec country_code(ip_address()) :: binary() | nil
  def country_code(ip_address) when is_binary(ip_address) do
    case lookup(ip_address) do
      {:ok, %{country_code: code}} -> code
      _ -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    db_path = Keyword.get(opts, :db_path, default_db_path())
    {:ok, %{db_path: db_path}, {:continue, :load_db}}
  end

  @impl GenServer
  def handle_continue(:load_db, state) do
    load_database(state.db_path)
    schedule_refresh()
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:refresh_db, state) do
    load_database(state.db_path)
    schedule_refresh()
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp load_database(db_path) do
    case Geolix.load_database(%{id: :geo_ip, adapter: Geolix.Adapter.MMDB2, source: db_path}) do
      :ok ->
        :ets.insert(@table, {@db_key, :geo_ip})
        Logger.info("GeoIP database loaded", path: db_path)
        :ok

      {:error, reason} ->
        Logger.error("Failed to load GeoIP database", path: db_path, reason: inspect(reason))
        {:error, reason}
    end
  end

  defp perform_lookup(db_id, ip_address) do
    with {:ok, parsed_ip} <- parse_ip(ip_address),
         record when not is_nil(record) <- Geolix.lookup(parsed_ip, where: db_id) do
      {:ok, build_result(record)}
    else
      {:error, :invalid_ip} -> {:error, :invalid_ip}
      nil -> {:error, :not_found}
    end
  end

  defp parse_ip(ip_string) do
    ip_string
    |> String.to_charlist()
    |> :inet.parse_address()
    |> case do
      {:ok, ip_tuple} -> {:ok, ip_tuple}
      {:error, _} -> {:error, :invalid_ip}
    end
  end

  defp build_result(record) do
    country = get_in(record, [:country, :iso_code]) || get_in(record, [:registered_country, :iso_code])
    country_name = get_in(record, [:country, :names, :en]) || get_in(record, [:registered_country, :names, :en])
    city = get_in(record, [:city, :names, :en])
    location = Map.get(record, :location, %{})

    %{
      country_code: country,
      country_name: country_name,
      city: city,
      latitude: Map.get(location, :latitude),
      longitude: Map.get(location, :longitude),
      timezone: Map.get(location, :time_zone)
    }
  end

  defp default_db_path do
    Application.get_env(:my_app, :geoip_db_path, "/var/data/GeoLite2-City.mmdb")
  end

  defp schedule_refresh do
    Process.send_after(self(), :refresh_db, @refresh_interval_ms)
  end
end
```
