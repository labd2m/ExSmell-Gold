```elixir
defmodule SecureRandom do
  def random_bytes(n), do: :crypto.strong_rand_bytes(n)

  def hex(n), do: random_bytes(n) |> Base.encode16(case: :lower)

  def url_safe_base64(n) do
    random_bytes(n) |> Base.url_encode64(padding: false)
  end
end

defmodule CryptoHelpers do
  defmacro __using__(_opts) do
    quote do
      import SecureRandom

      @pbkdf2_iterations 200_000
      @salt_length       32
      @token_byte_length 48

      def hash_password(password) do
        salt   = random_bytes(@salt_length)
        digest = :crypto.pbkdf2_hmac(:sha256, password, salt, @pbkdf2_iterations, 32)
        encoded_salt   = Base.encode64(salt)
        encoded_digest = Base.encode64(digest)
        "pbkdf2:sha256:#{@pbkdf2_iterations}:#{encoded_salt}:#{encoded_digest}"
      end

      def verify_password(password, stored_hash) do
        case String.split(stored_hash, ":") do
          ["pbkdf2", "sha256", iter_str, salt_b64, digest_b64] ->
            iter   = String.to_integer(iter_str)
            salt   = Base.decode64!(salt_b64)
            stored = Base.decode64!(digest_b64)
            computed = :crypto.pbkdf2_hmac(:sha256, password, salt, iter, 32)
            :crypto.hash_equals(stored, computed)
          _ ->
            false
        end
      end

      def generate_token(extra_entropy \\ 0) do
        base  = url_safe_base64(@token_byte_length)
        extra = if extra_entropy > 0, do: hex(extra_entropy), else: ""
        base <> extra
      end
    end
  end
end

defmodule AuthService do
  use CryptoHelpers

  @token_ttl_seconds 3_600
  @max_attempts      5

  def register(params) do
    with {:ok, _} <- validate_params(params),
         hashed   <- hash_password(params.password) do
      {:ok, %{
        id:              generate_token(4),
        email:           String.downcase(params.email),
        password_hash:   hashed,
        confirmed:       false,
        confirmation_token: generate_token(),
        inserted_at:     DateTime.utc_now()
      }}
    end
  end

  def login(email, password, credential_store) do
    with {:ok, user} <- fetch_user(email, credential_store),
         true        <- verify_password(password, user.password_hash),
         false       <- locked_out?(user) do
      token = generate_token()
      {:ok, %{
        user_id:    user.id,
        token:      token,
        expires_at: DateTime.add(DateTime.utc_now(), @token_ttl_seconds, :second)
      }}
    else
      false -> {:error, :invalid_credentials}
      {:error, _} = err -> err
    end
  end

  def change_password(user, old_password, new_password) do
    if verify_password(old_password, user.password_hash) do
      {:ok, %{user | password_hash: hash_password(new_password)}}
    else
      {:error, :wrong_password}
    end
  end

  def reset_token(user) do
    token = generate_token()
    {:ok, %{user | reset_token: token, reset_token_issued_at: DateTime.utc_now()}}
  end

  defp validate_params(%{email: e, password: p})
       when is_binary(e) and is_binary(p) and byte_size(p) >= 8,
       do: {:ok, :valid}
  defp validate_params(_), do: {:error, :invalid_params}

  defp fetch_user(email, store) do
    case Map.get(store, String.downcase(email)) do
      nil  -> {:error, :not_found}
      user -> {:ok, user}
    end
  end

  defp locked_out?(%{failed_attempts: n}) when n >= @max_attempts, do: true
  defp locked_out?(_), do: false
end
```
