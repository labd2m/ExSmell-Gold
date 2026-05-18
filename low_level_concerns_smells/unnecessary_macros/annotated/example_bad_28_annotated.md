# Annotated Example – Unnecessary Macros

| Field | Value |
|---|---|
| **Smell name** | Unnecessary macros |
| **Expected smell location** | `Notifications.Dispatcher` module, `status_label/1` macro |
| **Affected function(s)** | `status_label/1` |
| **Short explanation** | `status_label/1` is a macro that simply maps an integer status code to a string label. This is a pure data-mapping operation that can be expressed trivially as a set of function clauses, making the macro both unnecessary and harder to understand. |

```elixir
defmodule Notifications.Dispatcher do
  @moduledoc """
  Dispatches push notifications, emails, and SMS alerts to users
  and records delivery outcomes in the audit log.
  """

  require Logger

  @delivery_timeout_ms 5_000

  # VALIDATION: SMELL START - Unnecessary macros
  # VALIDATION: This is a smell because `status_label/1` only pattern-matches
  # an integer to return a descriptive string — a textbook use-case for
  # multi-clause functions. The macro adds `quote/unquote` boilerplate and
  # forces every caller to `require` the module without any compile-time gain.
  defmacro status_label(code) do
    quote do
      case unquote(code) do
        200 -> "delivered"
        201 -> "queued"
        400 -> "bad_request"
        401 -> "unauthorized"
        403 -> "forbidden"
        404 -> "not_found"
        408 -> "timeout"
        429 -> "rate_limited"
        500 -> "server_error"
        503 -> "service_unavailable"
        _ -> "unknown"
      end
    end
  end
  # VALIDATION: SMELL END

  def send_push(user_id, title, body, opts \\ []) do
    payload = %{
      user_id: user_id,
      title: title,
      body: body,
      priority: Keyword.get(opts, :priority, :normal),
      sent_at: DateTime.utc_now()
    }

    case push_provider().deliver(payload, timeout: @delivery_timeout_ms) do
      {:ok, %{status: code}} ->
        require Notifications.Dispatcher
        label = Notifications.Dispatcher.status_label(code)
        Logger.info("Push sent to #{user_id} – #{label}")
        {:ok, label}

      {:error, reason} ->
        Logger.error("Push failed for #{user_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def send_email(to, subject, html_body, opts \\ []) do
    message = %{
      to: to,
      subject: subject,
      html_body: html_body,
      from: Keyword.get(opts, :from, "noreply@example.com"),
      reply_to: Keyword.get(opts, :reply_to, nil)
    }

    case email_provider().send(message) do
      {:ok, %{status: code}} ->
        require Notifications.Dispatcher
        label = Notifications.Dispatcher.status_label(code)
        Logger.info("Email sent to #{to} – #{label}")
        {:ok, label}

      {:error, reason} ->
        Logger.warning("Email delivery failed to #{to}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def send_sms(phone_number, text) do
    case sms_provider().send(%{to: phone_number, body: text}) do
      {:ok, %{status: code}} ->
        require Notifications.Dispatcher
        label = Notifications.Dispatcher.status_label(code)
        {:ok, label}

      {:error, _} = err ->
        err
    end
  end

  def batch_push(user_ids, title, body) do
    user_ids
    |> Task.async_stream(fn uid -> send_push(uid, title, body) end,
      max_concurrency: 10,
      timeout: @delivery_timeout_ms + 1_000
    )
    |> Enum.reduce(%{ok: [], error: []}, fn
      {:ok, {:ok, label}}, acc -> Map.update!(acc, :ok, &[label | &1])
      {:ok, {:error, _}}, acc -> Map.update!(acc, :error, &[:failed | &1])
      {:exit, _}, acc -> Map.update!(acc, :error, &[:timeout | &1])
    end)
  end

  defp push_provider, do: Application.get_env(:notifications, :push_provider)
  defp email_provider, do: Application.get_env(:notifications, :email_provider)
  defp sms_provider, do: Application.get_env(:notifications, :sms_provider)
end
```
