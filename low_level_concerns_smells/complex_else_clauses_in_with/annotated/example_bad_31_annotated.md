# Annotated Example 31 — Complex else clauses in with

## Metadata

- **Smell name:** Complex else clauses in with
- **Expected smell location:** `register_user/1`, inside the `with` expression's `else` block
- **Affected function(s):** `register_user/1`
- **Short explanation:** Five distinct registration steps each return structurally different error shapes. Lumping all of them into one `else` block means a reader must scan every clause to understand which step a given error came from, reducing readability and making the function harder to extend.

---

```elixir
defmodule Accounts.RegistrationService do
  @moduledoc """
  Manages new user registration, including payload validation,
  duplicate detection, credential hashing, persistence, and
  welcome email dispatch.
  """

  alias Accounts.{UserRepo, CredentialHasher, EmailService, RateLimiter}
  require Logger

  @doc """
  Registers a new user from the given `attrs` map.

  Expected keys: `:email`, `:password`, `:name`, `:plan`.

  Returns `{:ok, user}` or a structured error tuple.
  """
  @spec register_user(map()) ::
          {:ok, map()}
          | {:error, :invalid_input, list()}
          | {:error, :rate_limited}
          | {:error, :email_taken}
          | {:error, :hash_failed}
          | {:error, :db_error, term()}
  def register_user(attrs) do
    # VALIDATION: SMELL START - Complex else clauses in with
    # VALIDATION: This is a smell because five with-clauses each fail with a
    # unique error shape. The else block collapses all of them into one place,
    # forcing the reader to cross-reference the clauses above and the patterns
    # below to understand failure provenance.
    with {:ok, params}        <- validate_input(attrs),
         :ok                  <- RateLimiter.check(:registration, params.email),
         :ok                  <- assert_email_available(params.email),
         {:ok, password_hash} <- CredentialHasher.hash(params.password),
         {:ok, user}          <- UserRepo.insert(%{
                                   email:         params.email,
                                   name:          params.name,
                                   plan:          params.plan,
                                   password_hash: password_hash,
                                   inserted_at:   DateTime.utc_now()
                                 }) do
      EmailService.send_welcome(user.email, user.name)
      Logger.info("New user registered: #{user.id}")
      {:ok, user}
    else
      {:error, :validation, errors} ->
        {:error, :invalid_input, errors}

      {:error, :rate_limit_exceeded} ->
        Logger.warn("Registration rate-limited for #{attrs[:email]}")
        {:error, :rate_limited}

      {:error, :conflict} ->
        {:error, :email_taken}

      {:error, :hash_error} ->
        Logger.error("Password hashing subsystem failure")
        {:error, :hash_failed}

      {:error, %Ecto.Changeset{} = cs} ->
        Logger.error("DB insert failed: #{inspect(cs.errors)}")
        {:error, :db_error, cs.errors}
    end
    # VALIDATION: SMELL END
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp validate_input(attrs) do
    errors =
      []
      |> maybe_add_error(:email,    valid_email?(attrs[:email]),    "is invalid or missing")
      |> maybe_add_error(:password, valid_password?(attrs[:password]), "must be at least 12 chars")
      |> maybe_add_error(:name,     is_binary(attrs[:name]) and attrs[:name] != "", "is required")
      |> maybe_add_error(:plan,     attrs[:plan] in [:free, :pro, :enterprise], "is not a valid plan")

    if errors == [] do
      {:ok, %{
        email:    String.downcase(attrs[:email]),
        password: attrs[:password],
        name:     attrs[:name],
        plan:     attrs[:plan]
      }}
    else
      {:error, :validation, errors}
    end
  end

  defp assert_email_available(email) do
    case UserRepo.get_by_email(email) do
      nil -> :ok
      _   -> {:error, :conflict}
    end
  end

  defp valid_email?(email) when is_binary(email) do
    String.match?(email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/)
  end
  defp valid_email?(_), do: false

  defp valid_password?(pw) when is_binary(pw), do: String.length(pw) >= 12
  defp valid_password?(_), do: false

  defp maybe_add_error(errors, _field, true, _msg), do: errors
  defp maybe_add_error(errors, field, false, msg), do: [{field, msg} | errors]
end
```
