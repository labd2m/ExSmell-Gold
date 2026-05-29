# Annotated Example 27 — Long Parameter List

## Metadata

| Field | Value |
|---|---|
| **Smell name** | Long Parameter List |
| **Expected smell location** | `Shipping.Labels.create_label/12` |
| **Affected function(s)** | `create_label/12` |
| **Explanation** | The function accepts 12 individual parameters: sender details (sender_name, sender_phone), sender address (from_street, from_city, from_zip, from_country), recipient address (to_street, to_city, to_zip, to_country), and parcel properties (weight_kg, service_level). Twelve positional arguments is severely above the threshold and clearly deserves at least `%Address{}` and `%Parcel{}` groupings. |

---

```elixir
# VALIDATION: SMELL START - Long Parameter List
# VALIDATION: This is a smell because `create_label/12` takes twelve
# individual positional parameters. The origin contact details (sender_name,
# sender_phone), origin address (from_street, from_city, from_zip,
# from_country), destination address (to_street, to_city, to_zip,
# to_country), and parcel options (weight_kg, service_level) are all
# threaded through a single flat signature. With twelve arguments, even
# experienced developers will need to consult the function signature
# every time they call it, which is a clear sign of a parameter list
# that has grown out of control.
defmodule Shipping.Labels do
  @moduledoc """
  Generates and stores shipping labels by calling the carrier label API,
  supporting multiple service levels and international shipments.
  """

  require Logger

  alias Shipping.Repo
  alias Shipping.Schemas.Label
  alias Shipping.CarrierAPI
  alias Shipping.PDFStore

  @valid_service_levels ~w(standard express overnight economy)
  @max_weight_kg 70.0

  def create_label(
        sender_name,
        sender_phone,
        from_street,
        from_city,
        from_zip,
        from_country,
        to_street,
        to_city,
        to_zip,
        to_country,
        weight_kg,
        service_level
      ) do
# VALIDATION: SMELL END
    origin = %{
      name: sender_name,
      phone: sender_phone,
      street: from_street,
      city: from_city,
      zip: from_zip,
      country: from_country
    }

    destination = %{
      street: to_street,
      city: to_city,
      zip: to_zip,
      country: to_country
    }

    with :ok <- validate_address(origin, :origin),
         :ok <- validate_address(destination, :destination),
         :ok <- validate_weight(weight_kg),
         :ok <- validate_service_level(service_level) do
      carrier_request = %{
        sender: origin,
        recipient: destination,
        weight_kg: weight_kg,
        service: service_level
      }

      case CarrierAPI.request_label(carrier_request) do
        {:ok, %{tracking_number: tracking, label_pdf_url: pdf_url}} ->
          local_pdf_path = PDFStore.download_and_store(pdf_url, tracking)

          label_attrs = %{
            sender_name: sender_name,
            from_city: from_city,
            from_country: from_country,
            to_city: to_city,
            to_country: to_country,
            weight_kg: weight_kg,
            service_level: service_level,
            tracking_number: tracking,
            pdf_path: local_pdf_path,
            status: :ready,
            inserted_at: DateTime.utc_now()
          }

          {:ok, label} = Repo.insert(Label.changeset(%Label{}, label_attrs))
          Logger.info("Label #{label.id} created, tracking=#{tracking}")
          {:ok, label}

        {:error, reason} ->
          Logger.error("Label API error: #{inspect(reason)}")
          {:error, :label_generation_failed}
      end
    end
  end

  defp validate_address(%{street: s, city: c, zip: z, country: co}, label) do
    cond do
      blank?(s) -> {:error, {label, :missing_street}}
      blank?(c) -> {:error, {label, :missing_city}}
      blank?(z) -> {:error, {label, :missing_zip}}
      String.length(co) != 2 -> {:error, {label, :invalid_country_code}}
      true -> :ok
    end
  end

  defp blank?(v), do: is_nil(v) or String.trim(v) == ""

  defp validate_weight(w) when is_float(w) and w > 0 and w <= @max_weight_kg, do: :ok
  defp validate_weight(w) when is_integer(w) and w > 0 and w <= @max_weight_kg, do: :ok
  defp validate_weight(_), do: {:error, :invalid_weight}

  defp validate_service_level(s) when s in @valid_service_levels, do: :ok
  defp validate_service_level(s), do: {:error, {:unknown_service_level, s}}
end
```
