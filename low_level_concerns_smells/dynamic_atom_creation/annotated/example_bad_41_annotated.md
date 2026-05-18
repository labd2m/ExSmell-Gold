# Annotated Example — Code Smell

## Metadata

- **Smell name:** Dynamic atom creation
- **Expected smell location:** `map_error_code/1` function
- **Affected function(s):** `map_error_code/1`
- **Short explanation:** The function converts error code strings returned by an external ERP integration API into atoms using `String.to_atom/1`. ERP systems can return a wide and evolving range of error codes (including vendor-specific, locale-based, or module-specific ones), making this an uncontrolled and unbounded source of atom creation.

---

```elixir
defmodule ERP.OrderIntegration do
  @moduledoc """
  Integrates with the company's ERP system to synchronise orders,
  process fulfilment updates, and relay error conditions back to the
  order management service.
  """

  require Logger

  alias ERP.{ERPClient, OrderRepo, FulfilmentQueue, AlertManager}

  @max_sync_batch 200
  @retry_delay_ms 2_000
  @max_retries 3

  @spec submit_order(String.t()) :: {:ok, String.t()} | {:error, term()}
  def submit_order(order_id) do
    Logger.info("Submitting order to ERP", order_id: order_id)

    with {:ok, order} <- OrderRepo.get(order_id),
         {:ok, erp_payload} <- build_erp_payload(order),
         {:ok, response} <- submit_with_retry(erp_payload, @max_retries),
         {:ok, erp_ref} <- extract_erp_reference(response),
         :ok <- OrderRepo.mark_submitted(order_id, erp_ref) do
      Logger.info("Order submitted to ERP", order_id: order_id, erp_ref: erp_ref)
      {:ok, erp_ref}
    else
      {:error, reason} = err ->
        Logger.error("ERP order submission failed",
          order_id: order_id,
          reason: inspect(reason)
        )
        err
    end
  end

  @spec sync_fulfilment_updates() :: {:ok, map()} | {:error, term()}
  def sync_fulfilment_updates do
    Logger.info("Polling ERP for fulfilment updates")

    case ERPClient.poll_updates(limit: @max_sync_batch) do
      {:ok, updates} ->
        stats = Enum.reduce(updates, %{ok: 0, failed: 0}, &process_update/2)
        {:ok, stats}

      {:error, reason} ->
        Logger.error("Fulfilment poll failed", reason: inspect(reason))
        {:error, reason}
    end
  end

  defp process_update(update, stats) do
    case FulfilmentQueue.enqueue(update) do
      :ok -> Map.update!(stats, :ok, &(&1 + 1))
      {:error, _} -> Map.update!(stats, :failed, &(&1 + 1))
    end
  end

  defp build_erp_payload(order) do
    {:ok,
     %{
       external_ref: order.id,
       customer_code: order.customer_code,
       lines: Enum.map(order.line_items, &build_line/1),
       currency: order.currency,
       total: order.total_cents,
       requested_at: DateTime.to_iso8601(order.created_at)
     }}
  end

  defp build_line(item) do
    %{sku: item.sku, qty: item.quantity, unit_price: item.unit_price_cents}
  end

  defp submit_with_retry(payload, retries_left) do
    case ERPClient.create_order(payload) do
      {:ok, response} ->
        {:ok, response}

      {:error, %{"error_code" => code} = raw_error} ->
        with {:ok, error_atom} <- map_error_code(code) do
          if retriable?(error_atom) and retries_left > 0 do
            Logger.warning("Retrying ERP submission", error: error_atom, retries_left: retries_left)
            Process.sleep(@retry_delay_ms)
            submit_with_retry(payload, retries_left - 1)
          else
            AlertManager.notify(:erp_submission_failure, %{error: error_atom})
            {:error, error_atom}
          end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # VALIDATION: SMELL START - Dynamic atom creation
  # VALIDATION: This is a smell because `String.to_atom/1` is applied to an
  # error code string returned by the ERP system. ERP vendors regularly add new
  # error codes for new modules, integrations, or regional configurations.
  # Every distinct error code string creates a new permanent atom, and since
  # error codes are dictated by the vendor, the developer cannot bound the
  # atom table growth.
  defp map_error_code(code) when is_binary(code) do
    {:ok, String.to_atom(code)}
  end
  # VALIDATION: SMELL END

  defp map_error_code(_), do: {:error, :unknown_error_code}

  defp retriable?(:erp_timeout), do: true
  defp retriable?(:erp_overloaded), do: true
  defp retriable?(:erp_lock_conflict), do: true
  defp retriable?(_), do: false

  defp extract_erp_reference(%{"erp_order_id" => ref}) when is_binary(ref), do: {:ok, ref}
  defp extract_erp_reference(_), do: {:error, :missing_erp_reference}
end
```
