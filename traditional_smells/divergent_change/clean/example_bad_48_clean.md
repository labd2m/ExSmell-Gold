```elixir
defmodule MyApp.NotificationHub do
  @moduledoc """
  Dispatches notifications across channels (push, SMS, email),
  manages reusable message templates, and tracks delivery outcomes.
  """

  alias MyApp.Repo
  alias MyApp.Notifications.{Template, DeliveryRecord}
  alias MyApp.Accounts.User
  import Ecto.Query



  @push_provider_url "https://fcm.googleapis.com/fcm/send"
  @sms_provider_url "https://api.twilio.io/2010-04-01/Accounts"

  def send_push(user_id, title, body) do
    user = Repo.get!(User, user_id)

    if is_nil(user.device_token) do
      {:error, :no_device_token}
    else
      payload = %{
        to: user.device_token,
        notification: %{title: title, body: body},
        data: %{user_id: user_id}
      }

      result =
        MyApp.HTTPClient.post(@push_provider_url, payload,
          headers: [
            {"Authorization", "key=#{fcm_server_key()}"},
            {"Content-Type", "application/json"}
          ]
        )

      with {:ok, _response} <- result do
        record_delivery(user_id, :push, :delivered)
        :ok
      end
    end
  end

  def send_sms(user_id, message_body) do
    user = Repo.get!(User, user_id)

    if is_nil(user.phone_number) do
      {:error, :no_phone_number}
    else
      account_sid = Application.fetch_env!(:my_app, :twilio_account_sid)
      auth_token = Application.fetch_env!(:my_app, :twilio_auth_token)
      from_number = Application.fetch_env!(:my_app, :twilio_from_number)

      url = "#{@sms_provider_url}/#{account_sid}/Messages.json"

      payload = %{
        "From" => from_number,
        "To" => user.phone_number,
        "Body" => message_body
      }

      with {:ok, _response} <- MyApp.HTTPClient.post_form(url, payload, basic_auth: {account_sid, auth_token}) do
        record_delivery(user_id, :sms, :delivered)
        :ok
      end
    end
  end

  def send_email(user_id, subject, html_body) do
    user = Repo.get!(User, user_id)

    %{
      from: "notifications@myapp.io",
      to: user.email,
      subject: subject,
      html_body: html_body
    }
    |> MyApp.Mailer.deliver()
    |> case do
      {:ok, _} ->
        record_delivery(user_id, :email, :delivered)
        :ok

      {:error, reason} ->
        record_delivery(user_id, :email, :failed)
        {:error, reason}
    end
  end

  defp fcm_server_key, do: Application.fetch_env!(:my_app, :fcm_server_key)


  def upsert_template(name, channel, body_template) when channel in [:push, :sms, :email] do
    case Repo.get_by(Template, name: name, channel: channel) do
      nil ->
        %Template{}
        |> Template.changeset(%{name: name, channel: channel, body: body_template})
        |> Repo.insert()

      existing ->
        existing
        |> Template.changeset(%{body: body_template})
        |> Repo.update()
    end
  end

  def render_template(name, channel, variables) when is_map(variables) do
    case Repo.get_by(Template, name: name, channel: channel) do
      nil ->
        {:error, :template_not_found}

      template ->
        rendered =
          Enum.reduce(variables, template.body, fn {key, value}, acc ->
            String.replace(acc, "{{#{key}}}", to_string(value))
          end)

        if String.contains?(rendered, "{{") do
          missing =
            Regex.scan(~r/\{\{(\w+)\}\}/, rendered, capture: :all_but_first)
            |> List.flatten()

          {:error, {:unresolved_variables, missing}}
        else
          {:ok, rendered}
        end
    end
  end


  def record_delivery(user_id, channel, status) do
    %DeliveryRecord{}
    |> DeliveryRecord.changeset(%{
      user_id: user_id,
      channel: channel,
      status: status,
      occurred_at: DateTime.utc_now()
    })
    |> Repo.insert()
  end

  def delivery_stats(user_id, since) do
    from(d in DeliveryRecord,
      where: d.user_id == ^user_id and d.occurred_at >= ^since,
      group_by: [d.channel, d.status],
      select: %{
        channel: d.channel,
        status: d.status,
        count: count(d.id)
      }
    )
    |> Repo.all()
    |> Enum.group_by(& &1.channel)
  end

end
```
