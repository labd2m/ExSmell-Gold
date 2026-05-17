```elixir
defmodule Notifications.BounceHandler do
  @moduledoc """
  Processes email Delivery Status Notification (DSN) messages received from
  mail servers to classify bounces, update suppression lists, and trigger
  retry logic.

  DSN messages contain headers like:
    Final-Recipient: rfc822; user@example.com
    Action: failed
    Status: 5.1.1
    Diagnostic-Code: smtp; 550 5.1.1: User unknown
  """

  require Logger

  @hard_bounce_statuses ["5.1.1", "5.1.2", "5.1.3", "5.4.4"]
  @soft_bounce_statuses ["4.2.1", "4.2.2", "4.3.1", "4.4.1"]

  @hard_bounce_actions  ["failed"]
  @soft_bounce_actions  ["delayed"]

  def handle(raw_dsn) when is_binary(raw_dsn) do
    parsed = parse_dsn(raw_dsn)

    with {:ok, recipient} <- extract_recipient(parsed),
         {:ok, bounce}    <- classify_bounce(parsed) do
      record_bounce(recipient, bounce)
      {:ok, %{recipient: recipient, bounce_type: bounce}}
    end
  end

  defp parse_dsn(raw) do
    raw
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce(%{}, fn line, acc ->
      parts = String.split(line, ": ")
      key   = Enum.at(parts, 0) |> String.downcase() |> String.replace("-", "_")
      value = Enum.at(parts, 1)

      Map.put(acc, key, value)
    end)
  end

  defp extract_recipient(%{"final_recipient" => recipient}) when is_binary(recipient) do
    email =
      recipient
      |> String.split(";")
      |> List.last()
      |> String.trim()

    {:ok, email}
  end

  defp extract_recipient(_), do: {:error, :no_recipient}

  defp classify_bounce(%{"action" => action, "status" => status}) do
    cond do
      action in @hard_bounce_actions and status in @hard_bounce_statuses ->
        {:ok, :hard}

      action in @soft_bounce_actions or status in @soft_bounce_statuses ->
        {:ok, :soft}

      action in @hard_bounce_actions ->
        {:ok, :hard}

      true ->
        {:ok, :unknown}
    end
  end

  defp classify_bounce(_), do: {:ok, :unknown}

  defp record_bounce(recipient, :hard) do
    Logger.info("Hard bounce for #{recipient} — adding to suppression list")
    {:ok, :suppressed}
  end

  defp record_bounce(recipient, :soft) do
    Logger.info("Soft bounce for #{recipient} — scheduling retry")
    {:ok, :retry_scheduled}
  end

  defp record_bounce(recipient, :unknown) do
    Logger.warning("Unknown bounce type for #{recipient}")
    {:ok, :logged}
  end

  def suppression_summary(bounce_records) do
    hard = Enum.count(bounce_records, &(&1.bounce_type == :hard))
    soft = Enum.count(bounce_records, &(&1.bounce_type == :soft))

    %{total: length(bounce_records), hard: hard, soft: soft}
  end

  def should_retry?(%{bounce_type: :soft}), do: true
  def should_retry?(_), do: false
end
```
