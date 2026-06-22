```elixir
defmodule Accounting.Budgets.AllocationEngine do
  @moduledoc """
  Allocates a total budget across a set of cost centres according to
  weighted distribution rules. All monetary values are in integer cents.
  Weights are normalised internally; callers provide raw relative weights.
  """

  @type centre :: %{id: String.t(), weight: pos_integer()}
  @type allocation :: %{centre_id: String.t(), allocated_cents: non_neg_integer()}
  @type result :: %{
          allocations: [allocation()],
          total_cents: non_neg_integer(),
          remainder_cents: non_neg_integer()
        }

  @doc """
  Distributes `total_cents` across `centres` proportionally by weight.

  Rounding remainders are assigned to the highest-weight centre.
  Returns `{:ok, result}` or `{:error, reason}` on invalid input.
  """
  @spec allocate([centre()], non_neg_integer()) :: {:ok, result()} | {:error, String.t()}
  def allocate(centres, total_cents)
      when is_list(centres) and is_integer(total_cents) and total_cents >= 0 do
    with :ok <- validate_centres(centres),
         {:ok, weight_sum} <- sum_weights(centres) do
      raw_allocations = compute_raw(centres, total_cents, weight_sum)
      floored = floor_allocations(raw_allocations)
      distributed = distribute_remainder(floored, total_cents, centres)
      allocated_total = Enum.reduce(distributed, 0, fn a, acc -> acc + a.allocated_cents end)
      remainder = total_cents - allocated_total

      {:ok, %{allocations: distributed, total_cents: total_cents, remainder_cents: remainder}}
    end
  end

  defp validate_centres([]), do: {:error, "at least one cost centre is required"}

  defp validate_centres(centres) do
    invalid = Enum.find(centres, fn c -> not valid_centre?(c) end)

    if is_nil(invalid) do
      :ok
    else
      {:error, "invalid centre: #{inspect(invalid)}"}
    end
  end

  defp valid_centre?(%{id: id, weight: w})
       when is_binary(id) and id != "" and is_integer(w) and w > 0,
       do: true

  defp valid_centre?(_), do: false

  defp sum_weights(centres) do
    total = Enum.reduce(centres, 0, fn c, acc -> acc + c.weight end)

    if total > 0 do
      {:ok, total}
    else
      {:error, "total weight must be greater than zero"}
    end
  end

  defp compute_raw(centres, total_cents, weight_sum) do
    Enum.map(centres, fn centre ->
      raw = total_cents * centre.weight / weight_sum
      %{centre_id: centre.id, weight: centre.weight, raw: raw}
    end)
  end

  defp floor_allocations(raw_allocations) do
    Enum.map(raw_allocations, fn a ->
      %{centre_id: a.centre_id, weight: a.weight, allocated_cents: floor(a.raw)}
    end)
  end

  defp distribute_remainder(allocations, total_cents, _centres) do
    floored_total = Enum.reduce(allocations, 0, fn a, acc -> acc + a.allocated_cents end)
    remainder = total_cents - floored_total

    if remainder == 0 do
      strip_weights(allocations)
    else
      sorted = Enum.sort_by(allocations, fn a -> a.weight end, :desc)

      {updated, _} =
        Enum.map_reduce(sorted, remainder, fn alloc, rem ->
          if rem > 0 do
            {%{alloc | allocated_cents: alloc.allocated_cents + 1}, rem - 1}
          else
            {alloc, rem}
          end
        end)

      strip_weights(updated)
    end
  end

  defp strip_weights(allocations) do
    Enum.map(allocations, fn a -> Map.take(a, [:centre_id, :allocated_cents]) end)
  end
end
```
