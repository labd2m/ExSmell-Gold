```elixir
defmodule Sampling.WeightedReservoir do
  @moduledoc """
  Implements Algorithm A-Res (Weighted Reservoir Sampling) for drawing a
  representative sample of size `k` from a potentially infinite stream
  without loading the full dataset into memory. Items with higher weights
  are proportionally more likely to appear in the sample. The algorithm
  processes each item in O(log k) time and uses O(k) memory, making it
  suitable for sampling very large datasets or live event streams.

  Reference: Efraimidis & Spirakis, "Weighted random sampling with a
  reservoir" (2006).
  """

  @type weight :: pos_integer() | float()
  @type item :: term()
  @type sample_entry :: %{item: item(), key: float()}

  @doc """
  Draws a weighted random sample of at most `k` items from `enumerable`.
  Each element must be a `{item, weight}` tuple with a positive weight.
  Returns a list of sampled items (without weights) of length `min(k, n)`.
  """
  @spec sample(Enumerable.t(), pos_integer()) :: [item()]
  def sample(enumerable, k) when is_integer(k) and k > 0 do
    enumerable
    |> Enum.reduce({[], 0}, fn {item, weight}, {reservoir, size} ->
      key = compute_key(weight)

      cond do
        size < k ->
          entry = %{item: item, key: key}
          {insert_sorted(reservoir, entry), size + 1}

        key > min_key(reservoir) ->
          entry = %{item: item, key: key}
          updated = reservoir |> drop_min() |> insert_sorted(entry)
          {updated, size}

        true ->
          {reservoir, size}
      end
    end)
    |> elem(0)
    |> Enum.map(& &1.item)
  end

  @doc """
  Samples a single item from `enumerable` using weighted probabilities.
  Returns `{:ok, item}` or `{:error, :empty}`.
  """
  @spec sample_one(Enumerable.t()) :: {:ok, item()} | {:error, :empty}
  def sample_one(enumerable) do
    case sample(enumerable, 1) do
      [item] -> {:ok, item}
      [] -> {:error, :empty}
    end
  end

  @doc """
  Normalises a list of `{item, weight}` pairs so weights sum to 1.0,
  then samples `k` items. Useful when weights are raw frequencies or counts.
  """
  @spec sample_normalised([{item(), weight()}], pos_integer()) :: [item()]
  def sample_normalised(items, k) when is_list(items) and is_integer(k) and k > 0 do
    total = items |> Enum.map(&elem(&1, 1)) |> Enum.sum()

    if total == 0 do
      []
    else
      normalised = Enum.map(items, fn {item, w} -> {item, w / total} end)
      sample(normalised, k)
    end
  end

  @doc """
  Returns the probability that each item in `items` would appear in a sample
  of size `k`. Useful for auditing sampling bias.
  """
  @spec inclusion_probabilities([{item(), weight()}], pos_integer()) ::
          [{item(), float()}]
  def inclusion_probabilities(items, k) when is_list(items) and is_integer(k) and k > 0 do
    total_weight = items |> Enum.map(&elem(&1, 1)) |> Enum.sum()
    n = length(items)

    Enum.map(items, fn {item, weight} ->
      probability =
        if n <= k do
          1.0
        else
          min(1.0, k * weight / total_weight)
        end

      {item, Float.round(probability, 6)}
    end)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp compute_key(weight) when is_number(weight) and weight > 0 do
    u = :rand.uniform()
    :math.pow(u, 1.0 / weight)
  end

  defp insert_sorted(reservoir, entry) do
    Enum.sort_by([entry | reservoir], & &1.key, :desc)
  end

  defp min_key([]), do: 0.0
  defp min_key(reservoir), do: List.last(reservoir).key

  defp drop_min([]), do: []
  defp drop_min([_ | rest]), do: rest
  defp drop_min(reservoir) when is_list(reservoir) do
    List.delete_at(reservoir, -1)
  end
end
```
