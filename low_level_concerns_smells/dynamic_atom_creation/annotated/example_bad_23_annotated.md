# Annotated Example — Dynamic Atom Creation

| Field | Value |
|---|---|
| **Smell name** | Dynamic atom creation |
| **Expected smell location** | `ERPDataMapper.map_document_type/1`, line where `String.to_atom/1` converts the ERP document type code |
| **Affected function(s)** | `ERPDataMapper.map_document_type/1` |
| **Short explanation** | ERP document type codes are returned as strings by the ERP system's SOAP/REST API and are converted to atoms to drive pattern-matching in downstream processors. ERP systems can have hundreds of document type codes that evolve with business configuration, so this conversion is unbounded in practice. |

```elixir
defmodule MyApp.ERP.ERPDataMapper do
  @moduledoc """
  Maps raw ERP API responses to normalised internal structs.
  Handles purchase orders, sales orders, goods receipts, invoices,
  credit memos, and stock transfer documents from the SAP integration layer.
  """

  require Logger

  alias MyApp.ERP.{Document, LineItem, Party, Amount}

  @supported_doc_types ~w(
    PURCHASE_ORDER
    SALES_ORDER
    GOODS_RECEIPT
    INVOICE
    CREDIT_MEMO
    DEBIT_MEMO
    STOCK_TRANSFER
    RETURN_ORDER
  )

  @doc """
  Maps a raw ERP document map to a normalised `Document` struct.
  """
  @spec map_document(map()) :: {:ok, Document.t()} | {:error, term()}
  def map_document(%{"DocumentNumber" => doc_num, "DocumentType" => doc_type} = raw) do
    Logger.debug("Mapping ERP document", doc_number: doc_num, doc_type: doc_type)

    with {:ok, type_atom} <- map_document_type(doc_type),
         {:ok, line_items} <- map_line_items(raw["Items"] || []),
         {:ok, header_party} <- map_party(raw["HeaderParty"] || %{}),
         {:ok, amounts} <- map_amounts(raw["Amounts"] || %{}) do
      doc = %Document{
        erp_number: doc_num,
        type: type_atom,
        status: map_status(raw["Status"]),
        created_at: parse_erp_date(raw["CreatedAt"]),
        posted_at: parse_erp_date(raw["PostedAt"]),
        party: header_party,
        line_items: line_items,
        amounts: amounts,
        company_code: raw["CompanyCode"],
        fiscal_year: raw["FiscalYear"],
        raw_payload: raw
      }

      {:ok, doc}
    end
  end

  def map_document(raw) do
    Logger.warning("ERP document missing required fields", keys: Map.keys(raw))
    {:error, :missing_required_fields}
  end

  # VALIDATION: SMELL START - Dynamic atom creation
  # VALIDATION: This is a smell because `String.to_atom/1` converts a document type
  # code string returned by the ERP system's API. ERP systems such as SAP can
  # expose dozens to hundreds of document type codes, and enterprise customers often
  # configure custom document types specific to their business processes. When the
  # ERP system is upgraded or reconfigured, new codes appear. Each unique code
  # string permanently allocates an atom. A supported-list check occurs after the
  # atom is already created, so the allocation happens unconditionally for every
  # novel code encountered during integration processing.
  defp map_document_type(doc_type) when is_binary(doc_type) do
    atom = String.to_atom(doc_type)

    if doc_type in @supported_doc_types do
      {:ok, atom}
    else
      Logger.warning("Unsupported ERP document type", type: doc_type)
      {:error, {:unsupported_document_type, doc_type}}
    end
  end
  # VALIDATION: SMELL END

  defp map_document_type(_), do: {:error, :invalid_document_type}

  defp map_line_items(items) when is_list(items) do
    result =
      Enum.reduce_while(items, [], fn item, acc ->
        case map_line_item(item) do
          {:ok, li} -> {:cont, [li | acc]}
          {:error, _} = err -> {:halt, err}
        end
      end)

    case result do
      {:error, _} = err -> err
      list -> {:ok, Enum.reverse(list)}
    end
  end

  defp map_line_item(%{"LineNumber" => num, "MaterialNumber" => mat, "Quantity" => qty, "UoM" => uom}) do
    {:ok, %LineItem{line_number: num, material: mat, quantity: qty, unit_of_measure: uom}}
  end

  defp map_line_item(_), do: {:error, :malformed_line_item}

  defp map_party(%{"PartyId" => id, "Name" => name, "Country" => country}) do
    {:ok, %Party{id: id, name: name, country: country}}
  end

  defp map_party(_), do: {:ok, %Party{}}

  defp map_amounts(%{"Net" => net, "Tax" => tax, "Gross" => gross, "Currency" => currency}) do
    {:ok, %Amount{net: net, tax: tax, gross: gross, currency: currency}}
  end

  defp map_amounts(_), do: {:ok, %Amount{}}

  defp map_status("POSTED"), do: :posted
  defp map_status("PARKED"), do: :parked
  defp map_status("REVERSED"), do: :reversed
  defp map_status("BLOCKED"), do: :blocked
  defp map_status(_), do: :unknown

  defp parse_erp_date(nil), do: nil

  defp parse_erp_date(str) when is_binary(str) do
    case Date.from_iso8601(str) do
      {:ok, date} -> date
      _ -> nil
    end
  end
end
```
