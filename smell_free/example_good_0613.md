# File: `example_good_613.md`

```elixir
defmodule Analytics.AttributionModel do
  @moduledoc """
  Computes marketing attribution weights for conversion paths using
  multiple configurable attribution models.

  Attribution distributes conversion credit across the touchpoints
  a user encountered before converting. All models are pure functions
  operating on ordered touchpoint lists.
  """

  @type channel :: String.t()
  @type weight :: float()

  @type touchpoint :: %{
          required(:channel) => channel(),
          required(:occurred_at) => DateTime.t(),
          optional(:cost_cents) => non_neg_integer()
        }

  @type attribution :: %{channel() => weight()}

  @type model ::
          :first_touch
          | :last_touch
          | :linear
          | :time_decay
          | {:position_based, first: float(), last: float()}

  @doc """
  Distributes conversion credit across `touchpoints` using `model`.

  Returns a map of channel to weight, where weights sum to 1.0.
  Returns an empty map for an empty touchpoint list.
  """
  @spec attribute([touchpoint()], model()) :: attribution()
  def attribute([], _model), do: %{}

  def attribute(touchpoints, :first_touch) when is_list(touchpoints) do
    first = List.first(touchpoints)
    Map.new(touchpoints, fn tp ->
      {tp.channel, if(tp == first, do: 1.0, else: 0.0)}
    end)
    |> combine_channels()
  end

  def attribute(touchpoints, :last_touch) when is_list(touchpoints) do
    last = List.last(touchpoints)
    Map.new(touchpoints, fn tp ->
      {tp.channel, if(tp == last, do: 1.0, else: 0.0)}
    end)
    |> combine_channels()
  end

  def attribute(touchpoints, :linear) when is_list(touchpoints) do
    weight = 1.0 / length(touchpoints)
    touchpoints
    |> Enum.map(fn tp -> {tp.channel, weight} end)
    |> Enum.reduce(%{}, fn {channel, w}, acc ->
      Map.update(acc, channel, w, &(&1 + w))
    end)
  end

  def attribute(touchpoints, :time_decay) when is_list(touchpoints) do
    last_ts = List.last(touchpoints).occurred_at
    half_life_seconds = 7 * 86_400

    raw_weights =
      Enum.map(touchpoints, fn tp ->
        age_seconds = DateTime.diff(last_ts, tp.occurred_at, :second)
        decay = :math.pow(0.5, age_seconds / half_life_seconds)
        {tp.channel, decay}
      end)

    total = raw_weights |> Enum.map(&elem(&1, 1)) |> Enum.sum()

    raw_weights
    |> Enum.reduce(%{}, fn {channel, w}, acc ->
      Map.update(acc, channel, w / total, &(&1 + w / total))
    end)
  end

  def attribute(touchpoints, {:position_based, first: first_weight, last: last_weight})
      when is_list(touchpoints) and length(touchpoints) >= 2 do
    middle_weight = (1.0 - first_weight - last_weight) / max(length(touchpoints) - 2, 1)

    touchpoints
    |> Enum.with_index()
    |> Enum.map(fn {tp, idx} ->
      weight =
        cond do
          idx == 0 -> first_weight
          idx == length(touchpoints) - 1 -> last_weight
          true -> middle_weight
        end

      {tp.channel, weight}
    end)
    |> Enum.reduce(%{}, fn {channel, w}, acc ->
      Map.update(acc, channel, w, &(&1 + w))
    end)
  end

  def attribute([single], {:position_based, first: _, last: _}) do
    %{single.channel => 1.0}
  end

  @doc """
  Converts an attribution map to a list of `{channel, weight}` tuples
  sorted by weight descending.
  """
  @spec rank(attribution()) :: [{channel(), weight()}]
  def rank(attribution) when is_map(attribution) do
    attribution
    |> Enum.sort_by(&elem(&1, 1), :desc)
  end

  @doc """
  Computes weighted return on ad spend (ROAS) for each channel given
  attribution weights and total touchpoint costs.
  """
  @spec roas([touchpoint()], attribution(), pos_integer()) :: %{channel() => float()}
  def roas(touchpoints, attribution, conversion_value_cents)
      when is_list(touchpoints) and is_integer(conversion_value_cents) and conversion_value_cents > 0 do
    costs_by_channel =
      Enum.reduce(touchpoints, %{}, fn tp, acc ->
        cost = Map.get(tp, :cost_cents, 0)
        Map.update(acc, tp.channel, cost, &(&1 + cost))
      end)

    Map.new(attribution, fn {channel, weight} ->
      attributed_value = conversion_value_cents * weight
      cost = Map.get(costs_by_channel, channel, 0)
      roas_value = if cost > 0, do: Float.round(attributed_value / cost, 4), else: nil
      {channel, roas_value}
    end)
  end

  defp combine_channels(weight_map) do
    Enum.reduce(weight_map, %{}, fn {channel, w}, acc ->
      Map.update(acc, channel, w, &(&1 + w))
    end)
  end
end
```
