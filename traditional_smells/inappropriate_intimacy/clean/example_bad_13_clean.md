```elixir
defmodule MyApp.UserManagement.UserProvisioner do
  @moduledoc """
  Handles provisioning new users into organizations, applying
  seat limits, domain rules, and plan-tier constraints.
  """

  alias MyApp.Organizations.{Organization, OrgPlan}
  alias MyApp.Accounts.User
  alias MyApp.Auth.PasswordGenerator
  alias MyApp.Notifications.WelcomeMailer

  def provision(org_id, attrs) do
    with {:ok, org}  <- Organization.fetch(org_id),
         {:ok, plan} <- OrgPlan.for_org(org_id) do

      seat_limit       = org.seat_limit
      domain_whitelist = org.domain_whitelist
      sso_required     = org.sso_required

      allowed_roles    = plan.allowed_roles
      max_seats        = plan.max_seat_count

      email  = Map.fetch!(attrs, :email)
      role   = Map.get(attrs, :role, :member)
      domain = email |> String.split("@") |> List.last()

      current_seats = User.count_for_org(org_id)

      cond do
        current_seats >= seat_limit ->
          {:error, :seat_limit_reached}

        current_seats >= max_seats ->
          {:error, :plan_seat_limit_reached}

        domain_whitelist != [] and domain not in domain_whitelist ->
          {:error, :domain_not_allowed}

        role not in allowed_roles ->
          {:error, :role_not_allowed_on_plan}

        sso_required and not Map.get(attrs, :sso_provisioned, false) ->
          {:error, :sso_provisioning_required}

        true ->
          create_user(org, attrs, role)
      end
    end
  end

  def deprovision(user_id, org_id) do
    case User.fetch(user_id) do
      nil  -> {:error, :not_found}
      user ->
        if user.org_id != org_id do
          {:error, :user_not_in_org}
        else
          User.deactivate(user_id)
          revoke_sessions(user_id)
          {:ok, :deprovisioned}
        end
    end
  end

  def update_role(user_id, org_id, new_role) do
    with {:ok, plan} <- OrgPlan.for_org(org_id),
         {:ok, user} <- User.fetch(user_id) do
      if user.org_id != org_id do
        {:error, :user_not_in_org}
      else
        User.update(user_id, %{role: new_role})
      end
    end
  end

  def list_provisioned(org_id, opts \\ []) do
    User.list_for_org(org_id, opts)
  end


  defp create_user(org, attrs, role) do
    temp_password = PasswordGenerator.generate()
    user_attrs = %{
      email:       Map.fetch!(attrs, :email),
      name:        Map.get(attrs, :name, ""),
      org_id:      org.id,
      role:        role,
      status:      :active,
      temp_pw:     temp_password,
      created_at:  DateTime.utc_now()
    }
    case User.create(user_attrs) do
      {:ok, user} ->
        WelcomeMailer.deliver(user, temp_password)
        {:ok, user}
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp revoke_sessions(user_id) do
    :ets.match_delete(:sessions, {user_id, :_})
  end
end
```
