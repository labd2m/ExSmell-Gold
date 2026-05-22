```elixir
defmodule Mailer.FormatHelpers do
  @moduledoc """
  Stateless helpers for email content formatting, recipient list validation,
  and plain-text generation from HTML bodies.
  """

  def wrap_preheader(html, preheader_text) when is_binary(preheader_text) do
    hidden = "<span style='display:none;max-height:0;overflow:hidden;'>#{preheader_text}</span>"
    String.replace(html, "<body", "<body>#{hidden}<body", global: false)
  end

  def strip_tags(html) do
    Regex.replace(~r/<[^>]+>/, html, "")
  end

  def inline_unsubscribe(body, token) when is_binary(token) do
    url = "https://mail.example.com/unsubscribe?token=#{token}"
    String.replace(body, "{{unsubscribe_url}}", url)
  end

  def valid_recipient?(%{email: email}) when is_binary(email) do
    Regex.match?(~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/, email)
  end
  def valid_recipient?(_), do: false

  def deduplicate_recipients(recipients) do
    recipients
    |> Enum.uniq_by(fn r -> String.downcase(r[:email] || "") end)
    |> Enum.filter(&valid_recipient?/1)
  end

  def personalise_subject(template, %{first_name: name}), do: String.replace(template, "{{first_name}}", name)
  def personalise_subject(template, _),                   do: String.replace(template, "{{first_name}}", "there")

  defmacro __using__(_opts) do
    quote do
      import Mailer.FormatHelpers
      alias Mailer.AttachmentStore

      @max_recipients_per_batch 500
      @default_encoding         "UTF-8"
    end
  end
end

defmodule Mailer.AttachmentStore do
  @moduledoc "Manages email attachments stored in object storage (stub)."

  def fetch(attachment_id) do
    {:ok, %{
      id:           attachment_id,
      filename:     "report_#{attachment_id}.pdf",
      content_type: "application/pdf",
      data:         <<0, 1, 2, 3>>
    }}
  end

  def list_for_campaign(campaign_id) do
    []
  end
end

defmodule Mailer.CampaignSender do
  use Mailer.FormatHelpers

  @moduledoc """
  Sends bulk email campaigns to recipient lists in configurable batch sizes,
  with personalisation, unsubscribe token injection, and attachment support.
  """

  def send_campaign(%{id: campaign_id, subject_template: subj, html_body: html} = campaign, recipients) do
    clean_recipients = deduplicate_recipients(recipients)
    attachments      = AttachmentStore.list_for_campaign(campaign_id)

    if length(clean_recipients) > @max_recipients_per_batch do
      clean_recipients
      |> Enum.chunk_every(@max_recipients_per_batch)
      |> Enum.map(&dispatch_batch(campaign, &1, attachments))
      |> Enum.reduce({0, []}, fn {sent, errs}, {total, all_errs} ->
        {total + sent, all_errs ++ errs}
      end)
      |> then(fn {total, errs} -> {:ok, %{sent: total, errors: length(errs)}} end)
    else
      {sent, errs} = dispatch_batch(campaign, clean_recipients, attachments)
      {:ok, %{sent: sent, errors: length(errs), campaign_id: campaign_id}}
    end
  end

  def build_message(campaign, recipient) do
    token   = generate_unsubscribe_token(recipient.email)
    subject = personalise_subject(campaign.subject_template, recipient)
    body    = campaign.html_body
              |> inline_unsubscribe(token)
              |> wrap_preheader(campaign[:preheader] || "")

    %{
      to:           recipient.email,
      subject:      subject,
      html_body:    body,
      text_body:    strip_tags(body),
      encoding:     @default_encoding,
      campaign_id:  campaign.id
    }
  end

  def personalise(message, recipient) do
    Map.update!(message, :html_body, fn body ->
      Enum.reduce(recipient, body, fn {key, val}, acc ->
        String.replace(acc, "{{#{key}}}", to_string(val))
      end)
    end)
  end

  def preview(%{} = message) do
    """
    To       : #{message.to}
    Subject  : #{message.subject}
    Encoding : #{message.encoding}
    ---
    #{message.text_body |> String.slice(0, 200)}
    """
  end

  defp dispatch_batch(campaign, recipients, _attachments) do
    results = Enum.map(recipients, fn r ->
      msg = build_message(campaign, r)
      IO.puts("[Mailer] Sending '#{msg.subject}' to #{msg.to}")
      :ok
    end)

    sent = Enum.count(results, &(&1 == :ok))
    errs = Enum.filter(results, &(&1 != :ok))
    {sent, errs}
  end

  defp generate_unsubscribe_token(email) do
    :crypto.hash(:sha256, email) |> Base.url_encode64(padding: false)
  end
end
```
