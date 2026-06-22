```elixir
defmodule Shipping.ManifestBuilder do
  @moduledoc """
  Builds structured shipping manifests from a list of parcels destined for
  the same carrier pickup. A manifest groups parcels by service class,
  computes aggregate weights and dimensions, and produces the carrier-ready
  data structure. All logic is pure; no database or network calls are made.
  """

  @type dimensions :: %{length_cm: float(), width_cm: float(), height_cm: float()}
  @type service_class :: :standard | :express | :overnight
  @type parcel :: %{
          tracking_number: String.t(),
          weight_grams: pos_integer(),
          dimensions: dimensions(),
          service_class: service_class(),
          recipient: map()
        }

  @type group :: %{
          service_class: service_class(),
          parcel_count: pos_integer(),
          total_weight_grams: non_neg_integer(),
          parcels: [parcel()]
        }

  @type manifest :: %{
          manifest_id: String.t(),
          created_at: DateTime.t(),
          parcel_count: non_neg_integer(),
          total_weight_grams: non_neg_integer(),
          groups: [group()]
        }

  @doc """
  Builds a manifest from `parcels`. Groups by service class, ordered
  from most to least time-sensitive.
  """
  @spec build([parcel()]) :: {:ok, manifest()} | {:error, :no_parcels}
  def build([]), do: {:error, :no_parcels}

  def build(parcels) when is_list(parcels) do
    groups =
      parcels
      |> Enum.group_by(& &1.service_class)
      |> Enum.map(fn {service, group_parcels} -> build_group(service, group_parcels) end)
      |> Enum.sort_by(&service_priority(&1.service_class))

    manifest = %{
      manifest_id: generate_id(),
      created_at: DateTime.utc_now(),
      parcel_count: length(parcels),
      total_weight_grams: Enum.sum_by(parcels, & &1.weight_grams),
      groups: groups
    }

    {:ok, manifest}
  end

  @doc "Returns the volumetric weight in grams using the standard 5000 cc/kg divisor."
  @spec volumetric_weight_grams(dimensions()) :: non_neg_integer()
  def volumetric_weight_grams(%{length_cm: l, width_cm: w, height_cm: h}) do
    round(l * w * h / 5_000 * 1_000)
  end

  @doc "Returns the billable weight: the greater of actual and volumetric weight."
  @spec billable_weight_grams(parcel()) :: non_neg_integer()
  def billable_weight_grams(%{weight_grams: actual, dimensions: dims}) do
    max(actual, volumetric_weight_grams(dims))
  end

  @doc "Returns a summary string for the manifest suitable for logging."
  @spec summarise(manifest()) :: String.t()
  def summarise(%{manifest_id: id, parcel_count: count, total_weight_grams: weight}) do
    kg = Float.round(weight / 1_000, 2)
    "[Manifest #{id}] #{count} parcel(s), #{kg}kg total"
  end

  defp build_group(service_class, parcels) do
    %{
      service_class: service_class,
      parcel_count: length(parcels),
      total_weight_grams: Enum.sum_by(parcels, & &1.weight_grams),
      parcels: parcels
    }
  end

  defp service_priority(:overnight), do: 0
  defp service_priority(:express), do: 1
  defp service_priority(:standard), do: 2

  defp generate_id do
    :crypto.strong_rand_bytes(6) |> Base.encode16()
  end
end
```
