```elixir
defmodule Notifications.Email do
  @moduledoc "Value object representing an outbound email message."

  @enforce_keys [:to, :subject, :body]
  defstruct [:to, :from, :subject, :body, :html_body, :reply_to, :metadata]

  def valid_address?(address) when is_binary(address) do
    String.match?(address, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/)
  end

  def valid_address?(_), do: false
end

defmodule Notifications.SmtpProvider do
  @moduledoc "Simulates sending via an SMTP relay provider."

  def send(%{to: to}) when is_binary(to) do
    cond do
      String.ends_with?(to, "@blocked.example.com") -> {:error, "recipient_blocked"}
      String.ends_with?(to, "@unknown.tld") -> {:error, "invalid_domain"}
      true -> {:ok, "msg_#{:rand.uniform(9_999_999)}"}
    end
  end
end

defmodule Notifications.DeliveryLog do
  @moduledoc "Persists delivery records for auditing and retry logic."

  defstruct [:id, :email_to, :message_id, :status, :sent_at, :error]

  def record_success(to, message_id) do
    %__MODULE__{
      id: :rand.uniform(999_999),
      email_to: to,
      message_id: message_id,
      status: :delivered,
      sent_at: DateTime.utc_now()
    }
  end

  def record_failure(to, error) do
    %__MODULE__{
      id: :rand.uniform(999_999),
      email_to: to,
      status: :failed,
      error: error,
      sent_at: DateTime.utc_now()
    }
  end
end

defmodule Notifications.EmailDispatcher do
  @moduledoc """
  Validates and dispatches outbound email messages through the configured
  SMTP provider. Logs delivery outcomes for retry and audit purposes.
  """

  alias Notifications.{DeliveryLog, Email, SmtpProvider}
  require Logger

  def dispatch(%Email{} = email) do
    unless is_binary(email.to) and String.length(email.to) > 0 do
      raise RuntimeError, message: "Email must have a non-empty recipient address"
    end

    unless Email.valid_address?(email.to) do
      raise RuntimeError, message: "Recipient '#{email.to}' is not a valid email address"
    end

    unless is_binary(email.subject) and String.length(String.trim(email.subject)) > 0 do
      raise RuntimeError, message: "Email subject cannot be blank"
    end

    unless is_binary(email.body) and String.length(email.body) > 0 do
      raise RuntimeError, message: "Email body cannot be empty"
    end

    case SmtpProvider.send(email) do
      {:ok, message_id} ->
        log = DeliveryLog.record_success(email.to, message_id)
        Logger.info("Email delivered to=#{email.to} message_id=#{message_id}")
        log

      {:error, provider_reason} ->
        raise RuntimeError,
          message: "SMTP provider rejected message to '#{email.to}': #{provider_reason}"
    end
  end

  def schedule(email, %DateTime{} = send_at) do
    delay_ms = DateTime.diff(send_at, DateTime.utc_now(), :millisecond)

    if delay_ms <= 0 do
      {:error, "send_at must be in the future"}
    else
      Logger.info("Scheduled email to=#{email.to} at=#{send_at}")
      {:ok, %{email: email, scheduled_at: send_at}}
    end
  end
end

defmodule Notifications.CampaignSender do
  @moduledoc """
  Sends bulk notification emails for a marketing or transactional campaign.
  Collects per-recipient outcomes without aborting the entire batch on failure.
  """

  alias Notifications.{Email, EmailDispatcher}
  require Logger

  def send_batch(campaign_id, recipients) when is_list(recipients) do
    Logger.info("Starting campaign=#{campaign_id} recipients=#{length(recipients)}")

    results =
      Enum.map(recipients, fn %{email: to, subject: subject, body: body} ->
        email = %Email{to: to, subject: subject, body: body, from: "noreply@myapp.com"}

        # Client forced to use try/rescue because EmailDispatcher.dispatch/1
        # raises on all error conditions instead of returning {:error, reason}.
        try do
          log = EmailDispatcher.dispatch(email)
          {:ok, log}
        rescue
          e in RuntimeError ->
            Logger.warning("campaign=#{campaign_id} failed to=#{to}: #{e.message}")
            {:error, %{to: to, reason: e.message}}
        end
      end)

    delivered = Enum.filter(results, &match?({:ok, _}, &1))
    failed = Enum.filter(results, &match?({:error, _}, &1))

    Logger.info(
      "Campaign=#{campaign_id} done: #{length(delivered)} delivered, #{length(failed)} failed"
    )

    %{campaign_id: campaign_id, delivered: length(delivered), failed: length(failed), results: results}
  end
end
```
