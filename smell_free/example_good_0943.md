```elixir
defmodule MessageSigning.Algorithm do
  @moduledoc """
  Behaviour for a pluggable message signing algorithm.
  """

  @callback sign(message :: binary(), key :: binary()) :: binary()
  @callback verify(message :: binary(), signature :: binary(), key :: binary()) :: boolean()
  @callback algorithm_id() :: String.t()
end

defmodule MessageSigning.HmacSha256 do
  @moduledoc false

  @behaviour MessageSigning.Algorithm

  @impl MessageSigning.Algorithm
  def algorithm_id, do: "hmac-sha256"

  @impl MessageSigning.Algorithm
  def sign(message, key) when is_binary(message) and is_binary(key) do
    :crypto.mac(:hmac, :sha256, key, message)
  end

  @impl MessageSigning.Algorithm
  def verify(message, signature, key) when is_binary(message) and is_binary(key) do
    expected = sign(message, key)
    :crypto.hash_equals(expected, signature)
  end
end

defmodule MessageSigning.HmacSha512 do
  @moduledoc false

  @behaviour MessageSigning.Algorithm

  @impl MessageSigning.Algorithm
  def algorithm_id, do: "hmac-sha512"

  @impl MessageSigning.Algorithm
  def sign(message, key) when is_binary(message) and is_binary(key) do
    :crypto.mac(:hmac, :sha512, key, message)
  end

  @impl MessageSigning.Algorithm
  def verify(message, signature, key) do
    expected = sign(message, key)
    :crypto.hash_equals(expected, signature)
  end
end

defmodule MessageSigning.Envelope do
  @moduledoc false

  @type t :: %__MODULE__{
          algorithm: String.t(),
          signature: String.t(),
          signed_at: integer(),
          key_id: String.t() | nil
        }

  defstruct [:algorithm, :signature, :signed_at, :key_id]
end

defmodule MessageSigning do
  @moduledoc """
  Produces and verifies detached HMAC signatures over arbitrary binary
  payloads.

  Signatures are emitted as `Envelope` structs carrying the algorithm ID,
  a Base64-encoded signature, a timestamp, and an optional key identifier
  for key-ring lookup. Verification is timing-safe. The algorithm is
  dispatched by the `algorithm_id` string stored in the envelope, so
  rolling to a stronger algorithm requires no schema migration.
  """

  alias MessageSigning.{Algorithm, Envelope, HmacSha256, HmacSha512}

  @algorithms %{
    "hmac-sha256" => HmacSha256,
    "hmac-sha512" => HmacSha512
  }

  @spec sign(binary(), binary(), keyword()) :: Envelope.t()
  def sign(message, key, opts \\ []) when is_binary(message) and is_binary(key) do
    algorithm_id = Keyword.get(opts, :algorithm, "hmac-sha256")
    algorithm = Map.fetch!(@algorithms, algorithm_id)
    raw_sig = algorithm.sign(message, key)

    %Envelope{
      algorithm: algorithm_id,
      signature: Base.url_encode64(raw_sig, padding: false),
      signed_at: System.system_time(:second),
      key_id: Keyword.get(opts, :key_id)
    }
  end

  @spec verify(binary(), Envelope.t(), binary()) ::
          :ok | {:error, :invalid_signature | :unknown_algorithm | :signature_expired}
  def verify(message, %Envelope{} = envelope, key, opts \\ [])
      when is_binary(message) and is_binary(key) do
    max_age_seconds = Keyword.get(opts, :max_age_seconds, nil)

    with {:ok, algorithm} <- resolve_algorithm(envelope.algorithm),
         {:ok, raw_sig} <- decode_signature(envelope.signature),
         :ok <- check_age(envelope.signed_at, max_age_seconds) do
      if algorithm.verify(message, raw_sig, key) do
        :ok
      else
        {:error, :invalid_signature}
      end
    end
  end

  @spec sign_and_encode(binary(), binary(), keyword()) :: String.t()
  def sign_and_encode(message, key, opts \\ []) do
    envelope = sign(message, key, opts)
    Jason.encode!(%{
      "alg" => envelope.algorithm,
      "sig" => envelope.signature,
      "iat" => envelope.signed_at,
      "kid" => envelope.key_id
    })
  end

  @spec decode_envelope(String.t()) :: {:ok, Envelope.t()} | {:error, :invalid_envelope}
  def decode_envelope(json) when is_binary(json) do
    with {:ok, %{"alg" => alg, "sig" => sig, "iat" => iat}} <- Jason.decode(json) do
      {:ok, %Envelope{algorithm: alg, signature: sig, signed_at: iat}}
    else
      _ -> {:error, :invalid_envelope}
    end
  end

  defp resolve_algorithm(id) do
    case Map.fetch(@algorithms, id) do
      {:ok, _} = ok -> ok
      :error -> {:error, :unknown_algorithm}
    end
  end

  defp decode_signature(b64) do
    case Base.url_decode64(b64, padding: false) do
      {:ok, _} = ok -> ok
      :error -> {:error, :invalid_signature}
    end
  end

  defp check_age(_signed_at, nil), do: :ok
  defp check_age(signed_at, max_age) do
    if System.system_time(:second) - signed_at <= max_age, do: :ok, else: {:error, :signature_expired}
  end
end
```
