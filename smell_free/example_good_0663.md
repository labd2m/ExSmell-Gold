```elixir
defmodule MyApp.Catalog.VariantMatrix do
  @moduledoc """
  Builds a structured variant matrix from a product's option definitions
  and variant records. The matrix maps every combination of option values
  to its corresponding variant, enabling storefront UIs to efficiently
  resolve "which variant corresponds to size=L, colour=blue?" without
  scanning all variants on every user interaction.

  All functions are purely functional with no I/O.
  """

  @type option_name :: String.t()
  @type option_value :: String.t()
  @type option_combo :: %{option_name() => option_value()}
  @type variant_id :: String.t()

  @type option_def :: %{
          required(:name) => option_name(),
          required(:values) => [option_value()]
        }

  @type variant :: %{
          required(:id) => variant_id(),
          required(:options) => option_combo(),
          required(:price_cents) => pos_integer(),
          required(:available) => boolean()
        }

  @type matrix_entry :: %{
          variant_id: variant_id(),
          price_cents: pos_integer(),
          available: boolean()
        }

  @doc """
  Builds a lookup matrix from `option_defs` and `variants`.
  Returns a map keyed by sorted option combination strings for O(1) lookup.
  """
  @spec build([option_def()], [variant()]) :: %{String.t() => matrix_entry()}
  def build(option_defs, variants)
      when is_list(option_defs) and is_list(variants) do
    Map.new(variants, fn variant ->
      key = combo_key(variant.options, option_defs)
      entry = %{
        variant_id: variant.id,
        price_cents: variant.price_cents,
        available: variant.available
      }
      {key, entry}
    end)
  end

  @doc """
  Looks up the matrix entry for the given `selected_options` map.
  Returns `{:ok, entry}` or `{:error, :not_found}`.
  """
  @spec lookup(%{String.t() => matrix_entry()}, option_combo(), [option_def()]) ::
          {:ok, matrix_entry()} | {:error, :not_found}
  def lookup(matrix, selected_options, option_defs) do
    key = combo_key(selected_options, option_defs)

    case Map.get(matrix, key) do
      nil -> {:error, :not_found}
      entry -> {:ok, entry}
    end
  end

  @doc """
  Returns a map of option names to their available values, given the
  currently selected options. Values whose selection would result in no
  available variant are excluded.
  """
  @spec available_options(%{String.t() => matrix_entry()}, option_combo(), [option_def()]) ::
          %{option_name() => [option_value()]}
  def available_options(matrix, selected, option_defs) do
    Map.new(option_defs, fn opt_def ->
      available =
        Enum.filter(opt_def.values, fn candidate ->
          merged = Map.put(selected, opt_def.name, candidate)
          key = combo_key(merged, option_defs)

          case Map.get(matrix, key) do
            nil -> false
            entry -> entry.available
          end
        end)

      {opt_def.name, available}
    end)
  end

  @doc "Returns all option combinations as a flat list of maps."
  @spec all_combinations([option_def()]) :: [option_combo()]
  def all_combinations([]), do: [%{}]

  def all_combinations([opt | rest]) do
    for value <- opt.values, combo <- all_combinations(rest) do
      Map.put(combo, opt.name, value)
    end
  end

  @spec combo_key(option_combo(), [option_def()]) :: String.t()
  defp combo_key(options, option_defs) do
    option_defs
    |> Enum.map(fn opt -> "#{opt.name}=#{Map.get(options, opt.name, "")}" end)
    |> Enum.join("|")
  end
end
```
