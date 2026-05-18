# Annotated Example 10 — Unnecessary Macros

## Metadata

- **Smell name:** Unnecessary macros
- **Expected smell location:** `defmacro retry/2` inside `UserManagement.RetryUtils`
- **Affected function(s):** `retry/2`
- **Short explanation:** The macro implements a simple retry loop using `Enum.reduce_while` over a runtime range. This is entirely expressible as a higher-order function; no AST manipulation is performed or needed, and the macro form makes the code harder to follow.

---

```elixir
defmodule UserManagement.RetryUtils do
  @moduledoc """
  Provides a generic retry mechanism for transient failures
  in user management operations such as email delivery and token issuance.
  """

  # VALIDATION: SMELL START - Unnecessary macros
  # VALIDATION: This is a smell because retry/2 implements a retry loop using
  # only runtime control flow (Enum.reduce_while, function calls). No AST
  # transformation is required; this belongs as a regular higher-order function.
  defmacro retry(attempts, fun) do
    quote do
      f = unquote(fun)
      n = unquote(attempts)

      Enum.reduce_while(1..n, {:error, :not_started}, fn attempt, _acc ->
        case f.(attempt) do
          {:ok, result} -> {:halt, {:ok, result}}
          {:error, reason} when attempt < n -> {:cont, {:error, reason}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end
  # VALIDATION: SMELL END

  @doc """
  Returns a linear backoff duration in milliseconds for a given attempt number.
  """
  @spec backoff_ms(pos_integer()) :: non_neg_integer()
  def backoff_ms(attempt) when attempt > 0, do: attempt * 200
end

defmodule UserManagement.EmailVerificationService do
  @moduledoc """
  Manages email address verification for newly registered users,
  including token generation, delivery, and validation.
  """

  require UserManagement.RetryUtils

  alias UserManagement.RetryUtils

  @token_ttl_seconds 86_400
  @max_send_attempts 3

  @doc """
  Issues a verification token for the given user and attempts to deliver it
  via the configured email provider, retrying on transient failures.
  """
  @spec issue_and_send(map(), (map() -> {:ok, any()} | {:error, any()})) ::
          {:ok, String.t()} | {:error, any()}
  def issue_and_send(%{id: user_id, email: email}, send_fn) do
    token = generate_token()
    expires_at = DateTime.add(DateTime.utc_now(), @token_ttl_seconds, :second)

    payload = %{
      user_id: user_id,
      email: email,
      token: token,
      expires_at: expires_at
    }

    result =
      RetryUtils.retry(@max_send_attempts, fn attempt ->
        if attempt > 1 do
          Process.sleep(RetryUtils.backoff_ms(attempt - 1))
        end

        send_fn.(payload)
      end)

    case result do
      {:ok, _} -> {:ok, token}
      {:error, reason} -> {:error, {:send_failed, reason}}
    end
  end

  @doc """
  Verifies a token submitted by the user against the stored record.
  """
  @spec verify_token(String.t(), map()) :: :ok | {:error, atom()}
  def verify_token(submitted_token, stored_record) do
    cond do
      stored_record.token != submitted_token ->
        {:error, :token_mismatch}

      DateTime.compare(DateTime.utc_now(), stored_record.expires_at) == :gt ->
        {:error, :token_expired}

      stored_record.used == true ->
        {:error, :token_already_used}

      true ->
        :ok
    end
  end

  @doc """
  Returns whether a verification record is still within its validity window.
  """
  @spec valid?(map()) :: boolean()
  def valid?(%{expires_at: expires_at, used: used}) do
    not used and DateTime.compare(DateTime.utc_now(), expires_at) != :gt
  end

  defp generate_token do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end
end
```
