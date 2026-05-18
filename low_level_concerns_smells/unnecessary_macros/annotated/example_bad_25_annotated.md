# Annotated Example 25 — Unnecessary Macros

## Metadata

- **Smell name:** Unnecessary macros
- **Expected smell location:** `defmacro generate_reference/1` inside `Logistics.ReferenceUtils`
- **Affected function(s):** `generate_reference/1`
- **Short explanation:** The macro builds a reference string from a runtime prefix by generating random bytes and encoding them — all runtime I/O and string operations. A regular function is the correct abstraction; macros exist to transform code at compile time, not to produce random runtime values.

---

```elixir
defmodule Logistics.ReferenceUtils do
  @moduledoc """
  Reference number generation utilities for logistics entities such as
  shipments, purchase orders, and returns. Ensures consistent formatting
  across all outbound and inbound document identifiers.
  """

  @reference_byte_length 6

  # VALIDATION: SMELL START - Unnecessary macros
  # VALIDATION: This is a smell because generate_reference/1 calls
  # :crypto.strong_rand_bytes/1 and Base.encode16/2 at runtime to build a
  # string. Random number generation is inherently a runtime side-effect and
  # cannot be computed at compile time. A def function is the only correct
  # choice here; the macro adds complexity with zero benefit.
  defmacro generate_reference(prefix) do
    quote do
      suffix =
        :crypto.strong_rand_bytes(unquote(@reference_byte_length))
        |> Base.encode16(case: :upper)

      "#{unquote(prefix)}-#{suffix}"
    end
  end
  # VALIDATION: SMELL END

  @doc """
  Validates that a reference string matches the expected format.
  Format: `<PREFIX>-<12 uppercase hex chars>`
  """
  @spec valid_reference?(String.t()) :: boolean()
  def valid_reference?(ref) when is_binary(ref) do
    Regex.match?(~r/^[A-Z]{2,8}-[A-F0-9]{12}$/, ref)
  end

  @doc """
  Extracts the prefix portion from a well-formed reference string.
  """
  @spec extract_prefix(String.t()) :: {:ok, String.t()} | {:error, :invalid_reference}
  def extract_prefix(ref) when is_binary(ref) do
    case String.split(ref, "-", parts: 2) do
      [prefix, _suffix] when byte_size(prefix) >= 2 -> {:ok, prefix}
      _ -> {:error, :invalid_reference}
    end
  end
end

defmodule Logistics.DocumentService do
  @moduledoc """
  Creates and manages logistics documents such as shipment orders,
  return merchandise authorisations (RMAs), and purchase orders.
  Each document type has a dedicated prefix for its reference number.
  """

  require Logistics.ReferenceUtils

  alias Logistics.ReferenceUtils

  @shipment_prefix "SHP"
  @rma_prefix "RMA"
  @po_prefix "PO"
  @transfer_prefix "TRF"

  @doc """
  Creates a new outbound shipment document from a request map.
  """
  @spec create_shipment(map()) :: {:ok, map()} | {:error, String.t()}
  def create_shipment(%{origin: origin, destination: destination, items: items} = _request) do
    if Enum.empty?(items) do
      {:error, "Shipment must contain at least one item"}
    else
      {:ok, %{
        reference: ReferenceUtils.generate_reference(@shipment_prefix),
        type: :shipment,
        origin: origin,
        destination: destination,
        items: items,
        item_count: length(items),
        status: :pending,
        created_at: DateTime.utc_now()
      }}
    end
  end

  @doc """
  Creates a Return Merchandise Authorisation for a list of items.
  """
  @spec create_rma(map()) :: {:ok, map()} | {:error, String.t()}
  def create_rma(%{customer_id: customer_id, reason: reason, items: items}) do
    if Enum.empty?(items) do
      {:error, "RMA must contain at least one item"}
    else
      {:ok, %{
        reference: ReferenceUtils.generate_reference(@rma_prefix),
        type: :rma,
        customer_id: customer_id,
        reason: reason,
        items: items,
        status: :awaiting_return,
        created_at: DateTime.utc_now()
      }}
    end
  end

  @doc """
  Creates a purchase order for a supplier.
  """
  @spec create_purchase_order(map()) :: {:ok, map()} | {:error, String.t()}
  def create_purchase_order(%{supplier_id: supplier_id, lines: lines, expected_delivery: delivery}) do
    if Enum.empty?(lines) do
      {:error, "Purchase order must contain at least one line"}
    else
      {:ok, %{
        reference: ReferenceUtils.generate_reference(@po_prefix),
        type: :purchase_order,
        supplier_id: supplier_id,
        lines: lines,
        line_count: length(lines),
        expected_delivery: delivery,
        status: :draft,
        created_at: DateTime.utc_now()
      }}
    end
  end

  @doc """
  Creates an internal stock transfer document between two warehouse locations.
  """
  @spec create_transfer(map()) :: {:ok, map()}
  def create_transfer(%{from_warehouse: from, to_warehouse: to, items: items}) do
    {:ok, %{
      reference: ReferenceUtils.generate_reference(@transfer_prefix),
      type: :transfer,
      from_warehouse: from,
      to_warehouse: to,
      items: items,
      status: :in_progress,
      created_at: DateTime.utc_now()
    }}
  end

  @doc """
  Returns a display-friendly summary line for any document map.
  """
  @spec summary_line(map()) :: String.t()
  def summary_line(%{reference: ref, type: type, status: status, created_at: ts}) do
    "[#{DateTime.to_date(ts)}] #{type |> Atom.to_string() |> String.upcase()} #{ref} — #{status}"
  end
end
```
