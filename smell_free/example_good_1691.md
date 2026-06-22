```elixir
defmodule Geo.AddressValidator do
  @moduledoc """
  Validates and normalizes postal address records.

  Validation is performed in two stages: structural validation (required fields,
  type checks) and optional remote normalization via a configurable provider.
  The provider is supplied per-call to allow per-tenant routing.
  """

  alias Geo.AddressValidator.{Address, ValidationResult, NormalizationProvider}

  @doc """
  Validates and optionally normalizes an address.

  If a `provider` option is given, the address is sent to the normalization
  service and the standardized form is returned. Without a provider, only
  structural validation is performed.
  """
  @spec validate(map(), keyword()) :: {:ok, ValidationResult.t()} | {:error, String.t()}
  def validate(raw_address, opts \\ []) when is_map(raw_address) do
    provider = Keyword.get(opts, :provider)

    with {:ok, address} <- Address.from_map(raw_address),
         {:ok, result} <- run_validation(address, provider) do
      {:ok, result}
    end
  end

  def validate(_, _), do: {:error, "address must be a map"}

  defp run_validation(address, nil) do
    {:ok, ValidationResult.local_only(address)}
  end

  defp run_validation(address, provider) do
    case NormalizationProvider.normalize(provider, address) do
      {:ok, normalized} -> {:ok, ValidationResult.normalized(address, normalized)}
      {:error, reason} -> {:ok, ValidationResult.normalization_failed(address, reason)}
    end
  end
end

defmodule Geo.AddressValidator.Address do
  @moduledoc "Typed value object representing a postal address."

  @enforce_keys [:line1, :city, :country_code]
  defstruct [:line1, :line2, :city, :state, :postal_code, :country_code]

  @type t :: %__MODULE__{
          line1: String.t(),
          line2: String.t() | nil,
          city: String.t(),
          state: String.t() | nil,
          postal_code: String.t() | nil,
          country_code: String.t()
        }

  @spec from_map(map()) :: {:ok, t()} | {:error, String.t()}
  def from_map(%{line1: line1, city: city, country_code: cc} = m)
      when is_binary(line1) and line1 != "" and
             is_binary(city) and city != "" and
             is_binary(cc) and byte_size(cc) == 2 do
    {:ok, %__MODULE__{
      line1: line1,
      line2: Map.get(m, :line2),
      city: city,
      state: Map.get(m, :state),
      postal_code: Map.get(m, :postal_code),
      country_code: String.upcase(cc)
    }}
  end

  def from_map(_), do: {:error, "address requires line1, city, and a 2-letter country_code"}
end

defmodule Geo.AddressValidator.ValidationResult do
  @moduledoc "Structured outcome of an address validation operation."

  alias Geo.AddressValidator.Address

  @enforce_keys [:original, :valid, :normalized, :normalization_status]
  defstruct [:original, :valid, :normalized, :normalization_status, :normalization_error]

  @type normalization_status :: :skipped | :success | :failed

  @type t :: %__MODULE__{
          original: Address.t(),
          valid: boolean(),
          normalized: Address.t() | nil,
          normalization_status: normalization_status(),
          normalization_error: String.t() | nil
        }

  @spec local_only(Address.t()) :: t()
  def local_only(address) do
    %__MODULE__{original: address, valid: true, normalized: nil, normalization_status: :skipped}
  end

  @spec normalized(Address.t(), Address.t()) :: t()
  def normalized(original, normalized_address) do
    %__MODULE__{
      original: original,
      valid: true,
      normalized: normalized_address,
      normalization_status: :success
    }
  end

  @spec normalization_failed(Address.t(), String.t()) :: t()
  def normalization_failed(address, reason) do
    %__MODULE__{
      original: address,
      valid: true,
      normalized: nil,
      normalization_status: :failed,
      normalization_error: reason
    }
  end
end

defmodule Geo.AddressValidator.NormalizationProvider do
  @moduledoc "Behaviour for address normalization adapters."

  alias Geo.AddressValidator.Address

  @callback normalize(Address.t()) :: {:ok, Address.t()} | {:error, String.t()}

  @spec normalize(module(), Address.t()) :: {:ok, Address.t()} | {:error, String.t()}
  def normalize(provider_module, %Address{} = address) do
    provider_module.normalize(address)
  end
end
```
