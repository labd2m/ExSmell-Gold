# Annotated Example 47 — Complex else clauses in with

## Metadata

- **Smell name:** Complex else clauses in with
- **Expected smell location:** `onboard_candidate/2`, inside the `with` expression's `else` block
- **Affected function(s):** `onboard_candidate/2`
- **Short explanation:** Five HR onboarding steps produce structurally distinct failures. Grouping all of them in a single `else` block obscures which step produced a given error and increases the risk of incorrectly handling a new error shape introduced during maintenance.

---

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
    # VALIDATION: SMELL START - Complex else clauses in with
    # VALIDATION: This is a smell because five with-clauses each produce a
    # distinct error shape ({:error, :invalid, _}, {:error, :bgc, _},
    # {:error, :letter, _}, {:error, :provision, _}, {:error, :mail}).
    # The flat else block merges all into one list, making it opaque which
    # step a given pattern originated from.
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
    # VALIDATION: SMELL END
  end
end
```
