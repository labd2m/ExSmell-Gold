# Annotated Example — Code Smell

## Metadata

- **Smell name:** Dynamic atom creation
- **Expected smell location:** `parse_severity/1` function
- **Affected function(s):** `parse_severity/1`
- **Short explanation:** The function converts an alert severity string received from an external monitoring system's API into an atom using `String.to_atom/1`. Because monitoring tools can be configured with custom severity levels and can be upgraded to introduce new ones, this is an externally controlled, potentially unbounded source of atom creation.

---

```elixir
defmodule Monitoring.AlertIngester do
  @moduledoc """
  Ingests alert events from external monitoring systems via webhook callbacks.
  Routes and escalates alerts based on severity and service ownership.
  """

  require Logger

  alias Monitoring.{AlertRepo, EscalationEngine, OnCallResolver, SlackNotifier}

  @dedup_window_seconds 300

  @spec ingest(map()) :: {:ok, map()} | {:error, term()}
  def ingest(%{"alert_id" => alert_id} = payload) do
    Logger.info("Ingesting alert", alert_id: alert_id)

    with :ok <- check_duplicate(alert_id),
         {:ok, alert} <- parse_alert(payload),
         {:ok, record} <- AlertRepo.insert(alert),
         {:ok, on_call} <- OnCallResolver.resolve(alert.service, alert.severity),
         :ok <- notify(record, on_call),
         :ok <- maybe_escalate(record) do
      Logger.info("Alert ingested", alert_id: alert_id, severity: alert.severity)
      {:ok, record}
    else
      {:error, :duplicate} ->
        Logger.debug("Duplicate alert suppressed", alert_id: alert_id)
        {:ok, :suppressed}

      {:error, reason} = err ->
        Logger.error("Alert ingestion failed",
          alert_id: alert_id,
          reason: inspect(reason)
        )
        err
    end
  end

  def ingest(payload) do
    Logger.warning("Malformed alert payload", payload: inspect(payload))
    {:error, :malformed_payload}
  end

  defp check_duplicate(alert_id) do
    if AlertRepo.recent?(alert_id, within: @dedup_window_seconds),
      do: {:error, :duplicate},
      else: :ok
  end

  defp parse_alert(%{"alert_id" => id, "service" => service, "severity" => sev,
                     "message" => message, "fired_at" => fired_at} = payload) do
    with {:ok, severity} <- parse_severity(sev),
         {:ok, fired_datetime} <- parse_datetime(fired_at) do
      {:ok,
       %{
         external_id: id,
         service: service,
         severity: severity,
         message: message,
         source: payload["source"],
         labels: payload["labels"] || %{},
         fired_at: fired_datetime
       }}
    end
  end

  defp parse_alert(_), do: {:error, :missing_required_fields}

  # VALIDATION: SMELL START - Dynamic atom creation
  # VALIDATION: This is a smell because `String.to_atom/1` is applied to the
  # severity string returned by an external monitoring system. Monitoring
  # platforms can be configured with custom severity levels (e.g. "P0", "P1",
  # "sev1", "critical_sla", "warning-high") or upgraded to add new ones. Each
  # unique string creates a new permanent atom, and the developer cannot control
  # how many distinct severity values the external system may send.
  defp parse_severity(sev) when is_binary(sev) do
    normalized = sev |> String.trim() |> String.downcase()
    {:ok, String.to_atom(normalized)}
  end
  # VALIDATION: SMELL END

  defp parse_severity(_), do: {:error, :invalid_severity}

  defp notify(record, on_call) do
    SlackNotifier.post_alert(%{
      channel: on_call.slack_channel,
      alert_id: record.external_id,
      severity: record.severity,
      service: record.service,
      message: record.message,
      on_call_name: on_call.name
    })
  end

  defp maybe_escalate(%{severity: :critical} = record) do
    EscalationEngine.schedule(record, delay_minutes: 5)
  end

  defp maybe_escalate(%{severity: :high} = record) do
    EscalationEngine.schedule(record, delay_minutes: 15)
  end

  defp maybe_escalate(_), do: :ok

  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> {:ok, dt}
      _ -> {:error, :invalid_datetime}
    end
  end

  defp parse_datetime(_), do: {:error, :invalid_datetime}
end
```
