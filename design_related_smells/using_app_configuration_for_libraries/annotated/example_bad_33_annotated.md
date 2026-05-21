# Annotated Example — Bad Code

- **Smell name:** Using App Configuration for libraries
- **Expected smell location:** `Mailer.send/1`
- **Affected function(s):** `send/1`, `send_bulk/1`, `build_message/3`
- **Short explanation:** The library reads `:default_from`, `:rate_limit_per_minute`, `:track_opens`, and `:sandbox` from the global `Application` environment instead of accepting them as part of a message struct or options map. This prevents different subsystems of the same application from sending email with different sender addresses or tracking settings.

```elixir
defmodule Mailer do
  @moduledoc """
  A library for composing and sending transactional email messages.

  Handles rate limiting, sandbox mode, and open/click tracking configuration.
  Delegates actual SMTP delivery to the configured adapter.

  Application configuration:

      config :mailer,
        default_from:          "no-reply@example.com",
        rate_limit_per_minute: 60,
        track_opens:           true,
        track_clicks:          true,
        sandbox:               false,
        adapter:               Mailer.Adapters.SMTP
  """

  require Logger

  defstruct [
    :to,
    :cc,
    :bcc,
    :from,
    :reply_to,
    :subject,
    :text_body,
    :html_body,
    :attachments,
    :headers
  ]

  @type t :: %__MODULE__{
          to:          String.t() | [String.t()],
          cc:          [String.t()],
          bcc:         [String.t()],
          from:        String.t() | nil,
          reply_to:    String.t() | nil,
          subject:     String.t(),
          text_body:   String.t() | nil,
          html_body:   String.t() | nil,
          attachments: list(),
          headers:     map()
        }

  @doc """
  Sends an email message.

  If the message's `from` field is nil, falls back to the configured default.
  Returns `{:ok, message_id}` or `{:error, reason}`.
  """
  # VALIDATION: SMELL START - Using App Configuration for libraries
  # VALIDATION: This is a smell because default_from, rate_limit_per_minute,
  # track_opens, track_clicks, and sandbox are read from Application.fetch_env!/2
  # rather than accepted as parameters, so every call to send/1 in a dependent
  # app must share the same sender, tracking, and rate-limit settings.
  def send(%__MODULE__{} = message) do
    default_from          = Application.fetch_env!(:mailer, :default_from)
    rate_limit_per_minute = Application.fetch_env!(:mailer, :rate_limit_per_minute)
    track_opens           = Application.fetch_env!(:mailer, :track_opens)
    track_clicks          = Application.fetch_env!(:mailer, :track_clicks)
    sandbox               = Application.fetch_env!(:mailer, :sandbox)
    adapter               = Application.fetch_env!(:mailer, :adapter)
  # VALIDATION: SMELL END

    from = message.from || default_from

    outgoing =
      message
      |> Map.put(:from, from)
      |> maybe_inject_tracking_pixel(track_opens)
      |> maybe_wrap_links(track_clicks)
      |> normalize_recipients()

    if sandbox do
      Logger.info("[Mailer SANDBOX] Would send to #{inspect(outgoing.to)}: #{outgoing.subject}")
      {:ok, "sandbox_#{:crypto.strong_rand_bytes(8) |> Base.encode16()}"}
    else
      case check_rate_limit(from, rate_limit_per_minute) do
        :ok ->
          adapter.deliver(outgoing)

        {:error, :rate_limited} ->
          Logger.warning("[Mailer] Rate limit exceeded for sender: #{from}")
          {:error, :rate_limited}
      end
    end
  end

  @doc """
  Sends a list of messages, respecting the configured rate limit.

  Returns a list of `{:ok, message_id} | {:error, reason}` tuples.
  """
  def send_bulk(messages) when is_list(messages) do
    rate_limit = Application.fetch_env!(:mailer, :rate_limit_per_minute)
    delay_ms   = trunc(60_000 / max(rate_limit, 1))

    messages
    |> Enum.map(fn message ->
      result = send(message)
      Process.sleep(delay_ms)
      result
    end)
  end

  @doc """
  Constructs a Mailer struct from basic fields for common use cases.
  """
  def build_message(to, subject, html_body) do
    %__MODULE__{
      to:          to,
      subject:     subject,
      html_body:   html_body,
      text_body:   strip_html(html_body),
      cc:          [],
      bcc:         [],
      attachments: [],
      headers:     %{}
    }
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp maybe_inject_tracking_pixel(%__MODULE__{html_body: nil} = msg, _), do: msg

  defp maybe_inject_tracking_pixel(%__MODULE__{html_body: html} = msg, true) do
    pixel = ~s(<img src="https://track.example.com/open" width="1" height="1" />)
    %{msg | html_body: html <> pixel}
  end

  defp maybe_inject_tracking_pixel(msg, false), do: msg

  defp maybe_wrap_links(msg, false), do: msg

  defp maybe_wrap_links(%__MODULE__{html_body: nil} = msg, _), do: msg

  defp maybe_wrap_links(%__MODULE__{html_body: html} = msg, true) do
    wrapped = Regex.replace(~r/href="([^"]+)"/, html, fn _, url ->
      encoded = URI.encode_www_form(url)
      ~s(href="https://track.example.com/click?url=#{encoded}")
    end)

    %{msg | html_body: wrapped}
  end

  defp normalize_recipients(%__MODULE__{to: to} = msg) when is_binary(to) do
    %{msg | to: [to]}
  end

  defp normalize_recipients(msg), do: msg

  defp check_rate_limit(_from, _limit), do: :ok

  defp strip_html(html) do
    Regex.replace(~r/<[^>]+>/, html, "")
  end
end
```
