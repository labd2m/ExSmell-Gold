```elixir
defmodule HR.CandidateOnboarding do
  @moduledoc """
  Manages end-to-end candidate onboarding: application validation,
  background check initiation, offer letter generation, system account
  provisioning, and welcome package dispatch.
  """

  alias HR.{
    ApplicationValidator,
    BackgroundCheckService,
    OfferLetterGenerator,
    AccountProvisioner,
    WelcomeMailer
  }

  require Logger

  @doc """
  Onboards the candidate identified by `candidate_id` using `onboarding_data`.

  `onboarding_data` must include `:position_id`, `:start_date`, and `:offer_details`.

  Returns `{:ok, onboarding_record}` or a structured error.
  """
  @spec onboard_candidate(String.t(), map()) ::
          {:ok, map()}
          | {:error, :invalid_application}
          | {:error, :background_check_failed, String.t()}
          | {:error, :offer_letter_failed}
          | {:error, :provisioning_failed, String.t()}
          | {:error, :welcome_email_failed}
  def onboard_candidate(candidate_id, onboarding_data) do
    with {:ok, application}  <- ApplicationValidator.validate(candidate_id, onboarding_data),
         {:ok, bgc_ref}      <- BackgroundCheckService.initiate(candidate_id, application),
         {:ok, letter}       <- OfferLetterGenerator.generate(application, onboarding_data.offer_details),
         {:ok, account}      <- AccountProvisioner.provision(%{
                                  candidate_id: candidate_id,
                                  position_id:  onboarding_data.position_id,
                                  start_date:   onboarding_data.start_date,
                                  email:        application.email
                                }),
         :ok                 <- WelcomeMailer.send(application.email, %{
                                  name:       application.full_name,
                                  start_date: onboarding_data.start_date,
                                  letter_url: letter.url,
                                  login_url:  account.login_url
                                }) do
      record = %{
        candidate_id:    candidate_id,
        position_id:     onboarding_data.position_id,
        bgc_reference:   bgc_ref,
        account_id:      account.id,
        offer_letter_url: letter.url,
        onboarded_at:    DateTime.utc_now()
      }

      Logger.info("Candidate #{candidate_id} onboarded successfully, account=#{account.id}")
      {:ok, record}
    else
      {:error, :invalid, reasons} ->
        Logger.warn("Application invalid for #{candidate_id}: #{inspect(reasons)}")
        {:error, :invalid_application}

      {:error, :bgc, reason} ->
        Logger.error("Background check failed for #{candidate_id}: #{reason}")
        {:error, :background_check_failed, reason}

      {:error, :letter, detail} ->
        Logger.error("Offer letter generation failed: #{inspect(detail)}")
        {:error, :offer_letter_failed}

      {:error, :provision, system} ->
        Logger.error("Account provisioning failed in #{system} for #{candidate_id}")
        {:error, :provisioning_failed, system}

      {:error, :mail} ->
        Logger.error("Welcome email failed for #{candidate_id}")
        {:error, :welcome_email_failed}
    end
  end
end
```
