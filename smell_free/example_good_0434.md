```elixir
defmodule Content.CacheInvalidator do
  @moduledoc """
  Manages CDN cache invalidation for published content. When articles,
  landing pages, or media assets are updated, their CDN cache paths must
  be purged so visitors receive the latest version without waiting for
  TTL expiry. Invalidations are batched within a short collection window
  to avoid overwhelming the CDN API with one request per save.
  Supervised by the application; the batch flusher runs on a regular timer.
  """

  use GenServer

  alias Content.{Article, Page}

  require Logger

  @batch_window_ms 2_000
  @max_batch_size 100

  @type content_type :: :article | :page | :asset
  @type path :: binary()

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Queues CDN cache invalidation for the given content type and ID.
  Paths are resolved from the content record so callers don't need to
  know CDN path conventions. Returns `:ok` immediately; invalidation
  is asynchronous and batched.
  """
  @spec invalidate(content_type(), binary()) :: :ok
  def invalidate(content_type, content_id)
      when content_type in [:article, :page, :asset] and is_binary(content_id) do
    GenServer.cast(__MODULE__, {:queue, content_type, content_id})
  end

  @doc """
  Forces an immediate flush of all queued invalidations regardless of
  the batch window. Useful in test environments or post-deployment hooks.
  """
  @spec flush() :: {:ok, non_neg_integer()} | {:error, term()}
  def flush do
    GenServer.call(__MODULE__, :flush)
  end

  @doc """
  Returns the number of invalidations currently queued.
  """
  @spec queue_depth() :: non_neg_integer()
  def queue_depth do
    GenServer.call(__MODULE__, :queue_depth)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(_opts) do
    schedule_flush()
    {:ok, %{queue: [], timer_ref: nil}}
  end

  @impl GenServer
  def handle_cast({:queue, content_type, content_id}, state) do
    paths = resolve_paths(content_type, content_id)
    new_queue = Enum.uniq(state.queue ++ paths)
    capped_queue = Enum.take(new_queue, @max_batch_size)

    if length(new_queue) > @max_batch_size do
      Logger.warning("CDN invalidation queue at capacity, older paths evicted",
        queued: length(new_queue),
        cap: @max_batch_size
      )
    end

    {:noreply, %{state | queue: capped_queue}}
  end

  @impl GenServer
  def handle_call(:flush, _from, state) do
    {result, new_state} = do_flush(state)
    {:reply, result, new_state}
  end

  def handle_call(:queue_depth, _from, state) do
    {:reply, length(state.queue), state}
  end

  @impl GenServer
  def handle_info(:flush_timer, state) do
    {_result, new_state} = do_flush(state)
    schedule_flush()
    {:noreply, new_state}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp do_flush(%{queue: []} = state), do: {{:ok, 0}, state}

  defp do_flush(%{queue: paths} = state) do
    Logger.info("Flushing CDN invalidations", path_count: length(paths))

    case Content.CdnClient.invalidate_paths(paths) do
      {:ok, count} ->
        Logger.info("CDN invalidation submitted", paths_invalidated: count)
        {{:ok, count}, %{state | queue: []}}

      {:error, reason} ->
        Logger.error("CDN invalidation failed", reason: inspect(reason), paths: paths)
        {{:error, reason}, state}
    end
  end

  defp resolve_paths(:article, content_id) do
    article_slug = Content.Repo.get_value(Article, content_id, :slug)
    ["/articles/#{article_slug}", "/articles/#{article_slug}/amp", "/feed.xml"]
  end

  defp resolve_paths(:page, content_id) do
    page_path = Content.Repo.get_value(Page, content_id, :path)
    [page_path, "/sitemap.xml"]
  end

  defp resolve_paths(:asset, content_id) do
    ["/assets/#{content_id}", "/assets/#{content_id}/thumbnail"]
  end

  defp schedule_flush do
    Process.send_after(self(), :flush_timer, @batch_window_ms)
  end
end
```
