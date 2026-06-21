```elixir
defmodule MyApp.Ecto.EncryptedString do
  @moduledoc """
  A custom `Ecto.Type` that transparently encrypts string values with
  AES-256-GCM before writing to the database and decrypts them on read.
  Each ciphertext is prefixed with a random 12-byte IV so repeated writes
  of the same plaintext produce distinct database values, preventing
  frequency analysis.

  The encryption key is derived from the application secret via HKDF and
  is never stored alongside the data.

  ## Usage in a schema

      field :tax_id, MyApp.Ecto.EncryptedString
  """

  use Ecto.Type

  @aad "myapp_encrypted_field_v1"
  @iv_length 12
  @tag_length 16

  @impl Ecto.Type
  def type, do: :binary

  @impl Ecto.Type
  def cast(value) when is_binary(value), do: {:ok, value}
  def cast(_), do: :error

  @impl Ecto.Type
  def dump(plaintext) when is_binary(plaintext) do
    key = derive_key()
    iv = :crypto.strong_rand_bytes(@iv_length)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, @aad, @tag_length, true)

    {:ok, iv <> tag <> ciphertext}
  end

  def dump(nil), do: {:ok, nil}
  def dump(_), do: :error

  @impl Ecto.Type
  def load(nil), do: {:ok, nil}

  def load(binary) when is_binary(binary) do
    key = derive_key()

    with <<iv::binary-size(@iv_length), tag::binary-size(@tag_length), ciphertext::binary>> <- binary,
         plaintext when is_binary(plaintext) <-
           :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ciphertext, @aad, tag, false) do
      {:ok, plaintext}
    else
      _ -> :error
    end
  end

  def load(_), do: :error

  @impl Ecto.Type
  def equal?(a, b), do: a == b

  @impl Ecto.Type
  def embed_as(_), do: :self

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp derive_key do
    secret = Application.fetch_env!(:my_app, :secret_key_base)

    :crypto.mac(:hmac, :sha256, secret, "encryption:field:key:v1")
  end
end

defmodule MyApp.Ecto.EncryptedMap do
  @moduledoc """
  A custom `Ecto.Type` that JSON-serializes a map and then encrypts it
  using the same AES-256-GCM scheme as `EncryptedString`. Suitable for
  storing sensitive structured metadata such as KYC documents or PII.

  ## Usage

      field :kyc_data, MyApp.Ecto.EncryptedMap
  """

  use Ecto.Type

  @impl Ecto.Type
  def type, do: :binary

  @impl Ecto.Type
  def cast(value) when is_map(value), do: {:ok, value}
  def cast(_), do: :error

  @impl Ecto.Type
  def dump(map) when is_map(map) do
    case Jason.encode(map) do
      {:ok, json} -> MyApp.Ecto.EncryptedString.dump(json)
      {:error, _} -> :error
    end
  end

  def dump(nil), do: {:ok, nil}
  def dump(_), do: :error

  @impl Ecto.Type
  def load(nil), do: {:ok, nil}

  def load(binary) when is_binary(binary) do
    with {:ok, json} <- MyApp.Ecto.EncryptedString.load(binary),
         {:ok, map} <- Jason.decode(json) do
      {:ok, map}
    end
  end

  def load(_), do: :error

  @impl Ecto.Type
  def equal?(a, b), do: a == b

  @impl Ecto.Type
  def embed_as(_), do: :self
end
```
