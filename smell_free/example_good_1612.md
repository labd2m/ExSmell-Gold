```elixir
defmodule Domain.EmailAddress do
  @moduledoc """
  An immutable value object representing a validated email address.
  Construction enforces RFC-5321 structural rules; all access is
  through typed accessors that preserve the invariant.
  """

  @type t :: %__MODULE__{local: String.t(), domain: String.t()}

  @enforce_keys [:local, :domain]
  defstruct [:local, :domain]

  @spec new(String.t()) :: {:ok, t()} | {:error, :invalid_email}
  def new(raw) when is_binary(raw) do
    trimmed = String.trim(raw)

    case String.split(trimmed, "@") do
      [local, domain] when local != "" and domain != "" ->
        with :ok <- validate_local(local),
             :ok <- validate_domain(domain) do
          {:ok, %__MODULE__{local: String.downcase(local), domain: String.downcase(domain)}}
        end

      _ ->
        {:error, :invalid_email}
    end
  end

  def new(_), do: {:error, :invalid_email}

  @spec new!(String.t()) :: t()
  def new!(raw) do
    case new(raw) do
      {:ok, email} -> email
      {:error, _} -> raise ArgumentError, "Invalid email address: #{inspect(raw)}"
    end
  end

  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{local: local, domain: domain}), do: "#{local}@#{domain}"

  @spec domain_part(t()) :: String.t()
  def domain_part(%__MODULE__{domain: domain}), do: domain

  @spec local_part(t()) :: String.t()
  def local_part(%__MODULE__{local: local}), do: local

  @spec same_domain?(t(), t()) :: boolean()
  def same_domain?(%__MODULE__{domain: d1}, %__MODULE__{domain: d2}), do: d1 == d2

  @spec equals?(t(), t()) :: boolean()
  def equals?(%__MODULE__{} = a, %__MODULE__{} = b) do
    to_string(a) == to_string(b)
  end

  @spec validate_local(String.t()) :: :ok | {:error, :invalid_email}
  defp validate_local(local) do
    if Regex.match?(~r/^[a-zA-Z0-9!#$%&'*+\-\/=?^_`{|}~.]{1,64}$/, local) do
      :ok
    else
      {:error, :invalid_email}
    end
  end

  @spec validate_domain(String.t()) :: :ok | {:error, :invalid_email}
  defp validate_domain(domain) do
    valid =
      Regex.match?(~r/^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z]{2,})+$/, domain)

    if valid, do: :ok, else: {:error, :invalid_email}
  end

  defimpl String.Chars do
    def to_string(email), do: Domain.EmailAddress.to_string(email)
  end

  defimpl Jason.Encoder do
    def encode(email, opts), do: Jason.Encode.string(Domain.EmailAddress.to_string(email), opts)
  end
end
```
