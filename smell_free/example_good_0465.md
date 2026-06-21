```elixir
defmodule MyApp.Shipping.LabelPrinter do
  @moduledoc """
  Generates and stores shipping labels by calling a carrier's label API,
  persisting the resulting PDF to object storage, and recording the label
  metadata in the `shipping_labels` table. Labels are idempotent per
  shipment: re-calling `print/1` for a shipment that already has a label
  returns the existing record rather than issuing a duplicate API call.
  """

  require Logger

  alias MyApp.Repo
  alias MyApp.Shipping.{Shipment, ShippingLabel}
  alias MyApp.Shipping.Adapters
  alias MyApp.Storage

  import Ecto.Query, warn: false

  @type label_result :: %{
          tracking_number: String.t(),
          carrier: String.t(),
          label_url: String.t(),
          label_format: String.t()
        }

  @doc """
  Prints a label for `shipment`. Returns an existing label record
  when one was previously generated, or creates a new one by calling
  the carrier API and uploading the PDF to object storage.
  """
  @spec print(Shipment.t()) :: {:ok, ShippingLabel.t()} | {:error, term()}
  def print(%Shipment{} = shipment) do
    case find_existing_label(shipment.id) do
      %ShippingLabel{} = existing -> {:ok, existing}
      nil -> generate_and_store(shipment)
    end
  end

  @doc "Returns the label for `shipment_id` if one exists."
  @spec fetch(String.t()) :: {:ok, ShippingLabel.t()} | {:error, :not_found}
  def fetch(shipment_id) when is_binary(shipment_id) do
    case find_existing_label(shipment_id) do
      nil -> {:error, :not_found}
      label -> {:ok, label}
    end
  end

  @spec generate_and_store(Shipment.t()) :: {:ok, ShippingLabel.t()} | {:error, term()}
  defp generate_and_store(shipment) do
    with {:ok, label_data} <- call_carrier_api(shipment),
         {:ok, label_url} <- upload_pdf(shipment.id, label_data.pdf_bytes),
         {:ok, record} <- persist_label(shipment, label_data, label_url) do
      Logger.info("shipping_label_generated",
        shipment_id: shipment.id,
        tracking: label_data.tracking_number
      )

      {:ok, record}
    end
  end

  @spec call_carrier_api(Shipment.t()) :: {:ok, map()} | {:error, term()}
  defp call_carrier_api(shipment) do
    adapter = Adapters.for_carrier(shipment.carrier)
    adapter.create_label(shipment)
  end

  @spec upload_pdf(String.t(), binary()) :: {:ok, String.t()} | {:error, term()}
  defp upload_pdf(shipment_id, pdf_bytes) do
    key = "shipping_labels/#{shipment_id}.pdf"
    Storage.put(key, pdf_bytes, acl: :private, content_type: "application/pdf")
  end

  @spec persist_label(Shipment.t(), map(), String.t()) ::
          {:ok, ShippingLabel.t()} | {:error, Ecto.Changeset.t()}
  defp persist_label(shipment, label_data, label_url) do
    %ShippingLabel{}
    |> ShippingLabel.changeset(%{
      shipment_id: shipment.id,
      carrier: shipment.carrier,
      tracking_number: label_data.tracking_number,
      label_url: label_url,
      label_format: label_data.format,
      service_code: label_data.service_code,
      printed_at: DateTime.utc_now()
    })
    |> Repo.insert()
  end

  @spec find_existing_label(String.t()) :: ShippingLabel.t() | nil
  defp find_existing_label(shipment_id) do
    ShippingLabel
    |> where([l], l.shipment_id == ^shipment_id)
    |> Repo.one()
  end
end
```
