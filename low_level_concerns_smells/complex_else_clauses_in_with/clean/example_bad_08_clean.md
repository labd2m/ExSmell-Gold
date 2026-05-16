```elixir
defmodule Accounts.UserOnboarding do
  alias Accounts.{Repo, User, EmailVerification, ResourceProvisioner, CRMClient}

  require Logger

  @default_plan :starter

  def onboard_user(params, invited_by \\ nil) do
    with {:ok, validated} <- validate_params(params),
         :ok <- check_no_duplicate(validated.email),
         {:ok, user} <- create_user(validated, invited_by),
         {:ok, _token} <- EmailVerification.send_verification(user),
         {:ok, _resources} <- ResourceProvisioner.provision(user, @default_plan),
         {:ok, _crm_contact} <- CRMClient.create_contact(user) do
      Logger.info("User #{user.id} onboarded successfully (invited_by=#{inspect(invited_by)})")
      {:ok, user}
    else
      {:error, :invalid_params} ->
        {:error, :validation_failed}

      {:error, {:validation, errors}} ->
        {:error, {:validation_failed, errors}}

      {:error, :email_taken} ->
        Logger.warning("Onboarding blocked: email already registered (#{params["email"]})")
        {:error, :email_already_registered}

      {:error, :changeset_error, changeset} ->
        Logger.error("User record creation failed: #{inspect(changeset.errors)}")
        {:error, :user_creation_failed}

      {:error, :email_delivery_failed} ->
        Logger.error("Verification email could not be sent")
        {:error, :email_delivery_failed}

      {:error, :provisioning_failed} ->
        Logger.error("Default resource provisioning failed")
        {:error, :provisioning_error}

      {:error, :crm_unavailable} ->
        Logger.warning("CRM contact creation skipped — service unavailable")
        {:error, :crm_sync_failed}

      {:error, reason} ->
        Logger.error("Unhandled onboarding error: #{inspect(reason)}")
        {:error, :internal_error}
    end
  end

  defp validate_params(%{"email" => email, "password" => password} = params)
       when is_binary(email) and is_binary(password) do
    errors =
      []
      |> then(fn e -> if String.match?(email, ~r/@/), do: e, else: [{:email, "invalid"} | e] end)
      |> then(fn e -> if String.length(password) >= 8, do: e, else: [{:password, "too short"} | e] end)

    if errors == [] do
      {:ok, %{email: String.downcase(email), password: password, name: params["name"]}}
    else
      {:error, {:validation, errors}}
    end
  end

  defp validate_params(_), do: {:error, :invalid_params}

  defp check_no_duplicate(email) do
    if Repo.exists?(from u in User, where: u.email == ^email) do
      {:error, :email_taken}
    else
      :ok
    end
  end

  defp create_user(validated, invited_by) do
    %User{}
    |> User.registration_changeset(%{
      email: validated.email,
      password: validated.password,
      name: validated.name,
      invited_by: invited_by,
      plan: @default_plan
    })
    |> Repo.insert()
    |> case do
      {:ok, user} -> {:ok, user}
      {:error, changeset} -> {:error, :changeset_error, changeset}
    end
  end
end
```
