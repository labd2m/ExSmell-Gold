```elixir
defmodule Notifications.Dispatcher do
  @moduledoc """
  Dispatches outbound notifications via multiple channels (email, SMS).
  Each channel function validates the recipient and formats the message
  before handing off to the appropriate transport adapter.
  """

  alias Notifications.EmailAdapter
  alias Notifications.SmsAdapter
  alias Notifications.Template
  alias Accounts.User

  @doc """
  Sends a templated email notification to the given user.
  """
  def send_email(%User{} = user, template_name, assigns \\ %{}) do
    display_name =
      if user.first_name && user.last_name do
        "#{user.first_name} #{user.last_name}"
      else
        user.email
      end

    with {:ok, subject, body} <- Template.render(template_name, Map.put(assigns, :name, display_name)),
         true <- valid_email?(user.email) do
      EmailAdapter.deliver(%{
        to: user.email,
        to_name: display_name,
        subject: subject,
        html_body: body
      })
    else
      {:error, reason} -> {:error, {:template_error, reason}}
      false -> {:error, :invalid_email}
    end
  end

  @doc """
  Sends a templated SMS notification to the given user.
  """
  def send_sms(%User{} = user, template_name, assigns \\ %{}) do
    display_name =
      if user.first_name && user.last_name do
        "#{user.first_name} #{user.last_name}"
      else
        user.email
      end

    with {:ok, _subject, body} <- Template.render(template_name, Map.put(assigns, :name, display_name)),
         true <- valid_phone?(user.phone_number) do
      SmsAdapter.deliver(%{
        to: user.phone_number,
        body: body
      })
    else
      {:error, reason} -> {:error, {:template_error, reason}}
      false -> {:error, :invalid_phone}
    end
  end

  @doc """
  Sends a notification via all configured channels for a user.
  """
  def broadcast(%User{} = user, template_name, assigns \\ %{}) do
    results = []

    results =
      if user.email_notifications_enabled do
        [send_email(user, template_name, assigns) | results]
      else
        results
      end

    results =
      if user.sms_notifications_enabled do
        [send_sms(user, template_name, assigns) | results]
      else
        results
      end

    summarize_results(results)
  end

  defp valid_email?(email), do: String.match?(email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/)
  defp valid_phone?(phone), do: String.match?(phone || "", ~r/^\+?[1-9]\d{7,14}$/)

  defp summarize_results(results) do
    errors = Enum.filter(results, fn r -> match?({:error, _}, r) end)
    if errors == [], do: :ok, else: {:partial_failure, errors}
  end
end
```
