```elixir
defmodule Publishing.Newsletters.SegmentDispatcher do
  @moduledoc """
  Dispatches newsletter editions to subscriber segments.
  Each segment is delivered concurrently via a supervised task pool.
  Send results are aggregated per segment with success and failure counts.
  """

  alias Publishing.Newsletters.{Edition, Segment, SubscriberRepository}

  @type segment_result :: %{
          segment_id: String.t(),
          sent: non_neg_integer(),
          failed: non_neg_integer(),
          errors: [String.t()]
        }

  @doc """
  Dispatches `edition` to all `segments` concurrently.
  Returns a list of per-segment delivery results.
  """
  @spec dispatch(Edition.t(), [Segment.t()], keyword()) ::
          {:ok, [segment_result()]} | {:error, String.t()}
  def dispatch(%Edition{} = edition, segments, opts \\ []) when is_list(segments) do
    repo = Keyword.get(opts, :repo, SubscriberRepository)
    mailer = Keyword.get(opts, :mailer, Publishing.Mailer)
    concurrency = Keyword.get(opts, :concurrency, 4)

    with :ok <- validate_edition(edition),
         :ok <- validate_segments(segments) do
      results =
        segments
        |> Task.async_stream(
          fn segment -> deliver_segment(edition, segment, repo, mailer) end,
          max_concurrency: concurrency,
          ordered: false,
          timeout: 60_000,
          on_timeout: :kill_task
        )
        |> Enum.map(&unwrap_segment_result/1)

      {:ok, results}
    end
  end

  defp deliver_segment(edition, segment, repo, mailer) do
    case repo.subscribers_for_segment(segment.id) do
      {:ok, subscribers} ->
        results = Enum.map(subscribers, fn sub -> send_to_subscriber(edition, sub, mailer) end)
        failures = Enum.filter(results, fn r -> match?({:error, _}, r) end)
        errors = Enum.map(failures, fn {:error, r} -> r end)

        %{
          segment_id: segment.id,
          sent: length(subscribers) - length(failures),
          failed: length(failures),
          errors: errors
        }

      {:error, reason} ->
        %{segment_id: segment.id, sent: 0, failed: 0, errors: ["failed to load subscribers: #{reason}"]}
    end
  end

  defp send_to_subscriber(edition, subscriber, mailer) do
    mailer.send(%{
      to: subscriber.email,
      subject: edition.subject,
      html_body: edition.html_body,
      text_body: edition.text_body
    })
  rescue
    e -> {:error, "mailer exception for #{subscriber.email}: #{Exception.message(e)}"}
  end

  defp unwrap_segment_result({:ok, result}), do: result

  defp unwrap_segment_result({:exit, reason}) do
    %{segment_id: "unknown", sent: 0, failed: 0, errors: ["task exited: #{inspect(reason)}"]}
  end

  defp validate_edition(%Edition{id: id, subject: subj, html_body: html})
       when is_binary(id) and id != "" and is_binary(subj) and subj != "" and
              is_binary(html) and html != "",
       do: :ok

  defp validate_edition(_), do: {:error, "edition must have non-empty id, subject, and html_body"}

  defp validate_segments([]), do: {:error, "at least one segment is required"}

  defp validate_segments(segments) do
    invalid = Enum.find(segments, fn s -> not (is_binary(s.id) and s.id != "") end)

    if is_nil(invalid) do
      :ok
    else
      {:error, "each segment must have a non-empty id"}
    end
  end
end
```
