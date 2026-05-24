# Annotated Example — Code Smell Validation

## Metadata

- **Smell name:** Divergent Change
- **Expected smell location:** The entire `NotificationHub` module
- **Affected function(s):** `send_push/3`, `send_sms/2`, `send_email/3`, `upsert_template/3`, `render_template/3`, `record_delivery/3`, `delivery_stats/2`
- **Short explanation:** The `NotificationHub` module conflates three orthogonal responsibilities: multi-channel message dispatch (push, SMS, email), template management (create/update/render), and delivery tracking/analytics. Changes to a push notification provider, changes to template variable syntax, and changes to delivery analytics schema are all completely independent reasons to edit this module, which is the hallmark of Divergent Change.

---

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

  # VALIDATION: SMELL START - Divergent Change
  # VALIDATION: This is a smell because the module is responsible for three unrelated
  # VALIDATION: concerns that evolve independently. Channel-dispatch functions change
  # VALIDATION: when integrating new providers or updating API credentials. Template
  # VALIDATION: functions change when the variable interpolation engine or storage
  # VALIDATION: format changes. Delivery tracking functions change when analytics or
  # VALIDATION: retention requirements change. The module will be edited for all three
  # VALIDATION: unrelated reasons.

  # ── Reason to modify (1): Multi-channel dispatch ───────────────────────────

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

  # ── Reason to modify (2): Template management & rendering ──────────────────

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

  # ── Reason to modify (3): Delivery tracking & analytics ────────────────────

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

  # VALIDATION: SMELL END
end
```
