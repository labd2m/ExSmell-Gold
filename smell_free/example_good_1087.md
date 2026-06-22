```elixir
defmodule Feeds.FanoutWorker do
  @moduledoc """
  Broadcasts a published content item to all eligible follower feeds.
  Uses Task.async_stream to fan out writes concurrently
  while bounding concurrency to avoid downstream overload.
  """

  alias Feeds.{FollowerStore, FeedWriter}

  @max_concurrency 50
  @timeout_ms 5_000

  @type content_item :: %{
          id: String.t(),
          author_id: String.t(),
          body: String.t(),
          published_at: DateTime.t()
        }

  @spec fanout(content_item()) :: {:ok, %{delivered: non_neg_integer(), failed: non_neg_integer()}}
  def fanout(%{author_id: author_id} = item) do
    follower_ids = FollowerStore.list_follower_ids(author_id)

    results =
      follower_ids
      |> Task.async_stream(
        &write_to_feed(&1, item),
        max_concurrency: @max_concurrency,
        timeout: @timeout_ms,
        on_timeout: :kill_task
      )
      |> Enum.reduce(%{delivered: 0, failed: 0}, &tally_result/2)

    {:ok, results}
  end

  @spec write_to_feed(String.t(), content_item()) :: :ok | {:error, term()}
  defp write_to_feed(follower_id, item) do
    FeedWriter.append(follower_id, item)
  end

  @spec tally_result(
          {:ok, :ok | {:error, term()}} | {:exit, term()},
          %{delivered: non_neg_integer(), failed: non_neg_integer()}
        ) :: %{delivered: non_neg_integer(), failed: non_neg_integer()}
  defp tally_result({:ok, :ok}, acc) do
    Map.update!(acc, :delivered, &(&1 + 1))
  end

  defp tally_result({:ok, {:error, _}}, acc) do
    Map.update!(acc, :failed, &(&1 + 1))
  end

  defp tally_result({:exit, _}, acc) do
    Map.update!(acc, :failed, &(&1 + 1))
  end
end
```
