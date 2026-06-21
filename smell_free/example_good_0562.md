```elixir
defmodule Sampling.Reservoir do
  @moduledoc """
  Implements Vitter's Algorithm R for uniform random sampling from a
  stream of unknown length.

  The reservoir maintains exactly `size` items at all times. Each new
  item from the stream has a `size / stream_position` probability of
  replacing a randomly chosen incumbent. This guarantees that after
  processing the full stream, every item has an equal probability of
  appearing in the reservoir — without holding the entire stream in memory.
  """

  @type t(item) :: %__MODULE__{
          items: [item],
          capacity: pos_integer(),
          seen: non_neg_integer()
        }

  defstruct [:items, :capacity, seen: 0]

  @spec new(pos_integer()) :: t(term())
  def new(capacity) when is_integer(capacity) and capacity > 0 do
    %__MODULE__{items: [], capacity: capacity}
  end

  @spec add(t(item), item) :: t(item) when item: term()
  def add(%__MODULE__{seen: seen, capacity: cap, items: items} = reservoir, item)
      when seen < cap do
    %{reservoir | items: [item | items], seen: seen + 1}
  end

  def add(%__MODULE__{seen: seen, capacity: cap, items: items} = reservoir, item) do
    j = :rand.uniform(seen + 1) - 1

    updated_items =
      if j < cap do
        List.replace_at(items, j, item)
      else
        items
      end

    %{reservoir | items: updated_items, seen: seen + 1}
  end

  @spec add_all(t(item), Enumerable.t()) :: t(item) when item: term()
  def add_all(%__MODULE__{} = reservoir, stream) do
    Enum.reduce(stream, reservoir, &add(&2, &1))
  end

  @spec sample(t(item)) :: [item] when item: term()
  def sample(%__MODULE__{items: items, capacity: cap}) do
    items |> Enum.take(cap) |> Enum.shuffle()
  end

  @spec full?(t(term())) :: boolean()
  def full?(%__MODULE__{seen: seen, capacity: cap}), do: seen >= cap

  @spec fill_ratio(t(term())) :: float()
  def fill_ratio(%__MODULE__{seen: seen, capacity: cap}) do
    min(1.0, seen / cap)
  end

  @spec from_list([term()], pos_integer()) :: t(term())
  def from_list(list, capacity) when is_list(list) do
    new(capacity) |> add_all(list)
  end
end

defmodule Sampling.WeightedReservoir do
  @moduledoc """
  Weighted reservoir sampling where each item carries a non-negative weight.
  Higher-weighted items are proportionally more likely to appear in the sample.
  Uses Algorithm A-Chao for streaming weighted reservoir sampling.
  """

  @type weighted_item(item) :: {item, number()}
  @type t(item) :: %__MODULE__{
          items: [item],
          weights: [number()],
          capacity: pos_integer(),
          total_weight: number()
        }

  defstruct [:items, :capacity, weights: [], total_weight: 0.0]

  @spec new(pos_integer()) :: t(term())
  def new(capacity) when is_integer(capacity) and capacity > 0 do
    %__MODULE__{items: [], capacity: capacity}
  end

  @spec add(t(item), item, number()) :: t(item) when item: term()
  def add(%__MODULE__{items: items, capacity: cap} = r, item, weight)
      when is_number(weight) and weight >= 0 do
    new_total = r.total_weight + weight

    updated =
      if length(items) < cap do
        %{r | items: [item | items], weights: [weight | r.weights], total_weight: new_total}
      else
        j = :rand.uniform(length(items)) - 1
        prob = weight / new_total

        if :rand.uniform() < prob do
          %{r |
            items: List.replace_at(items, j, item),
            weights: List.replace_at(r.weights, j, weight),
            total_weight: new_total
          }
        else
          %{r | total_weight: new_total}
        end
      end

    updated
  end

  @spec sample(t(term())) :: [term()]
  def sample(%__MODULE__{items: items}), do: Enum.shuffle(items)
end
```
