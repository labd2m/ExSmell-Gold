```elixir
defmodule Geo.AddressNormalizer do
  @moduledoc """
  Normalises and validates postal addresses through a composable
  transformation pipeline. Each stage receives a candidate address map
  and returns either an updated map or an error tuple, allowing the pipeline
  to short-circuit cleanly on the first failure. Normalization is fully pure;
  geocoding enrichment is performed as a separate, explicitly async step.
  """

  @type raw_address :: %{
          optional(:line1) => String.t(),
          optional(:line2) => String.t(),
          optional(:city) => String.t(),
          optional(:state) => String.t(),
          optional(:postal_code) => String.t(),
          optional(:country_code) => String.t()
        }

  @type normalized_address :: %{
          required(:line1) => String.t(),
          required(:line2) => String.t() | nil,
          required(:city) => String.t(),
          required(:state) => String.t(),
          required(:postal_code) => String.t(),
          required(:country_code) => String.t()
        }

  @supported_countries ~w[US CA GB AU BR DE FR NL SE NO DK FI]

  @doc """
  Normalises `raw` by trimming whitespace, upcasing country code, and
  validating required fields. Returns `{:ok, normalized}` or `{:error, reason}`.
  """
  @spec normalize(raw_address()) :: {:ok, normalized_address()} | {:error, term()}
  def normalize(raw) when is_map(raw) do
    raw
    |> trim_fields()
    |> upcase_country()
    |> validate_required()
    |> validate_country()
    |> normalize_postal_code()
    |> wrap_result()
  end

  def normalize(_), do: {:error, :invalid_input}

  @doc """
  Formats a normalised address as a single human-readable string.
  Omits blank optional fields.
  """
  @spec format(normalized_address()) :: String.t()
  def format(%{} = addr) do
    [
      addr[:line1],
      addr[:line2],
      addr[:city],
      addr[:state],
      addr[:postal_code],
      addr[:country_code]
    ]
    |> Enum.reject(&is_nil_or_blank/1)
    |> Enum.join(", ")
  end

  # ---------------------------------------------------------------------------
  # Pipeline stages
  # ---------------------------------------------------------------------------

  defp trim_fields({:error, _} = err), do: err

  defp trim_fields(addr) when is_map(addr) do
    addr
    |> Enum.map(fn {k, v} -> {k, if(is_binary(v), do: String.trim(v), else: v)} end)
    |> Map.new()
  end

  defp upcase_country({:error, _} = err), do: err

  defp upcase_country(%{country_code: code} = addr) when is_binary(code) do
    %{addr | country_code: String.upcase(code)}
  end

  defp upcase_country(addr), do: addr

  defp validate_required({:error, _} = err), do: err

  defp validate_required(addr) do
    required = [:line1, :city, :postal_code, :country_code]

    missing =
      Enum.filter(required, fn field ->
        addr |> Map.get(field, nil) |> is_nil_or_blank()
      end)

    case missing do
      [] -> addr
      fields -> {:error, {:missing_fields, fields}}
    end
  end

  defp validate_country({:error, _} = err), do: err

  defp validate_country(%{country_code: code} = addr) when code in @supported_countries do
    addr
  end

  defp validate_country(%{country_code: code}) do
    {:error, {:unsupported_country, code}}
  end

  defp normalize_postal_code({:error, _} = err), do: err

  defp normalize_postal_code(%{country_code: "US", postal_code: code} = addr) do
    stripped = String.replace(code, ~r/[^0-9]/, "")

    if String.length(stripped) in [5, 9] do
      %{addr | postal_code: String.slice(stripped, 0, 5)}
    else
      {:error, {:invalid_postal_code, code}}
    end
  end

  defp normalize_postal_code(%{country_code: "CA", postal_code: code} = addr) do
    normalized = code |> String.replace(" ", "") |> String.upcase()

    if Regex.match?(~r/^[A-Z]\d[A-Z]\d[A-Z]\d$/, normalized) do
      formatted = "#{String.slice(normalized, 0, 3)} #{String.slice(normalized, 3, 3)}"
      %{addr | postal_code: formatted}
    else
      {:error, {:invalid_postal_code, code}}
    end
  end

  defp normalize_postal_code(addr), do: addr

  defp wrap_result({:error, _} = err), do: err

  defp wrap_result(addr) do
    normalized = %{
      line1: Map.get(addr, :line1),
      line2: Map.get(addr, :line2),
      city: Map.get(addr, :city),
      state: Map.get(addr, :state),
      postal_code: Map.get(addr, :postal_code),
      country_code: Map.get(addr, :country_code)
    }

    {:ok, normalized}
  end

  defp is_nil_or_blank(nil), do: true
  defp is_nil_or_blank(""), do: true
  defp is_nil_or_blank(_), do: false
end
```
