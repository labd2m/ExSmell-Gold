```elixir
defmodule Platform.BatchLoader do
  @moduledoc """
  A GenServer that coalesces individual record-load requests arriving within
  a short window into a single batched database query.

  This is the foundational pattern behind Dataloader: instead of issuing
  N queries for N associations, callers enqueue keys and a single batch query
  satisfies all of them once the window closes.
  """

  use GenServer

  @type schema :: module()
  @type key :: term()
  @type result :: {:ok, struct()} | {:error, :not_found}
  @type batch_fn :: ([key()] -> %{optional(key()) => struct()})

  @default_window_ms 5

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Enqueues `key` for batched loading using `batch_fn`.
  Blocks until the batch fires and the result is available.
  The `batch_fn` receives a list of keys and must return a `key => struct` map.
  """
  @spec load(term(), [key()], batch_fn()) :: result()
  def load(batch_id, key, batch_fn) when is_function(batch_fn, 1) do
    GenServer.call(__MODULE__, {:load, batch_id, key, batch_fn}, 10_000)
  end

  @doc "Returns current queue depth across all pending batches."
  @spec pending_count() :: non_neg_integer()
  def pending_count, do: GenServer.call(__MODULE__, :pending_count)

  @impl GenServer
  def init(opts) do
    window_ms = Keyword.get(opts, :window_ms, @default_window_ms)
    {:ok, %{batches: %{}, window_ms: window_ms}}
  end

  @impl GenServer
  def handle_call({:load, batch_id, key, batch_fn}, from, state) do
    batch = Map.get(state.batches, batch_id, new_batch(batch_fn, state.window_ms))
    updated_batch = add_to_batch(batch, key, from)
    {:noreply, put_in(state, [:batches, batch_id], updated_batch)}
  end

  @impl GenServer
  def handle_call(:pending_count, _from, state) do
    count = state.batches |> Map.values() |> Enum.sum_by(fn b -> map_size(b.waiters) end)
    {:reply, count, state}
  end

  @impl GenServer
  def handle_info({:fire_batch, batch_id}, %{batches: batches} = state) do
    case Map.get(batches, batch_id) do
      nil ->
        {:noreply, state}

      batch ->
        execute_batch(batch)
        {:noreply, %{state | batches: Map.delete(batches, batch_id)}}
    end
  end

  defp new_batch(batch_fn, window_ms) do
    %{batch_fn: batch_fn, waiters: %{}, window_ms: window_ms, timer_ref: nil}
  end

  defp add_to_batch(%{waiters: waiters, timer_ref: old_ref, window_ms: window_ms} = batch, key, from) do
    if old_ref, do: Process.cancel_timer(old_ref)
    batch_id = make_ref()
    timer_ref = Process.send_after(self(), {:fire_batch, batch_id}, window_ms)

    updated_waiters = Map.update(waiters, key, [from], fn froms -> [from | froms] end)
    %{batch | waiters: updated_waiters, timer_ref: timer_ref}
  end

  defp execute_batch(%{batch_fn: batch_fn, waiters: waiters}) do
    keys = Map.keys(waiters)
    results = batch_fn.(keys)

    Enum.each(waiters, fn {key, froms} ->
      result = case Map.get(results, key) do
        nil -> {:error, :not_found}
        value -> {:ok, value}
      end

      Enum.each(froms, fn from -> GenServer.reply(from, result) end)
    end)
  end
end
```
