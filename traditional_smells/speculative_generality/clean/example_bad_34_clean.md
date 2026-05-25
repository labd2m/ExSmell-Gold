```elixir
defmodule UserManagement.RegistrationService do
  @moduledoc """
  Handles new user registration: validates input, creates the account,
  bootstraps default settings, and triggers the welcome flow.
  """

  alias UserManagement.{Account, Profile, DefaultSettings, WelcomeMailer}

  require Logger

  @spec register(map()) :: {:ok, Account.t()} | {:error, map()}
  def register(params) do
    with {:ok, validated} <- validate_params(params),
         {:ok, account} <- Account.create(validated),
         {:ok, _profile} <- Profile.create_default(account.id, validated),
         :ok <- DefaultSettings.bootstrap(account.id),
         :ok <- WelcomeMailer.send(account) do
      Logger.info("User registered account=#{account.id} email=#{account.email}")
      {:ok, account}
    else
      {:error, %Ecto.Changeset{} = cs} ->
        {:error, format_changeset_errors(cs)}

      {:error, reason} ->
        Logger.error("Registration failed: #{inspect(reason)}")
        {:error, %{base: ["registration_failed"]}}
    end
  end

  defp validate_params(%{email: email, password: password} = params)
       when is_binary(email) and is_binary(password) do
    cond do
      String.length(email) == 0 -> {:error, %{email: ["can't be blank"]}}
      not String.contains?(email, "@") -> {:error, %{email: ["is invalid"]}}
      String.length(password) < 8 -> {:error, %{password: ["is too short"]}}
      true -> {:ok, params}
    end
  end

  defp validate_params(_), do: {:error, %{base: ["invalid_params"]}}

  defp format_changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end

defmodule UserManagement.ProfileEnricher do
  @moduledoc """
  Enriches user profile data with information from third-party providers.

  Uses the user's email domain and name to infer company affiliation,
  job title, and social profile links from external enrichment APIs.
  """

  alias UserManagement.{Profile, EnrichmentClient}

  require Logger

  @enrichment_timeout_ms 3_000
  @fallback_on_timeout true

  @spec enrich(String.t(), map()) :: {:ok, Profile.t()} | {:error, atom()}
  def enrich(account_id, %{email: email} = _base_data) do
    case fetch_enrichment(email) do
      {:ok, enrichment} ->
        apply_enrichment(account_id, enrichment)

      {:error, :timeout} when @fallback_on_timeout ->
        Logger.warning("Enrichment timeout for account=#{account_id}, skipping")
        {:ok, :skipped}

      {:error, reason} ->
        Logger.error("Enrichment failed account=#{account_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp fetch_enrichment(email) do
    domain = email |> String.split("@") |> List.last()

    Task.async(fn -> EnrichmentClient.lookup(email, domain) end)
    |> Task.await(@enrichment_timeout_ms)
  rescue
    Task.TimeoutError -> {:error, :timeout}
  end

  defp apply_enrichment(account_id, %{company: company, title: title, linkedin: linkedin}) do
    Profile.update(account_id, %{
      company: company,
      job_title: title,
      linkedin_url: linkedin,
      enriched_at: DateTime.utc_now()
    })
  end

  defp apply_enrichment(account_id, _enrichment) do
    Logger.debug("Partial enrichment result for account=#{account_id}, skipping")
    {:ok, :partial}
  end
end
```
