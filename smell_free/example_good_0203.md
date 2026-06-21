# File: `example_good_203.md`

```elixir
defmodule Products.VariantMatrix do
  @moduledoc """
  Builds and validates the full matrix of product variant combinations
  from a set of option axes (e.g. Size × Colour × Material).

  All operations are pure; no database access occurs here. The caller
  is responsible for persisting generated variant records.
  """

  @type option_name :: String.t()
  @type option_value :: String.t()
  @type axis :: %{required(:name) => option_name(), required(:values) => [option_value()]}
  @type combination :: %{option_name() => option_value()}

  @type matrix_result ::
          {:ok, [combination()]}
          | {:error, :no_axes}
          | {:error, :empty_axis_values, option_name()}
          | {:error, :duplicate_axis, option_name()}

  @doc """
  Generates all valid combinations from a list of option axes.

  Returns `{:ok, combinations}` where each combination is a map
  from axis name to the selected value for that axis.

  Returns an error if any axis has no values, axes are duplicated,
  or the axis list is empty.
  """
  @spec build([axis()]) :: matrix_result()
  def build(axes) when is_list(axes) do
    with :ok <- validate_axes(axes) do
      combinations = cartesian_product(axes)
      {:ok, combinations}
    end
  end

  @doc """
  Returns the total number of variant combinations for a set of axes
  without materialising the full list.
  """
  @spec combination_count([axis()]) :: non_neg_integer()
  def combination_count(axes) when is_list(axes) do
    Enum.reduce(axes, 1, fn axis, acc -> acc * length(axis.values) end)
  end

  @doc """
  Filters a list of combinations to those matching all key-value pairs
  in `criteria`. Useful for finding which combinations include a specific
  option value.
  """
  @spec filter([combination()], %{option_name() => option_value()}) :: [combination()]
  def filter(combinations, criteria)
      when is_list(combinations) and is_map(criteria) do
    Enum.filter(combinations, &matches_criteria?(&1, criteria))
  end

  @doc """
  Converts a combination map to a deterministic string key suitable for
  use as a map key or database unique index component.
  """
  @spec combination_key(combination()) :: String.t()
  def combination_key(combination) when is_map(combination) do
    combination
    |> Enum.sort_by(fn {k, _v} -> k end)
    |> Enum.map_join("/", fn {k, v} -> "#{k}:#{v}" end)
  end

  @doc """
  Identifies combinations present in `existing` but absent from `expected`,
  typically used to detect variants that were removed from a product's axes.
  """
  @spec removed_combinations([combination()], [combination()]) :: [combination()]
  def removed_combinations(existing, expected)
      when is_list(existing) and is_list(expected) do
    expected_keys = MapSet.new(expected, &combination_key/1)
    Enum.reject(existing, fn combo -> MapSet.member?(expected_keys, combination_key(combo)) end)
  end

  defp validate_axes([]), do: {:error, :no_axes}

  defp validate_axes(axes) do
    axes
    |> check_for_duplicates()
    |> check_for_empty_values()
  end

  defp check_for_duplicates(axes) do
    names = Enum.map(axes, & &1.name)
    duplicate = find_duplicate(names)

    case duplicate do
      nil -> {:ok, axes}
      name -> {:error, :duplicate_axis, name}
    end
  end

  defp check_for_empty_values({:error, _} = error), do: error

  defp check_for_empty_values({:ok, axes}) do
    case Enum.find(axes, fn axis -> axis.values == [] end) do
      nil -> :ok
      axis -> {:error, :empty_axis_values, axis.name}
    end
  end

  defp cartesian_product([]), do: [%{}]

  defp cartesian_product([axis | rest]) do
    tail_combinations = cartesian_product(rest)

    Enum.flat_map(axis.values, fn value ->
      Enum.map(tail_combinations, fn combo ->
        Map.put(combo, axis.name, value)
      end)
    end)
  end

  defp matches_criteria?(combination, criteria) do
    Enum.all?(criteria, fn {key, value} ->
      Map.get(combination, key) == value
    end)
  end

  defp find_duplicate(list) do
    list
    |> Enum.reduce_while({MapSet.new(), nil}, fn item, {seen, _dup} ->
      if MapSet.member?(seen, item) do
        {:halt, {seen, item}}
      else
        {:cont, {MapSet.put(seen, item), nil}}
      end
    end)
    |> elem(1)
  end
end
```
