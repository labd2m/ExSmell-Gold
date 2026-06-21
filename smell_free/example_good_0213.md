```elixir
defmodule MyApp.Geo.PostalRouter do
  @moduledoc """
  Maps postal codes to their configured fulfilment warehouse using a
  prefix-tree lookup. Routing rules are loaded once from the database at
  startup and cached in ETS for sub-microsecond reads on the hot path.
  The cache is refreshed by calling `reload/0`, which can be triggered
  via an admin action or a scheduled job without restarting the process.
  """

  use GenServer

  alias MyApp.Repo
  alias MyApp.Geo.PostalRoute

  import Ecto.Query, warn: false

  @table __MODULE__

  @type warehouse_id :: String.t()
  @type postal_code :: String.t()

  @doc "Starts the router process and pre-warms the ETS cache."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the warehouse ID responsible for delivering to `postal_code`,
  matching longest prefix first.
  Returns `{:error, :no_route}` when no rule covers the code.
  """
  @spec route(postal_code()) :: {:ok, warehouse_id()} | {:error, :no_route}
  def route(postal_code) when is_binary(postal_code) do
    postal_code
    |> prefixes()
    |> Enum.find_value(:none, fn prefix ->
      case :ets.lookup(@table, prefix) do
        [{^prefix, wh_id}] -> {:ok, wh_id}
        [] -> nil
      end
    end)
    |> case do
      :none -> {:error, :no_route}
      result -> result
    end
  end

  @doc "Reloads all routing rules from the database into the ETS cache."
  @spec reload() :: :ok
  def reload, do: GenServer.call(__MODULE__, :reload)

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    load_routes()
    {:ok, %{}}
  end

  @impl GenServer
  def handle_call(:reload, _from, state) do
    :ets.delete_all_objects(@table)
    load_routes()
    {:reply, :ok, state}
  end

  @spec load_routes() :: :ok
  defp load_routes do
    PostalRoute
    |> select([r], {r.postal_prefix, r.warehouse_id})
    |> Repo.all()
    |> Enum.each(fn {prefix, wh_id} ->
      :ets.insert(@table, {prefix, wh_id})
    end)
  end

  @spec prefixes(postal_code()) :: [String.t()]
  defp prefixes(code) do
    code
    |> String.length()
    |> Range.new(1)
    |> Enum.map(&String.slice(code, 0, &1))
  end
end
```
