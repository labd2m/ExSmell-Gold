```elixir
defmodule NotificationDispatcher do
  @moduledoc """
  Dispatches notifications to users across different channels.
  """

  alias NotificationDispatcher.{
    PasswordResetRequest,
    ShipmentAlert,
    PromotionalCampaign,
    EmailAdapter,
    SMSAdapter,
    PushAdapter,
    Repo
  }

  @doc """
  Dispatches a notification based on the type of event struct provided.

  ## Examples

      iex> NotificationDispatcher.dispatch(%PasswordResetRequest{})
      {:ok, :sent}

  """


  def dispatch(%PasswordResetRequest{user_id: user_id, token: token, expires_at: expires_at}) do
    with {:ok, user} <- Repo.get_user(user_id),
         true <- DateTime.compare(expires_at, DateTime.utc_now()) == :gt,
         reset_url <- "https://app.example.com/reset?token=#{token}",
         {:ok, _} <- EmailAdapter.send(user.email, :password_reset, %{url: reset_url}) do
      Repo.mark_token_sent(token)
      {:ok, :sent}
    else
      false -> {:error, :token_expired}
      {:error, reason} -> {:error, reason}
    end
  end

  # sends an SMS shipment update to the customer
  def dispatch(%ShipmentAlert{
        tracking_number: tracking_number,
        phone_number: phone_number,
        carrier: carrier,
        estimated_delivery: eta
      }) do
    message =
      "Your shipment #{tracking_number} via #{carrier} is on its way. " <>
        "Estimated delivery: #{Calendar.strftime(eta, "%B %d, %Y")}."

    case SMSAdapter.send(phone_number, message) do
      {:ok, sid} ->
        Repo.log_shipment_notification(tracking_number, sid)
        {:ok, :sent}

      {:error, :invalid_phone} ->
        {:error, :undeliverable}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # sends a push notification for a promotional campaign to all opted-in users
  def dispatch(%PromotionalCampaign{
        campaign_id: campaign_id,
        title: title,
        body: body,
        target_segment: segment
      }) do
    device_tokens =
      Repo.get_opted_in_device_tokens(segment)

    results =
      Enum.map(device_tokens, fn token ->
        PushAdapter.send(token, %{title: title, body: body, campaign_id: campaign_id})
      end)

    success_count = Enum.count(results, &match?({:ok, _}, &1))
    failure_count = length(results) - success_count

    Repo.record_campaign_dispatch(campaign_id, success_count, failure_count)

    {:ok, %{sent: success_count, failed: failure_count}}
  end

end
```
