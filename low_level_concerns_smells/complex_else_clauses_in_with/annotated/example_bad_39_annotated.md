# Annotated Example 39 — Complex else clauses in with

## Metadata

- **Smell name:** Complex else clauses in with
- **Expected smell location:** `exchange_code/2`, inside the `with` expression's `else` block
- **Affected function(s):** `exchange_code/2`
- **Short explanation:** Five OAuth2 steps each produce distinct failure shapes. The single `else` block must match all of them in one flat list, erasing the structural link between a specific step and the errors it generates.

---

```elixir
defmodule Auth.OAuth2.CodeExchange do
  @moduledoc """
  Handles the OAuth2 authorization code exchange flow:
  code validation, provider token request, profile fetch,
  local account resolution, and session creation.
  """

  alias Auth.OAuth2.{
    CodeVerifier,
    ProviderClient,
    ProfileNormalizer,
    AccountResolver,
    SessionFactory
  }

  require Logger

  @doc """
  Exchanges an OAuth2 authorization `code` from `provider` for a local session.

  `params` must contain `:code_verifier` (for PKCE) and `:redirect_uri`.

  Returns `{:ok, session_token}` or a structured error.
  """
  @spec exchange_code(atom(), map()) ::
          {:ok, String.t()}
          | {:error, :invalid_code}
          | {:error, :provider_error, String.t()}
          | {:error, :profile_parse_failed}
          | {:error, :account_suspended}
          | {:error, :session_error}
  def exchange_code(provider, params) do
    # VALIDATION: SMELL START - Complex else clauses in with
    # VALIDATION: This is a smell because five with-clauses each produce a
    # distinct error shape ({:error, :invalid}, {:error, :provider, _},
    # {:error, :parse}, {:suspended, _}, {:error, :session, _}).
    # Placing all in a single else block obscures which step triggered a given
    # error pattern, making debugging and extension harder.
    with {:ok, code}    <- CodeVerifier.verify(provider, params),
         {:ok, tokens}  <- ProviderClient.exchange(provider, code, params.redirect_uri),
         {:ok, profile} <- ProfileNormalizer.parse(provider, tokens.access_token),
         {:ok, account} <- AccountResolver.resolve_or_create(provider, profile),
         {:ok, session} <- SessionFactory.create(account, %{
                             provider:     provider,
                             access_token: tokens.access_token,
                             expires_in:   tokens.expires_in
                           }) do
      Logger.info("OAuth2 session created for account #{account.id} via #{provider}")
      {:ok, session.token}
    else
      {:error, :invalid} ->
        Logger.warn("Invalid or expired authorization code for provider #{provider}")
        {:error, :invalid_code}

      {:error, :provider, description} ->
        Logger.warn("Provider #{provider} error: #{description}")
        {:error, :provider_error, description}

      {:error, :parse} ->
        Logger.error("Failed to parse profile from provider #{provider}")
        {:error, :profile_parse_failed}

      {:suspended, reason} ->
        Logger.warn("Account suspended: #{reason}")
        {:error, :account_suspended}

      {:error, :session, detail} ->
        Logger.error("Session creation failed: #{inspect(detail)}")
        {:error, :session_error}
    end
    # VALIDATION: SMELL END
  end
end
```
