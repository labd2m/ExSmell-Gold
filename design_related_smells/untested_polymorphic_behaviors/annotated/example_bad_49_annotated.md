## Smell Metadata

- **Smell name:** Untested polymorphic behaviors
- **Expected smell location:** `build_recipient_header/1` — the `to_string(recipient)` call
- **Affected function(s):** `Notifications.EmailComposer.build_recipient_header/1`
- **Short explanation:** `to_string/1` uses the `String.Chars` protocol. No guard clause restricts `recipient` to types implementing it. A `Map`, `Tuple`, or struct without `String.Chars` raises `Protocol.UndefinedError`. Passing an integer or `URI` silently produces a recipient header like `"42"` or a URL string, which is a valid-looking but completely wrong email address that will silently fail delivery.

```elixir
defmodule Notifications.EmailComposer do
  @moduledoc """
  Composes outbound email messages for transactional notifications.
  Handles header assembly, MIME encoding, attachment bundling, and queue submission.
  """

  alias Notifications.{MailQueue, Template, Attachment}

  @default_sender "noreply@example.com"
  @default_sender_name "Example Platform"
  @max_recipients 50
  @max_subject_length 998

  def compose_and_queue(template_id, recipients, assigns, opts \\ []) do
    sender = Keyword.get(opts, :sender, @default_sender)
    sender_name = Keyword.get(opts, :sender_name, @default_sender_name)
    reply_to = Keyword.get(opts, :reply_to, nil)
    attachments = Keyword.get(opts, :attachments, [])

    with {:ok, template} <- Template.fetch(template_id),
         {:ok, recipient_headers} <- build_recipient_headers(recipients),
         {:ok, subject} <- render_subject(template, assigns),
         {:ok, html_body} <- render_body(template, assigns, :html),
         {:ok, text_body} <- render_body(template, assigns, :text),
         {:ok, mime} <-
           assemble_mime(%{
             from: format_address(sender, sender_name),
             to: recipient_headers,
             reply_to: reply_to,
             subject: subject,
             html: html_body,
             text: text_body,
             attachments: attachments
           }) do
      MailQueue.enqueue(mime)
    end
  end

  def build_recipient_headers(recipients) when is_list(recipients) do
    if length(recipients) > @max_recipients do
      {:error, {:too_many_recipients, length(recipients), @max_recipients}}
    else
      headers = Enum.map(recipients, &build_recipient_header/1)
      {:ok, headers}
    end
  end

  def build_recipient_headers(_), do: {:error, :recipients_must_be_list}

  # VALIDATION: SMELL START - Untested polymorphic behaviors
  # VALIDATION: This is a smell because `to_string(recipient)` uses the `String.Chars`
  # VALIDATION: protocol. No guard clause or multi-clause pattern restricts `recipient`
  # VALIDATION: to types that implement the protocol. Passing a Map, Tuple, or struct
  # VALIDATION: without `String.Chars` raises `Protocol.UndefinedError`. Passing an
  # VALIDATION: integer, float, or URI succeeds silently and produces a structurally
  # VALIDATION: plausible but semantically invalid "To:" header value, leading to silent
  # VALIDATION: delivery failures that are difficult to diagnose.
  def build_recipient_header(recipient) do
    address = to_string(recipient) |> String.trim()

    if String.contains?(address, " ") do
      ~s("#{address}")
    else
      address
    end
  end
  # VALIDATION: SMELL END

  def render_subject(%Template{subject: subject_template}, assigns) do
    try do
      rendered = EEx.eval_string(subject_template, assigns: assigns)

      if String.length(rendered) > @max_subject_length do
        {:ok, String.slice(rendered, 0, @max_subject_length)}
      else
        {:ok, rendered}
      end
    rescue
      e -> {:error, {:subject_render_failed, Exception.message(e)}}
    end
  end

  def render_body(%Template{} = template, assigns, format) when format in [:html, :text] do
    raw = if format == :html, do: template.html_body, else: template.text_body

    try do
      {:ok, EEx.eval_string(raw, assigns: assigns)}
    rescue
      e -> {:error, {:body_render_failed, format, Exception.message(e)}}
    end
  end

  def format_address(email, nil), do: email
  def format_address(email, name), do: "#{name} <#{email}>"

  def assemble_mime(parts) do
    mime = %{
      from: parts.from,
      to: parts.to,
      subject: parts.subject,
      html_body: parts.html,
      text_body: parts.text,
      headers: build_extra_headers(parts.reply_to),
      attachments: Enum.map(parts.attachments, &Attachment.encode/1)
    }

    {:ok, mime}
  end

  defp build_extra_headers(nil), do: []
  defp build_extra_headers(reply_to), do: [{"Reply-To", reply_to}]
end
```
