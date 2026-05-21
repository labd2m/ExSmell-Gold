```elixir
defmodule ShipmentLabel do
  @moduledoc """
  Library for generating plain-text shipment labels from logistics data.
  Consumed by warehouse management, courier dispatch, and e-commerce fulfillment services.
  """

  defstruct [
    :tracking_number,
    :sender_name,
    :sender_address,
    :recipient_name,
    :recipient_address,
    :service_class,
    :weight_kg,
    :barcode
  ]

  @type t :: %__MODULE__{
          tracking_number: String.t(),
          sender_name: String.t(),
          sender_address: [String.t()],
          recipient_name: String.t(),
          recipient_address: [String.t()],
          service_class: :standard | :express | :overnight,
          weight_kg: float(),
          barcode: String.t()
        }

  @service_labels %{
    standard: "STANDARD DELIVERY",
    express: "EXPRESS DELIVERY",
    overnight: "OVERNIGHT PRIORITY"
  }

  @doc """
  Builds a formatted plain-text shipment label string.
  The label width and maximum address lines are controlled by
  application-level configuration.
  """
  @spec build(t()) :: String.t()
  def build(%__MODULE__{} = shipment) do
    label_width = Application.fetch_env!(:shipment_label, :label_width)
    max_address_lines = Application.fetch_env!(:shipment_label, :max_address_lines)

    border = String.duplicate("=", label_width)
    thin_border = String.duplicate("-", label_width)
    service_tag = Map.get(@service_labels, shipment.service_class, "DELIVERY")

    sender_lines =
      shipment.sender_address
      |> Enum.take(max_address_lines)
      |> Enum.map(&pad_line(&1, label_width))

    recipient_lines =
      shipment.recipient_address
      |> Enum.take(max_address_lines)
      |> Enum.map(&pad_line(&1, label_width))

    [
      border,
      center_text("SHIPMENT LABEL", label_width),
      center_text(service_tag, label_width),
      thin_border,
      pad_line("FROM: #{shipment.sender_name}", label_width),
      Enum.join(sender_lines, "\n"),
      thin_border,
      pad_line("TO: #{shipment.recipient_name}", label_width),
      Enum.join(recipient_lines, "\n"),
      thin_border,
      pad_line("Tracking: #{shipment.tracking_number}", label_width),
      pad_line("Weight:   #{shipment.weight_kg} kg", label_width),
      thin_border,
      center_text(shipment.barcode, label_width),
      border
    ]
    |> Enum.join("\n")
  end

  @doc "Validates that a shipment struct has all required fields populated."
  @spec valid?(t()) :: boolean()
  def valid?(%__MODULE__{} = s) do
    Enum.all?([s.tracking_number, s.sender_name, s.recipient_name, s.barcode], fn v ->
      is_binary(v) and v != ""
    end) and is_list(s.sender_address) and is_list(s.recipient_address) and
      s.sender_address != [] and s.recipient_address != []
  end

  @doc "Returns the service class as a human-readable string."
  @spec service_description(t()) :: String.t()
  def service_description(%__MODULE__{service_class: sc}) do
    Map.get(@service_labels, sc, "UNKNOWN SERVICE")
  end

  # --- Private helpers ---

  defp pad_line(text, width) do
    String.slice(text, 0, width) |> String.pad_trailing(width)
  end

  defp center_text(text, width) do
    pad = max(div(width - String.length(text), 2), 0)
    String.duplicate(" ", pad) <> text
  end
end
```
