```elixir
defmodule Vault.EncryptedField do
  @moduledoc """
  An Ecto custom type that transparently encrypts field values on write
  and decrypts them on read using AES-256-GCM authenticated encryption.
  The secret key is fetched at runtime from application configuration,
  never baked into module attributes.
  """

  use Ecto.Type

  @aad "vault_encrypted_field_v1"
  @iv_bytes 16
  @tag_bytes 16

  @impl Ecto.Type
  def type, do: :binary

  @impl Ecto.Type
  def cast(value) when is_binary(value), do: {:ok, value}
  def cast(nil), do: {:ok, nil}
  def cast(_), do: :error

  @impl Ecto.Type
  def load(nil), do: {:ok, nil}

  def load(ciphertext) when is_binary(ciphertext) do
    decrypt(ciphertext)
  end

  @impl Ecto.Type
  def dump(nil), do: {:ok, nil}

  def dump(plaintext) when is_binary(plaintext) do
    encrypt(plaintext)
  end

  def dump(_), do: :error

  @spec encrypt(String.t()) :: {:ok, binary()} | {:error, :encryption_failed}
  def encrypt(plaintext) when is_binary(plaintext) do
    key = fetch_key()
    iv = :crypto.strong_rand_bytes(@iv_bytes)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, @aad, @tag_bytes, true)

    blob = iv <> tag <> ciphertext
    {:ok, blob}
  rescue
    _ -> {:error, :encryption_failed}
  end

  @spec decrypt(binary()) :: {:ok, String.t()} | {:error, atom()}
  def decrypt(blob) when is_binary(blob) and byte_size(blob) > @iv_bytes + @tag_bytes do
    key = fetch_key()
    <<iv::binary-size(@iv_bytes), tag::binary-size(@tag_bytes), ciphertext::binary>> = blob

    case :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ciphertext, @aad, tag, false) do
      plaintext when is_binary(plaintext) -> {:ok, plaintext}
      :error -> {:error, :decryption_failed}
    end
  rescue
    _ -> {:error, :decryption_failed}
  end

  def decrypt(_), do: {:error, :invalid_ciphertext}

  defp fetch_key do
    raw = Application.fetch_env!(:vault, :encryption_key)
    decode_key(raw)
  end

  defp decode_key(key) when is_binary(key) and byte_size(key) == 32, do: key

  defp decode_key(key) when is_binary(key) do
    case Base.decode64(key) do
      {:ok, decoded} when byte_size(decoded) == 32 -> decoded
      _ -> raise ArgumentError, "vault encryption key must be 32 bytes"
    end
  end
end

defmodule Vault.EncryptedSchema do
  @moduledoc """
  Provides the `encrypted_field/2` macro for Ecto schemas, which wires
  up `Vault.EncryptedField` as the field's Ecto type and enforces
  that the underlying column is stored as `:binary`.
  """

  defmacro __using__(_opts) do
    quote do
      import Vault.EncryptedSchema, only: [encrypted_field: 1, encrypted_field: 2]
    end
  end

  defmacro encrypted_field(name, opts \\ []) do
    quote do
      field(unquote(name), Vault.EncryptedField, unquote(opts))
    end
  end
end
```
