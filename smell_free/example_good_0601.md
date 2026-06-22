```elixir
defmodule Recommendations.CollaborativeFilter do
  @moduledoc """
  Generates product recommendations using item-based collaborative filtering.
  Co-occurrence scores between products are precomputed from order history
  and stored in ETS for sub-millisecond lookup at recommendation time.
  The score matrix is rebuilt on a configurable schedule via a supervised
  GenServer so recommendations stay fresh without blocking the request path.
  """

  use GenServer

  alias Recommendations.{OrderHistory, Repo}

  require Logger

  @table :collab_filter_scores
  @rebuild_interval_ms 6 * 60 * 60 * 1_000
  @top_k_candidates 50

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns up to `limit` recommended product IDs for `product_id`, ordered
  by descending co-occurrence score. Returns an empty list when the product
  has no co-occurrence data.
  """
  @spec recommend(binary(), pos_integer()) :: [binary()]
  def recommend(product_id, limit \\ 10)
      when is_binary(product_id) and is_integer(limit) and limit > 0 do
    case :ets.lookup(@table, product_id) do
      [{^product_id, scores}] ->
        scores
        |> Enum.sort_by(&elem(&1, 1), :desc)
        |> Enum.take(limit)
        |> Enum.map(&elem(&1, 0))

      [] ->
        []
    end
  end

  @doc """
  Forces an immediate rebuild of the co-occurrence matrix. Returns once the
  rebuild is complete. Useful after large data imports.
  """
  @spec rebuild() :: :ok
  def rebuild do
    GenServer.call(__MODULE__, :rebuild, 120_000)
  end

  @doc """
  Returns the number of products that currently have co-occurrence data.
  """
  @spec indexed_product_count() :: non_neg_integer()
  def indexed_product_count, do: :ets.info(@table, :size)

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{}, {:continue, :initial_build}}
  end

  @impl GenServer
  def handle_continue(:initial_build, state) do
    do_rebuild()
    schedule_rebuild()
    {:noreply, state}
  end

  @impl GenServer
  def handle_call(:rebuild, _from, state) do
    do_rebuild()
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_info(:rebuild, state) do
    do_rebuild()
    schedule_rebuild()
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp do_rebuild do
    Logger.info("Rebuilding collaborative filter co-occurrence matrix")
    started_at = System.monotonic_time(:millisecond)

    orders = OrderHistory.recent_orders(days: 90)
    matrix = build_cooccurrence_matrix(orders)

    :ets.delete_all_objects(@table)

    Enum.each(matrix, fn {product_id, scores} ->
      top_k = scores |> Enum.sort_by(&elem(&1, 1), :desc) |> Enum.take(@top_k_candidates)
      :ets.insert(@table, {product_id, top_k})
    end)

    elapsed = System.monotonic_time(:millisecond) - started_at

    Logger.info("Co-occurrence matrix rebuilt",
      products_indexed: map_size(matrix),
      duration_ms: elapsed
    )
  end

  defp build_cooccurrence_matrix(orders) do
    orders
    |> Enum.reduce(%{}, fn order, acc ->
      product_ids = Enum.map(order.items, & &1.product_id)
      pairs = for a <- product_ids, b <- product_ids, a != b, do: {a, b}

      Enum.reduce(pairs, acc, fn {a, b}, matrix ->
        Map.update(matrix, a, [{b, 1}], fn scores ->
          case Enum.find_index(scores, fn {id, _} -> id == b end) do
            nil -> [{b, 1} | scores]
            idx -> List.update_at(scores, idx, fn {id, n} -> {id, n + 1} end)
          end
        end)
      end)
    end)
    |> normalise_scores()
  end

  defp normalise_scores(matrix) do
    Map.new(matrix, fn {product_id, scores} ->
      max_score = scores |> Enum.map(&elem(&1, 1)) |> Enum.max(fn -> 1 end)
      normalised = Enum.map(scores, fn {id, score} -> {id, score / max_score} end)
      {product_id, normalised}
    end)
  end

  defp schedule_rebuild do
    Process.send_after(self(), :rebuild, @rebuild_interval_ms)
  end
end
```
