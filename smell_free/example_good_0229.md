```elixir
defmodule MyApp.Integrations.SlackNotifier do
  @moduledoc """
  Posts formatted messages to Slack incoming webhook URLs. Each notification
  type has a dedicated builder function that constructs the Block Kit payload,
  keeping the HTTP transport layer separate from the message formatting logic.

  All functions return tagged tuples; network failures are surfaced as
  `{:error, {:http_error, status}}` or `{:error, {:transport_error, reason}}`
  rather than raising so callers can decide on retry behaviour.
  """

  require Logger

  @http_timeout_ms 5_000

  @type webhook_url :: String.t()
  @type send_result :: :ok | {:error, term()}

  @doc "Posts a plain text alert to the given Slack webhook URL."
  @spec send_alert(webhook_url(), String.t(), String.t()) :: send_result()
  def send_alert(webhook_url, title, message)
      when is_binary(webhook_url) and is_binary(title) and is_binary(message) do
    payload = alert_payload(title, message)
    post(webhook_url, payload)
  end

  @doc "Posts a deployment notification with environment and commit context."
  @spec send_deploy(webhook_url(), map()) :: send_result()
  def send_deploy(webhook_url, %{env: env, sha: sha, author: author, message: msg}) do
    payload = deploy_payload(env, sha, author, msg)
    post(webhook_url, payload)
  end

  @doc "Posts an error digest with a count and sample trace."
  @spec send_error_digest(webhook_url(), String.t(), non_neg_integer(), String.t()) ::
          send_result()
  def send_error_digest(webhook_url, error_class, count, sample_trace)
      when is_binary(webhook_url) do
    payload = error_digest_payload(error_class, count, sample_trace)
    post(webhook_url, payload)
  end

  @spec alert_payload(String.t(), String.t()) :: map()
  defp alert_payload(title, message) do
    %{
      blocks: [
        section(":warning: *#{title}*"),
        section(message),
        context_block("Sent at #{format_now()}")
      ]
    }
  end

  @spec deploy_payload(String.t(), String.t(), String.t(), String.t()) :: map()
  defp deploy_payload(env, sha, author, message) do
    %{
      blocks: [
        section(":rocket: *Deployed to #{env}*"),
        section("*#{message}*\n`#{String.slice(sha, 0, 8)}` by #{author}"),
        context_block("Deployed at #{format_now()}")
      ]
    }
  end

  @spec error_digest_payload(String.t(), non_neg_integer(), String.t()) :: map()
  defp error_digest_payload(error_class, count, sample_trace) do
    %{
      blocks: [
        section(":red_circle: *#{error_class}* — #{count} occurrence(s)"),
        %{type: "section", text: %{type: "mrkdwn", text: "```#{sample_trace}```"}},
        context_block("Digest generated at #{format_now()}")
      ]
    }
  end

  @spec section(String.t()) :: map()
  defp section(text) do
    %{type: "section", text: %{type: "mrkdwn", text: text}}
  end

  @spec context_block(String.t()) :: map()
  defp context_block(text) do
    %{type: "context", elements: [%{type: "mrkdwn", text: text}]}
  end

  @spec post(webhook_url(), map()) :: send_result()
  defp post(url, payload) do
    body = Jason.encode!(payload)
    headers = [{"content-type", "application/json"}]

    case :httpc.request(:post, {String.to_charlist(url), headers, ~c"application/json", body},
           [{:timeout, @http_timeout_ms}], []) do
      {:ok, {{_, 200, _}, _headers, _body}} ->
        :ok

      {:ok, {{_, status, _}, _headers, _body}} ->
        Logger.warning("slack_webhook_non_200", status: status, url: url)
        {:error, {:http_error, status}}

      {:error, reason} ->
        Logger.error("slack_webhook_transport_error", reason: inspect(reason))
        {:error, {:transport_error, reason}}
    end
  end

  @spec format_now() :: String.t()
  defp format_now do
    DateTime.utc_now() |> Calendar.strftime("%Y-%m-%d %H:%M UTC")
  end
end
```
