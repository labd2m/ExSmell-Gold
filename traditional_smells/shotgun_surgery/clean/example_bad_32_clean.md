```elixir
defmodule Documents.Generator do
  @moduledoc """
  Renders business documents from structured data sources into
  formatted PDF or HTML output, applying type-appropriate templates.
  """


  @spec generate(atom(), map()) :: {:ok, binary()} | {:error, term()}
  def generate(:invoice, data) do
    template = "templates/invoice.html.eex"
    render_pdf(template, %{
      invoice_number: data.number,
      customer:       data.customer,
      line_items:     data.line_items,
      subtotal:       data.subtotal,
      tax:            data.tax,
      total:          data.total,
      due_date:       data.due_date
    })
  end

  def generate(:receipt, data) do
    template = "templates/receipt.html.eex"
    render_pdf(template, %{
      receipt_number:  data.number,
      customer:        data.customer,
      items_purchased: data.items,
      amount_paid:     data.amount,
      payment_method:  data.payment_method,
      paid_at:         data.paid_at
    })
  end

  def generate(:contract, data) do
    template = "templates/contract.html.eex"
    render_pdf(template, %{
      contract_ref:   data.reference,
      parties:        data.parties,
      effective_date: data.effective_date,
      terms:          data.terms,
      jurisdiction:   data.jurisdiction
    })
  end

  @spec requires_signature?(atom()) :: boolean()
  def requires_signature?(:invoice),  do: false
  def requires_signature?(:receipt),  do: false
  def requires_signature?(:contract), do: true


  defp render_pdf(template, assigns) do
    {:ok, <<"PDF binary stub for #{template}">>}
  end
end

defmodule Documents.ArchivePolicy do
  @moduledoc """
  Defines retention periods and storage class assignments for each
  document type, in compliance with financial and legal regulations.
  """


  @spec retention_years(atom()) :: pos_integer()
  def retention_years(:invoice),  do: 7
  def retention_years(:receipt),  do: 5
  def retention_years(:contract), do: 10

  @spec storage_class(atom()) :: atom()
  def storage_class(:invoice),  do: :standard_ia
  def storage_class(:receipt),  do: :standard_ia
  def storage_class(:contract), do: :glacier


  def archive_document(document) do
    class       = storage_class(document.type)
    expire_at   = Date.add(document.created_at, retention_years(document.type) * 365)

    %{
      document_id:   document.id,
      type:          document.type,
      storage_class: class,
      archive_path:  "archive/#{document.type}/#{document.id}.pdf",
      retain_until:  expire_at
    }
  end

  def past_retention?(document) do
    expiry = Date.add(document.created_at, retention_years(document.type) * 365)
    Date.compare(Date.utc_today(), expiry) == :gt
  end
end

defmodule Documents.SearchIndex do
  @moduledoc """
  Manages Elasticsearch index mappings and field configurations for
  full-text and structured search across business documents.
  """


  @spec searchable_fields(atom()) :: [String.t()]
  def searchable_fields(:invoice) do
    ["invoice_number", "customer.name", "customer.email", "total", "due_date"]
  end

  def searchable_fields(:receipt) do
    ["receipt_number", "customer.name", "amount_paid", "paid_at", "payment_method"]
  end

  def searchable_fields(:contract) do
    ["contract_ref", "parties.name", "effective_date", "jurisdiction", "terms"]
  end

  @spec index_name(atom()) :: String.t()
  def index_name(:invoice),  do: "documents_invoices"
  def index_name(:receipt),  do: "documents_receipts"
  def index_name(:contract), do: "documents_contracts"


  def index_document(document) do
    index  = index_name(document.type)
    fields = searchable_fields(document.type)

    payload =
      fields
      |> Enum.reduce(%{}, fn field, acc ->
        keys  = String.split(field, ".")
        value = get_in(document, Enum.map(keys, &String.to_existing_atom/1))
        Map.put(acc, field, value)
      end)

    Elasticsearch.put_document(index, document.id, payload)
  end
end
```
