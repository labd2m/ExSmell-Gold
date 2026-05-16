---
smell_name: Complex branching
smell_location: Notifications.EmailSender.handle_delivery_response/2
affected_functions:
  - handle_delivery_response/2
explanation: >
  `handle_delivery_response/2` contains a `case` with 14 branches covering
  every HTTP status and error shape that the email provider API can return for
  a single send operation. Logging, error tagging, and side effects (recording
  sent emails) are all interleaved within the same match arms, making the
  function long and difficult to reason about. A single misbehaving branch
  can leave the function in an inconsistent state, and adding support for new
  provider response codes requires modifying this already complex function.
---

```elixir
defmodule Notifications.EmailSender do
  @moduledoc """
  Sends transactional emails via a third-party email delivery API.
  Handles templated messages for billing, authentication, and onboarding flows.
  """

  require Logger

  alias Notifications.{EmailLog, EmailTemplate, Recipient}

  @send_timeout 8_000
  @max_recipients 50

  def send_transactional(template_name, recipient, variables \\ %{}) do
    with {:ok, template} <- EmailTemplate.fetch_by_name(template_name),
         {:ok, rendered} <- EmailTemplate.render(template, variables),
         :ok <- validate_recipient(recipient) do
      dispatch_email(rendered, recipient)
    end
  end

  def send_bulk(template_name, recipients, variables \\ %{})
      when length(recipients) <= @max_recipients do
    with {:ok, template} <- EmailTemplate.fetch_by_name(template_name),
         {:ok, rendered} <- EmailTemplate.render(template, variables) do
      recipients
      |> Enum.map(fn recipient ->
        Task.async(fn -> dispatch_email(rendered, recipient) end)
      end)
      |> Task.await_many(30_000)
    end
  end

  def get_delivery_status(message_id) do
    case EmailLog.find_by_message_id(message_id) do
      nil -> {:error, :not_found}
      log -> {:ok, log}
    end
  end

  defp validate_recipient(%{email: email}) when is_binary(email) do
    if String.match?(email, ~r/^[^\s]+@[^\s]+\.[^\s]+$/) do
      :ok
    else
      {:error, :invalid_email}
    end
  end

  defp dispatch_email(rendered_email, %{email: to, name: name}) do
    payload = %{
      to: [%{email: to, name: name}],
      from: %{email: sender_address(), name: sender_name()},
      subject: rendered_email.subject,
      html: rendered_email.html_body,
      text: rendered_email.text_body
    }

    EmailProviderAPI.send(payload, timeout: @send_timeout)
    |> handle_delivery_response(to)
  end

  # VALIDATION: SMELL START - Complex branching
  # VALIDATION: This is a smell because all 14 structurally different responses
  # from one API endpoint are handled inside a single function. The function
  # mixes transport-level concerns (HTTP status codes, headers), domain side
  # effects (EmailLog.record_sent), and error taxonomy in the same arms,
  # dramatically increasing cyclomatic complexity and the blast radius of any
  # single bug.
  defp handle_delivery_response(response, recipient_email) do
    case response do
      {:ok, %{status: 202, body: %{"message_id" => msg_id}}} ->
        Logger.info("Email accepted for #{recipient_email}, id=#{msg_id}")
        EmailLog.record_sent(recipient_email, msg_id)
        {:ok, msg_id}

      {:ok, %{status: 200, body: %{"id" => msg_id}}} ->
        {:ok, msg_id}

      {:ok, %{status: 400, body: %{"errors" => [%{"message" => msg} | _]}}} ->
        Logger.warning("Email validation error for #{recipient_email}: #{msg}")
        {:error, {:validation_failed, msg}}

      {:ok, %{status: 400, body: %{"message" => msg}}} ->
        {:error, {:bad_request, msg}}

      {:ok, %{status: 401}} ->
        Logger.error("Email provider API key rejected")
        {:error, :unauthorized}

      {:ok, %{status: 403, body: %{"message" => msg}}} ->
        Logger.warning("Email provider access denied: #{msg}")
        {:error, {:forbidden, msg}}

      {:ok, %{status: 413}} ->
        {:error, :payload_too_large}

      {:ok, %{status: 422, body: %{"errors" => errors}}} ->
        Logger.warning("Unprocessable email request: #{inspect(errors)}")
        {:error, {:unprocessable, errors}}

      {:ok, %{status: 429, headers: headers}} ->
        retry_after = get_retry_after_header(headers)
        Logger.warning("Email provider rate limit hit, retry after #{retry_after}s")
        {:error, {:rate_limited, retry_after}}

      {:ok, %{status: 500}} ->
        Logger.error("Email provider internal error")
        {:error, :provider_error}

      {:ok, %{status: 503}} ->
        Logger.warning("Email provider service unavailable")
        {:error, :service_unavailable}

      {:ok, %{status: status}} ->
        Logger.error("Unexpected email provider status #{status} for #{recipient_email}")
        {:error, {:unexpected_status, status}}

      {:error, :timeout} ->
        Logger.warning("Email provider request timed out for #{recipient_email}")
        {:error, :timeout}

      {:error, reason} ->
        Logger.error("Email dispatch failed for #{recipient_email}: #{inspect(reason)}")
        {:error, {:dispatch_error, reason}}
    end
  end
  # VALIDATION: SMELL END

  defp get_retry_after_header(headers) do
    case List.keyfind(headers, "x-ratelimit-reset", 0) do
      {_, v} -> String.to_integer(v)
      nil -> 60
    end
  end

  defp sender_address, do: Application.fetch_env!(:notifications, :sender_email)
  defp sender_name, do: Application.fetch_env!(:notifications, :sender_name)
end
```
