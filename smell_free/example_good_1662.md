```elixir
defmodule Encoding.Codec do
  @moduledoc """
  Behaviour for data encoding and decoding implementations.
  """

  @callback encode(data :: term()) :: {:ok, binary()} | {:error, term()}
  @callback decode(binary :: binary()) :: {:ok, term()} | {:error, term()}
  @callback content_type() :: String.t()
end

defmodule Encoding.JsonCodec do
  @behaviour Encoding.Codec

  @impl Encoding.Codec
  def encode(data) do
    case Jason.encode(data) do
      {:ok, json} -> {:ok, json}
      {:error, reason} -> {:error, {:json_encode_failed, reason}}
    end
  end

  @impl Encoding.Codec
  def decode(binary) when is_binary(binary) do
    case Jason.decode(binary) do
      {:ok, data} -> {:ok, data}
      {:error, reason} -> {:error, {:json_decode_failed, reason}}
    end
  end

  @impl Encoding.Codec
  def content_type, do: "application/json"
end

defmodule Encoding.MsgpackCodec do
  @behaviour Encoding.Codec

  @impl Encoding.Codec
  def encode(data) do
    case Msgpax.pack(data) do
      {:ok, packed} -> {:ok, IO.iodata_to_binary(packed)}
      {:error, reason} -> {:error, {:msgpack_encode_failed, reason}}
    end
  end

  @impl Encoding.Codec
  def decode(binary) when is_binary(binary) do
    case Msgpax.unpack(binary) do
      {:ok, data} -> {:ok, data}
      {:error, reason} -> {:error, {:msgpack_decode_failed, reason}}
    end
  end

  @impl Encoding.Codec
  def content_type, do: "application/msgpack"
end

defmodule Encoding.Registry do
  @moduledoc """
  Resolves the appropriate codec for a given MIME content type.
  New codecs are registered at startup via `register/2`.
  """

  use Agent

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(_opts) do
    Agent.start_link(
      fn ->
        %{
          "application/json" => Encoding.JsonCodec,
          "application/msgpack" => Encoding.MsgpackCodec
        }
      end,
      name: __MODULE__
    )
  end

  @spec register(String.t(), module()) :: :ok
  def register(content_type, codec_module)
      when is_binary(content_type) and is_atom(codec_module) do
    Agent.update(__MODULE__, &Map.put(&1, content_type, codec_module))
  end

  @spec resolve(String.t()) :: {:ok, module()} | {:error, :unsupported_content_type}
  def resolve(content_type) when is_binary(content_type) do
    normalized = content_type |> String.split(";") |> List.first() |> String.trim()

    case Agent.get(__MODULE__, &Map.fetch(&1, normalized)) do
      {:ok, codec} -> {:ok, codec}
      :error -> {:error, :unsupported_content_type}
    end
  end

  @spec encode(String.t(), term()) :: {:ok, binary()} | {:error, term()}
  def encode(content_type, data) do
    with {:ok, codec} <- resolve(content_type) do
      codec.encode(data)
    end
  end

  @spec decode(String.t(), binary()) :: {:ok, term()} | {:error, term()}
  def decode(content_type, binary) do
    with {:ok, codec} <- resolve(content_type) do
      codec.decode(binary)
    end
  end
end
```
