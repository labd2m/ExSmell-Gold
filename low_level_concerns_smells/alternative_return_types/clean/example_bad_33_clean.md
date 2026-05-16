```elixir
defmodule Notifications.Dispatcher do
  @moduledoc """
  Dispatches notifications to users across multiple channels
  (email, SMS, push). Supports synchronous, asynchronous, and dry-run modes.
  """

  alias Notifications.{EmailAdapter, SmsAdapter, PushAdapter}
  alias Notifications.Repo
  alias Notifications.Schema.{DeliveryReceipt, NotificationTemplate}

  require Logger

  @supported_channels [:email, :sms, :push]

  @doc """
  Sends a notification to a user on the specified channel.

  ## Arguments

    * `user_id` — ID of the recipient.
    * `template_name` — Name of the template to render.
    * `opts` — Keyword list of options.

  ## Options

    * `:channel` — One of `:email`, `:sms`, `:push`. Defaults to `:email`.
    * `:async` — When `true`, dispatches in a background `Task` and returns
      the `Task` struct. Defaults to `false`.
    * `:dry_run` — When `true`, builds and returns the payload map without
      actually sending anything. Useful for previewing. Overrides `:async`.
    * `:vars` — Map of template variable bindings.

  ## Examples

      iex> send_notification(1, "welcome", channel: :email)
      {:ok, %DeliveryReceipt{...}}

      iex> send_notification(1, "welcome", async: true)
      %Task{...}

      iex> send_notification(1, "welcome", dry_run: true, channel: :sms)
      %{channel: :sms, payload: %{body: "Welcome!"}, would_send: true}

  """

  def send_notification(user_id, template_name, opts \\ []) do
    channel = Keyword.get(opts, :channel, :email)
    vars = Keyword.get(opts, :vars, %{})

    template = Repo.get_by!(NotificationTemplate, name: template_name, channel: channel)
    payload = render_template(template, vars)

    cond do
      opts[:dry_run] == true ->
        %{channel: channel, payload: payload, would_send: true}

      opts[:async] == true ->
        Task.async(fn ->
          do_dispatch(user_id, channel, payload, template.id)
        end)

      true ->
        do_dispatch(user_id, channel, payload, template.id)
    end
  end

  defp do_dispatch(user_id, channel, payload, template_id) do
    result =
      case channel do
        :email -> EmailAdapter.deliver(user_id, payload)
        :sms -> SmsAdapter.deliver(user_id, payload)
        :push -> PushAdapter.deliver(user_id, payload)
        other -> {:error, {:unsupported_channel, other}}
      end

    case result do
      {:ok, external_id} ->
        receipt = record_delivery(user_id, template_id, channel, external_id, :delivered)
        {:ok, receipt}

      {:error, reason} ->
        Logger.error("Notification dispatch failed for user #{user_id}: #{inspect(reason)}")
        record_delivery(user_id, template_id, channel, nil, :failed)
        {:error, reason}
    end
  end

  defp render_template(%NotificationTemplate{body: body, subject: subject}, vars) do
    %{
      subject: interpolate(subject, vars),
      body: interpolate(body, vars)
    }
  end

  defp interpolate(template_string, vars) do
    Enum.reduce(vars, template_string, fn {key, value}, acc ->
      String.replace(acc, "{{#{key}}}", to_string(value))
    end)
  end

  defp record_delivery(user_id, template_id, channel, external_id, status) do
    %DeliveryReceipt{}
    |> DeliveryReceipt.changeset(%{
      user_id: user_id,
      template_id: template_id,
      channel: channel,
      external_id: external_id,
      status: status,
      sent_at: DateTime.utc_now()
    })
    |> Repo.insert!()
  end

  @doc """
  Returns recent delivery receipts for a user, ordered by most recent.
  """
  def delivery_history(user_id, limit \\ 20) do
    DeliveryReceipt
    |> Repo.all_by(user_id: user_id)
    |> Enum.sort_by(& &1.sent_at, {:desc, DateTime})
    |> Enum.take(limit)
  end

  @doc """
  Lists all available notification channels.
  """
  def supported_channels, do: @supported_channels
end
```
