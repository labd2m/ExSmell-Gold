```elixir
defmodule Serializer.Format do
  @moduledoc false

  @type t :: :json | :msgpack | :etf

  @mime_to_format %{
    "application/json" => :json,
    "application/x-msgpack" => :msgpack,
    "application/msgpack" => :msgpack,
    "application/x-erlang-binary" => :etf
  }

  @format_to_mime %{
    json: "application/json",
    msgpack: "application/x-msgpack",
    etf: "application/x-erlang-binary"
  }

  @spec from_mime(String.t()) :: {:ok, t()} | {:error, :unsupported}
  def from_mime(mime) when is_binary(mime) do
    base = mime |> String.split(";") |> List.first() |> String.trim()

    case Map.fetch(@mime_to_format, base) do
      {:ok, _} = ok -> ok
      :error -> {:error, :unsupported}
    end
  end

  @spec to_mime(t()) :: String.t()
  def to_mime(format), do: Map.fetch!(@format_to_mime, format)

  @spec supported_mimes() :: [String.t()]
  def supported_mimes, do: Map.keys(@mime_to_format)
end

defmodule Serializer do
  @moduledoc """
  Encodes and decodes domain data in multiple wire formats, dispatching
  on the format atom resolved from MIME type negotiation.

  Supported formats: `:json` (via Jason), `:msgpack` (via Msgpax),
  and `:etf` (Erlang External Term Format, for internal Elixir services).
  The `:etf` format is not safe for untrusted input; callers are responsible
  for restricting its use to authenticated internal channels.
  """

  alias Serializer.Format

  @type format :: Format.t()

  @spec encode(term(), format()) :: {:ok, binary()} | {:error, term()}
  def encode(data, :json) do
    case Jason.encode(data) do
      {:ok, _} = ok -> ok
      {:error, reason} -> {:error, {:encode_failed, :json, reason}}
    end
  end

  def encode(data, :msgpack) do
    case Msgpax.pack(data) do
      {:ok, packed} -> {:ok, IO.iodata_to_binary(packed)}
      {:error, reason} -> {:error, {:encode_failed, :msgpack, reason}}
    end
  end

  def encode(data, :etf) do
    {:ok, :erlang.term_to_binary(data)}
  rescue
    error -> {:error, {:encode_failed, :etf, error}}
  end

  def encode(_data, format), do: {:error, {:unsupported_format, format}}

  @spec decode(binary(), format()) :: {:ok, term()} | {:error, term()}
  def decode(binary, :json) when is_binary(binary) do
    case Jason.decode(binary) do
      {:ok, _} = ok -> ok
      {:error, reason} -> {:error, {:decode_failed, :json, reason}}
    end
  end

  def decode(binary, :msgpack) when is_binary(binary) do
    case Msgpax.unpack(binary) do
      {:ok, _} = ok -> ok
      {:error, reason} -> {:error, {:decode_failed, :msgpack, reason}}
    end
  end

  def decode(binary, :etf) when is_binary(binary) do
    {:ok, :erlang.binary_to_term(binary, [:safe])}
  rescue
    error -> {:error, {:decode_failed, :etf, error}}
  end

  def decode(_binary, format), do: {:error, {:unsupported_format, format}}

  @spec negotiate(String.t(), [format()]) :: {:ok, format()} | {:error, :not_acceptable}
  def negotiate(accept_header, producible_formats) when is_binary(accept_header) do
    accepted_mimes = parse_accept_header(accept_header)

    Enum.find_value(accepted_mimes, {:error, :not_acceptable}, fn mime ->
      with {:ok, format} <- Format.from_mime(mime),
           true <- format in producible_formats do
        {:ok, format}
      else
        _ -> nil
      end
    end)
  end

  defp parse_accept_header(header) do
    header
    |> String.split(",")
    |> Enum.map(fn segment ->
      [mime | _params] = String.split(String.trim(segment), ";")
      String.trim(mime)
    end)
  end
end
```
