```elixir
defmodule UserManagement.OnboardingService do
  @moduledoc """
  Handles new user onboarding, including address validation, tax configuration,
  and provisioning of the user's workspace.
  """

  require Logger

  alias UserManagement.{
    UserRepo,
    AddressValidator,
    TaxConfigResolver,
    WorkspaceProvisioner,
    WelcomeMailer
  }

  @spec onboard(map()) :: {:ok, map()} | {:error, term()}
  def onboard(params) do
    Logger.info("Starting user onboarding", email: params["email"])

    with {:ok, validated_params} <- validate_params(params),
         {:ok, address} <- build_address(validated_params),
         {:ok, _} <- AddressValidator.validate(address),
         {:ok, tax_config} <- TaxConfigResolver.resolve(address.country),
         {:ok, user} <- UserRepo.create(build_user_attrs(validated_params, address)),
         {:ok, workspace} <- WorkspaceProvisioner.provision(user),
         :ok <- WelcomeMailer.send(user) do
      Logger.info("User onboarding complete", user_id: user.id)
      {:ok, %{user: user, workspace: workspace, tax_config: tax_config}}
    else
      {:error, reason} = err ->
        Logger.error("Onboarding failed", email: params["email"], reason: inspect(reason))
        err
    end
  end

  defp validate_params(params) do
    required = ~w(email first_name last_name password address)

    missing = Enum.reject(required, &Map.has_key?(params, &1))

    if missing == [],
      do: {:ok, params},
      else: {:error, {:missing_required_fields, missing}}
  end

  defp build_user_attrs(params, address) do
    %{
      email: String.downcase(params["email"]),
      first_name: params["first_name"],
      last_name: params["last_name"],
      password_hash: hash_password(params["password"]),
      address_id: address.id,
      onboarded_at: DateTime.utc_now()
    }
  end

  defp build_address(%{"address" => addr_params}) do
    with {:ok, country} <- parse_country_code(addr_params["country"]) do
      address = %{
        line1: addr_params["line1"],
        line2: addr_params["line2"],
        city: addr_params["city"],
        state: addr_params["state"],
        postal_code: addr_params["postal_code"],
        country: country
      }

      {:ok, address}
    end
  end

  defp parse_country_code(nil), do: {:error, :missing_country_code}

  defp parse_country_code(code) when is_binary(code) do
    normalized =
      code
      |> String.trim()
      |> String.upcase()

    {:ok, String.to_atom(normalized)}
  end

  defp parse_country_code(_), do: {:error, :invalid_country_code}

  defp hash_password(password) do
    Bcrypt.hash_pwd_salt(password)
  end
end
```
