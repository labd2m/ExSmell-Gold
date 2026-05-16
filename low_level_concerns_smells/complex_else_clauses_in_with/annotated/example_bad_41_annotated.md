# Annotated Example 41 — Complex else clauses in with

## Metadata

- **Smell name:** Complex else clauses in with
- **Expected smell location:** `reset_password/2`, inside the `with` expression's `else` block
- **Affected function(s):** `reset_password/2`
- **Short explanation:** Four steps in the password reset pipeline each produce distinct error shapes. All are merged into one `else` block, creating an undifferentiated list that hides the step-to-error relationship and makes the function harder to reason about.

---

```elixir
defmodule Accounts.PasswordReset do
  @moduledoc """
  Handles the complete password-reset flow: token validation,
  password policy enforcement, credential update, and notification.
  """

  alias Accounts.{ResetTokenStore, PasswordPolicy, CredentialStore, NotificationService}
  require Logger

  @doc """
  Resets the password for the user associated with `token`.

  Returns `{:ok, user_id}` or a descriptive error.
  """
  @spec reset_password(String.t(), String.t()) ::
          {:ok, String.t()}
          | {:error, :token_invalid}
          | {:error, :token_expired}
          | {:error, :policy_violation, list()}
          | {:error, :update_failed}
  def reset_password(token, new_password) do
    # VALIDATION: SMELL START - Complex else clauses in with
    # VALIDATION: This is a smell because four with-clauses each fail with
    # a structurally different shape ({:error, :invalid}, {:error, :expired, _},
    # {:error, :policy, _}, {:error, :update, _}).
    # The flat else block mixes them all, hiding which step produced which error.
    with {:ok, claims}  <- ResetTokenStore.verify(token),
         :ok            <- check_expiry(claims),
         :ok            <- PasswordPolicy.validate(new_password),
         {:ok, user_id} <- CredentialStore.update_password(claims["sub"], new_password) do
      ResetTokenStore.revoke(token)
      NotificationService.send_password_changed(claims["sub"])
      Logger.info("Password reset completed for user #{claims["sub"]}")
      {:ok, user_id}
    else
      {:error, :invalid} ->
        Logger.warn("Invalid reset token presented")
        {:error, :token_invalid}

      {:error, :expired, expired_at} ->
        Logger.info("Reset token expired at #{expired_at}")
        {:error, :token_expired}

      {:error, :policy, violations} ->
        Logger.debug("Password policy violations: #{inspect(violations)}")
        {:error, :policy_violation, violations}

      {:error, :update, detail} ->
        Logger.error("Credential update failed: #{inspect(detail)}")
        {:error, :update_failed}
    end
    # VALIDATION: SMELL END
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp check_expiry(%{"exp" => exp}) do
    if System.system_time(:second) > exp do
      {:error, :expired, DateTime.from_unix!(exp)}
    else
      :ok
    end
  end

  defp check_expiry(_claims), do: {:error, :invalid}
end
```
