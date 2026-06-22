```elixir
defmodule Analytics.Reports.DailySummary do
  @moduledoc """
  Computes daily summary statistics from a stream of event records.
  Supports bucketing by event type and calculating aggregates per bucket.
  """

  @type event :: %{type: String.t(), value: number(), occurred_at: Date.t()}
  @type bucket_stats :: %{count: non_neg_integer(), total: number(), average: float()}
  @type summary :: %{date: Date.t(), buckets: %{String.t() => bucket_stats()}}

  @doc """
  Builds a daily summary from a list of events occurring on the same date.
  Returns `{:ok, summary}` or `{:error, reason}` if the event list is invalid.
  """
  @spec build([event()], Date.t()) :: {:ok, summary()} | {:error, String.t()}
  def build(events, %Date{} = date) when is_list(events) do
    case validate_events(events) do
      :ok ->
        buckets =
          events
          |> Enum.group_by(fn e -> e.type end)
          |> Enum.into(%{}, fn {type, type_events} -> {type, compute_stats(type_events)} end)

        {:ok, %{date: date, buckets: buckets}}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Merges two daily summaries with the same date into one combined summary.
  Returns `{:error, :date_mismatch}` if dates differ.
  """
  @spec merge(summary(), summary()) :: {:ok, summary()} | {:error, :date_mismatch}
  def merge(%{date: d} = a, %{date: d} = b) do
    merged_buckets =
      Map.merge(a.buckets, b.buckets, fn _type, stats_a, stats_b ->
        merge_stats(stats_a, stats_b)
      end)

    {:ok, %{date: d, buckets: merged_buckets}}
  end

  def merge(%{date: _}, %{date: _}), do: {:error, :date_mismatch}

  @doc """
  Returns stats for a specific bucket within a summary.
  """
  @spec fetch_bucket(summary(), String.t()) :: {:ok, bucket_stats()} | {:error, :not_found}
  def fetch_bucket(%{buckets: buckets}, type) when is_binary(type) do
    case Map.fetch(buckets, type) do
      {:ok, stats} -> {:ok, stats}
      :error -> {:error, :not_found}
    end
  end

  defp validate_events(events) do
    invalid = Enum.find(events, fn e -> not valid_event?(e) end)

    if is_nil(invalid) do
      :ok
    else
      {:error, "invalid event shape: #{inspect(invalid)}"}
    end
  end

  defp valid_event?(%{type: t, value: v, occurred_at: %Date{}})
       when is_binary(t) and t != "" and is_number(v),
       do: true

  defp valid_event?(_), do: false

  defp compute_stats(events) do
    count = length(events)
    total = Enum.reduce(events, 0, fn e, acc -> acc + e.value end)
    average = if count > 0, do: total / count, else: 0.0
    %{count: count, total: total, average: average}
  end

  defp merge_stats(a, b) do
    count = a.count + b.count
    total = a.total + b.total
    average = if count > 0, do: total / count, else: 0.0
    %{count: count, total: total, average: average}
  end
end
```
