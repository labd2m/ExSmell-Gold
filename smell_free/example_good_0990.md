```elixir
defmodule Api.RequestBatcher do
  @moduledoc """
  Batches outbound API calls to a rate-limited upstream, collecting individual
  requests within a short collection window and dispatching them as a single
  bulk request. When the upstream does not support bulk operations, the batcher
  fans out requests concurrently while honouring the configured rate limit.
  Callers block until their specific result is available, making the batching
  transparent from the call site.
  """

  use GenServer

  require Logger

  @type request :: term()
  @type response :: {:ok, term()} | {:error, term()}
  @type batcher_opts :: [
          window_ms: pos_integer(),
          max_batch_size: pos_integer(),
          bulk_fn: ([request()] -> [{:ok, term()} | {:error, term()}]) | nil,
          single_fn: (request() -> response()),
          max_concurrency: pos_integer()
        ]

  @default_window_ms 20
  @default_max_batch 100
  @default_concurrency 10

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec start_link(batcher_opts()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Submits `request` for batched processing. Blocks the caller until the
  result is available. Returns `{:ok, result}` or `{:error, reason}`.
  """
  @spec submit(GenServer.server(), request()) :: response()
  def submit(batcher \\ __MODULE__, request) do
    GenServer.call(batcher, {:submit, request}, 30_000)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    state = %{
      window_ms: Keyword.get(opts, :window_ms, @default_window_ms),
      max_batch_size: Keyword.get(opts, :max_batch_size, @default_max_batch),
      bulk_fn: Keyword.get(opts, :bulk_fn),
      single_fn: Keyword.fetch!(opts, :single_fn),
      max_concurrency: Keyword.get(opts, :max_concurrency, @default_concurrency),
      pending: [],
      timer_ref: nil
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:submit, request}, from, state) do
    new_pending = [{from, request} | state.pending]
    new_state = %{state | pending: new_pending}

    new_state =
      cond do
        length(new_pending) >= state.max_batch_size ->
          flush(new_state)

        state.timer_ref == nil ->
          ref = Process.send_after(self(), :flush_window, state.window_ms)
          %{new_state | timer_ref: ref}

        true ->
          new_state
      end

    {:noreply, new_state}
  end

  @impl GenServer
  def handle_info(:flush_window, state) do
    {:noreply, flush(%{state | timer_ref: nil})}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp flush(%{pending: []} = state), do: state

  defp flush(%{pending: pending, bulk_fn: bulk_fn} = state) when not is_nil(bulk_fn) do
    {batch, state} = take_batch(state)
    requests = Enum.map(batch, &elem(&1, 1))
    callers = Enum.map(batch, &elem(&1, 0))

    Task.start(fn ->
      results = bulk_fn.(requests)

      Enum.zip(callers, results)
      |> Enum.each(fn {caller, result} -> GenServer.reply(caller, result) end)
    end)

    state
  end

  defp flush(%{pending: pending, single_fn: single_fn, max_concurrency: max_conc} = state) do
    {batch, state} = take_batch(state)

    Task.start(fn ->
      batch
      |> Task.async_stream(
        fn {caller, request} ->
          result = single_fn.(request)
          GenServer.reply(caller, result)
        end,
        max_concurrency: max_conc,
        timeout: 25_000
      )
      |> Stream.run()
    end)

    state
  end

  defp take_batch(%{pending: pending, max_batch_size: max} = state) do
    {batch, rest} = Enum.split(Enum.reverse(pending), max)
    {batch, %{state | pending: Enum.reverse(rest)}}
  end
end
```
