```elixir
defmodule MyApp.Accounts.RateLimitedLogin do
  @moduledoc """
  Wraps the standard authentication flow with per-IP and per-email rate
  limiting to slow brute-force attacks. Both limits are checked before
  credentials are verified; a successful login resets the per-email
  counter while the per-IP counter decays naturally through the token
  bucket refill mechanism.
  """

  alias MyApp.Accounts
  alias MyApp.RateLimiter

  @ip_limit_key_prefix "login_ip:"
  @email_limit_key_prefix "login_email:"

  @type ip_address :: String.t()
  @type credentials :: %{email: String.t(), password: String.t()}

  @doc """
  Attempts to authenticate `credentials` from `ip_address`. Returns
  `{:ok, user}` on success or a structured error on failure, including
  rate-limit errors before credentials are checked.
  """
  @spec attempt(ip_address(), credentials()) ::
          {:ok, MyApp.Accounts.User.t()}
          | {:error, :rate_limited_ip}
          | {:error, :rate_limited_email}
          | {:error, :invalid_credentials}
          | {:error, :not_found}
  def attempt(ip_address, %{email: email, password: password})
      when is_binary(ip_address) and is_binary(email) and is_binary(password) do
    with :ok <- check_ip_limit(ip_address),
         :ok <- check_email_limit(email),
         {:ok, user} <- Accounts.authenticate(email, password) do
      RateLimiter.reset(@email_limit_key_prefix <> String.downcase(email))
      {:ok, user}
    else
      {:error, :rate_limited} -> {:error, classify_rate_limit(ip_address, email)}
      {:error, :invalid_credentials} = e -> e
      {:error, :not_found} = e -> e
    end
  end

  @spec check_ip_limit(ip_address()) :: :ok | {:error, :rate_limited}
  defp check_ip_limit(ip) do
    RateLimiter.check(@ip_limit_key_prefix <> ip)
    |> case do
      {:ok, _} -> :ok
      {:error, :rate_limited} -> {:error, :rate_limited}
    end
  end

  @spec check_email_limit(String.t()) :: :ok | {:error, :rate_limited}
  defp check_email_limit(email) do
    RateLimiter.check(@email_limit_key_prefix <> String.downcase(email))
    |> case do
      {:ok, _} -> :ok
      {:error, :rate_limited} -> {:error, :rate_limited}
    end
  end

  @spec classify_rate_limit(ip_address(), String.t()) ::
          :rate_limited_ip | :rate_limited_email
  defp classify_rate_limit(ip, email) do
    ip_ok = match?({:ok, _}, RateLimiter.peek(@ip_limit_key_prefix <> ip))
    email_ok = match?({:ok, _}, RateLimiter.peek(@email_limit_key_prefix <> String.downcase(email)))

    cond do
      not ip_ok -> :rate_limited_ip
      not email_ok -> :rate_limited_email
      true -> :rate_limited_ip
    end
  end
end
```
