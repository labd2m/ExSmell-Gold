```elixir
defmodule Analytics.EventSampler do
  @moduledoc """
  Samples high-volume analytics events before forwarding them to the
  storage pipeline. Each event type has a configurable sample rate
  between 0.0 and 1.0. Sampling decisions are deterministic per user ID
  so a given user is consistently included or excluded across event types,
  producing coherent per-user analytics rather than random gaps.
  """

  @type event_type :: String.t()
  @type user_id :: String.t()
  @type event :: %{type: event_type(), user_id: user_id(), payload: map()}
  @type sample_rate :: float()
  @type rates :: %{event_type() => sample_rate()}

  @default_rate 1.0

  @doc """
  Returns true when `event` should be kept given `rates`. Uses a
  deterministic hash of the user ID so sampling is consistent per user.
  """
  @spec keep?(event(), rates()) :: boolean()
  def keep?(%{type: type, user_id: user_id}, rates) when is_map(rates) do
    rate = Map.get(rates, type, @default_rate)
    sample_rate_permits?(user_id, rate)
  end

  @doc """
  Filters a list of events using `rates`. Returns the subset of events
  that pass the sampling filter along with sampling statistics.
  """
  @spec filter([event()], rates()) :: %{kept: [event()], dropped: non_neg_integer()}
  def filter(events, rates) when is_list(events) and is_map(rates) do
    {kept, dropped} =
      Enum.reduce(events, {[], 0}, fn event, {kept_acc, dropped_count} ->
        if keep?(event, rates) do
          {[event | kept_acc], dropped_count}
        else
          {kept_acc, dropped_count + 1}
        end
      end)

    %{kept: Enum.reverse(kept), dropped: dropped}
  end

  @doc """
  Returns the effective sample rate for `event_type` given `rates`.
  Falls back to the default rate of 1.0 for unregistered event types.
  """
  @spec effective_rate(event_type(), rates()) :: sample_rate()
  def effective_rate(event_type, rates) when is_binary(event_type) and is_map(rates) do
    Map.get(rates, event_type, @default_rate)
  end

  @doc """
  Computes the expected throughput after sampling. Returns events-per-second
  estimates for each configured event type.
  """
  @spec expected_throughput(%{event_type() => float()}, rates()) ::
          %{event_type() => float()}
  def expected_throughput(volume_per_second, rates)
      when is_map(volume_per_second) and is_map(rates) do
    Map.new(volume_per_second, fn {type, volume} ->
      rate = effective_rate(type, rates)
      {type, Float.round(volume * rate, 2)}
    end)
  end

  @doc "Merges two rate maps, taking the minimum rate for overlapping event types."
  @spec merge_conservative(rates(), rates()) :: rates()
  def merge_conservative(rates_a, rates_b) when is_map(rates_a) and is_map(rates_b) do
    all_keys = MapSet.union(MapSet.new(Map.keys(rates_a)), MapSet.new(Map.keys(rates_b)))

    Map.new(all_keys, fn key ->
      rate_a = Map.get(rates_a, key, @default_rate)
      rate_b = Map.get(rates_b, key, @default_rate)
      {key, min(rate_a, rate_b)}
    end)
  end

  defp sample_rate_permits?(_user_id, 1.0), do: true
  defp sample_rate_permits?(_user_id, 0.0), do: false

  defp sample_rate_permits?(user_id, rate)
       when is_float(rate) and rate > 0.0 and rate < 1.0 do
    bucket = :erlang.phash2(user_id, 10_000)
    bucket < round(rate * 10_000)
  end
end
```
