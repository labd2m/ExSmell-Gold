```elixir
defmodule Billing.TaxCalculationClient do
  @moduledoc """
  HTTP client for the third-party tax engine API (e.g. Avalara / TaxJar style).
  Computes sales tax for invoices, validates exemption certificates,
  and commits transactions to the tax ledger.
  """

  require Logger

  @base_url "https://tax-engine.internal/api/v2"
  @commit_url "#{@base_url}/transactions/commit"

  def calculate(invoice_id, line_items, ship_to_address, opts \\ []) do
    exemption_cert = Keyword.get(opts, :exemption_cert)
    currency = Keyword.get(opts, :currency, "USD")

    payload = %{
      invoice_id: invoice_id,
      line_items: line_items,
      ship_to: ship_to_address,
      currency: currency,
      exemption_certificate: exemption_cert
    }

    case http_post("#{@base_url}/calculate", payload, auth_headers()) do
      {:ok, raw} ->
        interpret_tax_calculation_response(raw, invoice_id)

      {:error, reason} ->
        Logger.error("Tax API transport error invoice=#{invoice_id}: #{inspect(reason)}")
        {:error, {:transport, reason}}
    end
  end

  def commit_transaction(transaction_id) do
    case http_post(@commit_url, %{transaction_id: transaction_id}, auth_headers()) do
      {:ok, %{status: 200, body: %{"committed" => true}}} ->
        {:ok, :committed}

      {:ok, %{status: 404}} ->
        {:error, :transaction_not_found}

      {:ok, %{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  def void_transaction(transaction_id) do
    case http_post("#{@base_url}/transactions/#{transaction_id}/void", %{}, auth_headers()) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: 404}} -> {:error, :not_found}
      {:ok, %{status: status}} -> {:error, {:unexpected_status, status}}
      {:error, reason} -> {:error, {:transport, reason}}
    end
  end

  defp interpret_tax_calculation_response(response, invoice_id) do
    case response do
      %{status: 200, body: body} ->
        case body do
          %{
            "status" => "calculated",
            "transaction_id" => tid,
            "total_tax" => total,
            "jurisdictions" => jurisdictions,
            "effective_rate" => rate
          } ->
            {:ok,
             %{
               transaction_id: tid,
               total_tax_cents: round(total * 100),
               effective_rate: rate,
               jurisdictions: parse_jurisdictions(jurisdictions),
               exempt: false,
               warnings: []
             }}

          %{
            "status" => "calculated",
            "transaction_id" => tid,
            "total_tax" => total,
            "jurisdictions" => jurisdictions,
            "warnings" => warnings
          } ->
            Logger.warning("Tax calc warnings invoice=#{invoice_id}: #{inspect(warnings)}")

            {:ok,
             %{
               transaction_id: tid,
               total_tax_cents: round(total * 100),
               effective_rate: nil,
               jurisdictions: parse_jurisdictions(jurisdictions),
               exempt: false,
               warnings: warnings
             }}

          %{"status" => "exempt", "transaction_id" => tid, "exemption_reason" => reason} ->
            {:ok,
             %{
               transaction_id: tid,
               total_tax_cents: 0,
               effective_rate: 0.0,
               jurisdictions: [],
               exempt: true,
               exemption_reason: reason,
               warnings: []
             }}

          %{"status" => "exempt", "transaction_id" => tid} ->
            {:ok,
             %{
               transaction_id: tid,
               total_tax_cents: 0,
               effective_rate: 0.0,
               jurisdictions: [],
               exempt: true,
               exemption_reason: nil,
               warnings: []
             }}

          %{"status" => "nexus_mismatch", "unresolved_jurisdictions" => juris} ->
            {:error, {:nexus_mismatch, juris}}

          %{"status" => "unsupported_jurisdiction", "jurisdiction" => j} ->
            {:error, {:unsupported_jurisdiction, j}}

          %{"status" => unknown} ->
            {:error, {:unknown_tax_status, unknown}}

          _ ->
            {:error, :malformed_tax_response}
        end

      %{status: 400, body: %{"error" => "invalid_address", "field" => field}} ->
        {:error, {:invalid_address, field}}

      %{status: 400, body: %{"error" => "missing_line_items"}} ->
        {:error, :missing_line_items}

      %{status: 400, body: %{"error" => "invalid_currency", "supported" => currencies}} ->
        {:error, {:invalid_currency, currencies}}

      %{status: 400, body: %{"error" => msg}} ->
        {:error, {:bad_request, msg}}

      %{status: 400} ->
        {:error, :bad_request}

      %{status: 401} ->
        Logger.error("Tax API unauthorized for invoice=#{invoice_id}")
        {:error, :unauthorized}

      %{status: 403, body: %{"error" => "account_suspended", "reason" => reason}} ->
        {:error, {:account_suspended, reason}}

      %{status: 403} ->
        {:error, :forbidden}

      %{status: 422, body: %{"error" => "invalid_exemption_cert", "detail" => detail}} ->
        {:error, {:invalid_exemption_cert, detail}}

      %{status: 422, body: %{"error" => msg}} ->
        {:error, {:unprocessable, msg}}

      %{status: 429, body: %{"retry_after" => seconds, "quota_reset_at" => reset}} ->
        {:error, {:rate_limited, seconds, reset}}

      %{status: 429} ->
        {:error, :rate_limited}

      %{status: 500, body: %{"request_id" => rid, "message" => msg}} ->
        Logger.error("Tax engine 500 request_id=#{rid} msg=#{msg} invoice=#{invoice_id}")
        {:error, {:server_error, rid}}

      %{status: 500} ->
        {:error, :server_error}

      %{status: 503, body: %{"maintenance_window" => window}} ->
        {:error, {:maintenance, window}}

      %{status: 503} ->
        {:error, :service_unavailable}

      %{status: status, body: body} ->
        Logger.warning("Unexpected tax API status=#{status} invoice=#{invoice_id} body=#{inspect(body)}")
        {:error, {:unexpected_response, status}}
    end
  end

  defp parse_jurisdictions(jurisdictions) when is_list(jurisdictions) do
    Enum.map(jurisdictions, fn j ->
      %{name: j["name"], rate: j["rate"], tax_amount: round(j["tax_amount"] * 100)}
    end)
  end

  defp parse_jurisdictions(_), do: []

  defp auth_headers do
    key = System.get_env("TAX_ENGINE_API_KEY", "")
    [{"Authorization", "Bearer #{key}"}, {"Content-Type", "application/json"}]
  end

  defp http_post(_url, _payload, _headers), do: {:error, :not_implemented}
end
```
