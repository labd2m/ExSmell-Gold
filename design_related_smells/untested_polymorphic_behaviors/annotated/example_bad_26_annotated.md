# Annotated Bad Example 26: Untested Polymorphic Behaviors

## Metadata

- **Smell name**: Untested Polymorphic Behaviors
- **Expected smell location**: `Shipping.ManifestBuilder.format_weight/1`
- **Affected function(s)**: `format_weight/1`
- **Short explanation**: The function calls `to_string/1` on `weight` and then appends a unit suffix, with no guard clause restricting the type. While `Decimal`, `Float`, and `Integer` all implement `String.Chars`, passing a `Map` or `List` raises `Protocol.UndefinedError`. More problematically, `Float` produces scientific notation for large or very small values (e.g., `"1.0e4 kg"`), which will fail downstream parsing in customs and carrier systems. The function should guard with `is_number(weight)` or accept only `Decimal` structs to ensure deterministic output.

## Code

```elixir
defmodule Shipping.ManifestBuilder do
  @moduledoc """
  Builds shipping manifests for carrier API submissions and customs declarations.
  Handles weight formatting, address normalization, parcel dimension encoding,
  and manifest line serialization for international shipments.
  """

  @weight_unit "kg"
  @dimension_unit "cm"
  @max_description_length 35
  @max_line_items 99

  @doc """
  Builds a complete manifest map for a shipment.
  """
  def build_manifest(%{
        shipment_id: id,
        sender: sender,
        recipient: recipient,
        parcels: parcels
      })
      when is_binary(id) and is_map(sender) and is_map(recipient) and is_list(parcels) do
    %{
      manifest_id: generate_manifest_id(),
      shipment_ref: id,
      sender: normalize_address(sender),
      recipient: normalize_address(recipient),
      line_items: build_line_items(parcels),
      total_weight: format_weight(total_weight(parcels)),
      parcel_count: length(parcels),
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  @doc """
  Formats a weight value with its unit suffix for carrier submission.

  ## Examples

      iex> Shipping.ManifestBuilder.format_weight(2.5)
      "2.5 kg"

      iex> Shipping.ManifestBuilder.format_weight(10)
      "10 kg"
  """
  # VALIDATION: SMELL START - Untested Polymorphic Behaviors
  # VALIDATION: This is a smell because `to_string/1` is called on `weight`
  # without any guard clause. The `String.Chars` protocol is not implemented for
  # `Map`, `List`, or `Tuple`, so those types raise `Protocol.UndefinedError` at
  # runtime. More critically, `Float` values may produce scientific notation for
  # very large or very small numbers (e.g., `"1.0e4 kg"`), which will fail
  # validation in carrier and customs APIs that expect decimal notation. The
  # function should use `is_number(weight)` as a guard and format floats with
  # explicit decimal precision rather than relying on `to_string/1`.
  def format_weight(weight) do
    "#{to_string(weight)} #{@weight_unit}"
  end
  # VALIDATION: SMELL END

  @doc """
  Formats a dimension value with its unit suffix.
  """
  def format_dimension(dim) when is_number(dim) do
    "#{dim} #{@dimension_unit}"
  end

  @doc """
  Normalizes a postal address map to the canonical fields required by carriers.
  """
  def normalize_address(%{
        name: name,
        street: street,
        city: city,
        postal_code: postal_code,
        country_code: country_code
      })
      when is_binary(name) and is_binary(street) and is_binary(city) and
             is_binary(postal_code) and is_binary(country_code) do
    %{
      name: String.upcase(name),
      street: String.trim(street),
      city: String.upcase(city),
      postal_code: String.replace(postal_code, " ", ""),
      country_code: String.upcase(country_code)
    }
  end

  @doc """
  Builds the line item list for the manifest from a list of parcel maps.
  """
  def build_line_items(parcels) when is_list(parcels) do
    parcels
    |> Enum.take(@max_line_items)
    |> Enum.with_index(1)
    |> Enum.map(fn {parcel, idx} ->
      %{
        line_number: idx,
        description: truncate_description(parcel.description),
        quantity: parcel.quantity,
        weight: format_weight(parcel.weight),
        hs_code: Map.get(parcel, :hs_code, "")
      }
    end)
  end

  @doc """
  Computes the total weight across all parcels.
  """
  def total_weight(parcels) when is_list(parcels) do
    Enum.reduce(parcels, 0, fn p, acc -> acc + p.weight end)
  end

  defp truncate_description(desc) when is_binary(desc) do
    if String.length(desc) > @max_description_length do
      String.slice(desc, 0, @max_description_length)
    else
      desc
    end
  end

  defp generate_manifest_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16()
  end
end
```
