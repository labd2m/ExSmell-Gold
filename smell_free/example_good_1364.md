```elixir
defmodule Idempotency.Key do
  @moduledoc """
  Validates and normalizes idempotency key strings provided by API callers.
  Keys must be 8–128 URL-safe characters. Invalid keys are rejected at the
  plug layer before any business logic executes.
  """

  @key_regex ~r/^[A-Za-z0-9\-_]{8,128}$/

  @type t :: String.t()

  @spec validate(String.t()) :: {:ok, t()} | {:error, :invalid_idempotency_key}
  def validate(key) when is_binary(key) do
    if Regex.match?(@key_regex, key) do
      {:ok, key}
    else
      {:error, :invalid_idempotency_key}
    end
  end

  def validate(_), do: {:error, :invalid_idempotency_key}
end

defmodule Idempotency.Store do
  @moduledoc """
  ETS-backed store for idempotency records. Each entry captures the
  cached response for a key so repeat requests receive the original
  response without re-executing the operation.
  """

  use GenServer

  @table :idempotency_store
  @ttl_ms 86_400_000

  @type record :: %{status: :pending | :complete, response: term() | nil, locked_at_ms: integer()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec lock(String.t()) :: {:ok, :acquired} | {:error, :already_exists}
  def lock(key) when is_binary(key) do
    GenServer.call(__MODULE__, {:lock, key})
  end

  @spec complete(String.t(), term()) :: :ok
  def complete(key, response) when is_binary(key) do
    GenServer.cast(__MODULE__, {:complete, key, response})
  end

  @spec lookup(String.t()) :: {:ok, record()} | {:error, :not_found}
  def lookup(key) when is_binary(key) do
    case :ets.lookup(@table, key) do
      [{^key, record}] -> {:ok, record}
      [] -> {:error, :not_found}
    end
  end

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    schedule_eviction()
    {:ok, %{}}
  end

  @impl GenServer
  def handle_call({:lock, key}, _from, state) do
    case :ets.lookup(@table, key) do
      [] ->
        record = %{status: :pending, response: nil, locked_at_ms: System.monotonic_time(:millisecond)}
        :ets.insert(@table, {key, record})
        {:reply, {:ok, :acquired}, state}

      [{^key, _existing}] ->
        {:reply, {:error, :already_exists}, state}
    end
  end

  @impl GenServer
  def handle_cast({:complete, key, response}, state) do
    case :ets.lookup(@table, key) do
      [{^key, record}] ->
        :ets.insert(@table, {key, %{record | status: :complete, response: response}})
      [] ->
        :ok
    end

    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:evict, state) do
    now = System.monotonic_time(:millisecond)
    cutoff = now - @ttl_ms
    :ets.select_delete(@table, [{{:_, %{locked_at_ms: :"$1"}}, [{:<, :"$1", cutoff}], [true]}])
    schedule_eviction()
    {:noreply, state}
  end

  defp schedule_eviction do
    Process.send_after(self(), :evict, 3_600_000)
  end
end

defmodule Idempotency.Plug do
  @moduledoc """
  A Plug that enforces idempotency for mutating HTTP requests.
  On first request: locks the key, runs the handler, caches the response.
  On repeat request: returns the cached response immediately.
  """

  import Plug.Conn

  alias Idempotency.{Key, Store}

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    with [raw_key] <- get_req_header(conn, "idempotency-key"),
         {:ok, key} <- Key.validate(raw_key) do
      handle_idempotent_request(conn, key)
    else
      _ -> conn
    end
  end

  defp handle_idempotent_request(conn, key) do
    case Store.lookup(key) do
      {:ok, %{status: :complete, response: response}} ->
        conn |> assign(:idempotent_response, response) |> assign(:idempotency_key, key)

      {:ok, %{status: :pending}} ->
        conn |> put_resp_content_type("application/json") |> send_resp(409, ~s({"error":"request_in_progress"})) |> halt()

      {:error, :not_found} ->
        case Store.lock(key) do
          {:ok, :acquired} -> assign(conn, :idempotency_key, key)
          {:error, :already_exists} ->
            conn |> put_resp_content_type("application/json") |> send_resp(409, ~s({"error":"request_in_progress"})) |> halt()
        end
    end
  end
end
```
