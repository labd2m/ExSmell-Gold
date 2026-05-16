# Example 32

```elixir
defmodule Auth.IdentityVerification do
  @moduledoc """
  Integrates with the third-party identity verification provider (IDVerify)
  to validate user documents during onboarding and periodic re-verification.
  """

  require Logger

  alias Auth.Repo
  alias Auth.Schema.{User, VerificationRecord}
  alias Auth.IDVerify.Client
  alias Auth.Mailer

  @verification_levels [:basic, :enhanced, :full_kyc]

  def start_verification(user_id, document_payload, level \\ :basic)
      when level in @verification_levels do
    with {:ok, user} <- fetch_user(user_id),
         :ok <- check_existing_verification(user),
         {:ok, session} <- Client.create_session(user.id, level) do
      verify_identity(user, Client.submit_document(session.id, document_payload))
    end
  end

  defp fetch_user(user_id) do
    case Repo.get(User, user_id) do
      nil -> {:error, :user_not_found}
      user -> {:ok, user}
    end
  end

  defp check_existing_verification(%User{verification_status: :verified}),
    do: {:error, :already_verified}

  defp check_existing_verification(_user), do: :ok

  defp verify_identity(user, provider_response) do
    case provider_response do
      {:ok, %{status: 200, body: %{"result" => "approved", "score" => score, "session_id" => sid}}} ->
        Logger.info("Identity approved for user #{user.id}, score #{score}")

        {:ok, _record} =
          Repo.insert(%VerificationRecord{
            user_id: user.id,
            session_id: sid,
            result: :approved,
            score: score
          })

        User.changeset(user, %{verification_status: :verified})
        |> Repo.update()

        Mailer.send_verification_approved(user)
        {:ok, :approved}

      {:ok, %{status: 200, body: %{"result" => "pending_review", "session_id" => sid, "eta_hours" => eta}}} ->
        Logger.info("Identity pending manual review for user #{user.id}, eta #{eta}h")

        Repo.insert(%VerificationRecord{
          user_id: user.id,
          session_id: sid,
          result: :pending_review
        })

        User.changeset(user, %{verification_status: :pending_review})
        |> Repo.update()

        {:ok, :pending_review}

      {:ok, %{status: 200, body: %{"result" => "rejected", "reason" => "document_expired"}}} ->
        Logger.warning("Document expired for user #{user.id}")
        User.changeset(user, %{verification_status: :rejected}) |> Repo.update()
        Mailer.send_verification_rejected(user, :document_expired)
        {:error, :document_expired}

      {:ok, %{status: 200, body: %{"result" => "rejected", "reason" => "document_unreadable"}}} ->
        Logger.warning("Unreadable document for user #{user.id}")
        User.changeset(user, %{verification_status: :rejected}) |> Repo.update()
        Mailer.send_verification_rejected(user, :document_unreadable)
        {:error, :document_unreadable}

      {:ok, %{status: 200, body: %{"result" => "rejected", "reason" => "name_mismatch"}}} ->
        Logger.warning("Name mismatch on document for user #{user.id}")
        User.changeset(user, %{verification_status: :rejected}) |> Repo.update()
        Mailer.send_verification_rejected(user, :name_mismatch)
        {:error, :name_mismatch}

      {:ok, %{status: 200, body: %{"result" => "rejected", "reason" => "suspected_fraud"}}} ->
        Logger.error("Fraud suspicion on user #{user.id}, flagging account")
        User.changeset(user, %{verification_status: :flagged}) |> Repo.update()
        Mailer.send_fraud_flag_notice(user)
        {:error, :suspected_fraud}

      {:ok, %{status: 401, body: %{"error" => "session_expired"}}} ->
        Logger.warning("Verification session expired for user #{user.id}")
        {:error, :session_expired}

      {:ok, %{status: 413, body: _}} ->
        Logger.warning("Document payload too large for user #{user.id}")
        {:error, :payload_too_large}

      {:ok, %{status: 429, body: _}} ->
        Logger.warning("Rate limited by IDVerify for user #{user.id}")
        {:error, :rate_limited}

      {:ok, %{status: 503, body: _}} ->
        Logger.error("IDVerify service unavailable for user #{user.id}")
        {:error, :provider_unavailable}

      {:ok, %{status: status, body: body}} ->
        Logger.error("Unexpected IDVerify response #{status} for user #{user.id}: #{inspect(body)}")
        {:error, {:unexpected_response, status}}

      {:error, %{reason: :timeout}} ->
        Logger.error("IDVerify timeout for user #{user.id}")
        {:error, :timeout}

      {:error, reason} ->
        Logger.error("IDVerify connection error for user #{user.id}: #{inspect(reason)}")
        {:error, {:provider_error, reason}}
    end
  end

  def retry_pending_verifications do
    VerificationRecord
    |> VerificationRecord.pending()
    |> Repo.all()
    |> Enum.each(fn record ->
      Logger.info("Re-checking pending verification for user #{record.user_id}")
      Client.poll_session(record.session_id)
    end)
  end
end
```
