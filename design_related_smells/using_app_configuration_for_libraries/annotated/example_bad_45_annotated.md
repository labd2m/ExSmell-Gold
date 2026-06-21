# Code Smell Example – Annotated

- **Smell name:** Using App Configuration for libraries
- **Expected smell location:** `PhoneFormatter.format/1`
- **Affected function(s):** `format/1`, `normalize/1`
- **Short explanation:** The library reads `:default_country_code` and `:output_format` from the global `Application Environment` rather than accepting them as parameters. A dependent application with users in multiple countries cannot format phone numbers with different country defaults per user without changing global config, making the library unsuitable for international use.

```elixir
defmodule PhoneFormatter do
  @moduledoc """
  A phone number parsing, validation, and formatting library.
  Supports E.164, national, and international display formats.

  Configuration (config/config.exs):

      config :phone_formatter,
        default_country_code: "US",
        output_format: :national
  """

  @country_configs %{
    "US" => %{prefix: "+1", trunk: "1", length: 10, national_pattern: ~r/^[2-9]\d{2}[2-9]\d{6}$/},
    "BR" => %{prefix: "+55", trunk: "55", length: 11, national_pattern: ~r/^\d{2}9?\d{8}$/},
    "GB" => %{prefix: "+44", trunk: "44", length: 10, national_pattern: ~r/^\d{10}$/},
    "DE" => %{prefix: "+49", trunk: "49", length: 11, national_pattern: ~r/^\d{6,11}$/}
  }

  @supported_formats [:e164, :national, :international]

  @doc """
  Formats a raw phone string using the globally configured country code and
  output format.

  Returns `{:ok, formatted}` or `{:error, reason}`.
  """
  @spec format(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def format(raw) when is_binary(raw) do
    # VALIDATION: SMELL START - Using App Configuration for libraries
    # VALIDATION: This is a smell because the library reads :default_country_code
    # and :output_format from the global Application Environment instead of
    # accepting them as function parameters. An international application that
    # must format numbers from multiple countries simultaneously (or render
    # numbers differently in different UI contexts) is forced to share a single
    # global country assumption. Any caller that needs a different default
    # country code or output format is blocked from achieving that without
    # changing the global configuration.
    country_code = Application.fetch_env!(:phone_formatter, :default_country_code)
    output_format = Application.fetch_env!(:phone_formatter, :output_format)
    # VALIDATION: SMELL END

    with {:ok, digits} <- extract_digits(raw),
         {:ok, config} <- fetch_country_config(country_code),
         :ok <- validate_length(digits, config),
         :ok <- validate_pattern(digits, config) do
      formatted = apply_format(digits, config, output_format)
      {:ok, formatted}
    end
  end

  @doc """
  Normalizes a phone number to E.164 format using the configured default country.
  """
  @spec normalize(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def normalize(raw) when is_binary(raw) do
    country_code = Application.fetch_env!(:phone_formatter, :default_country_code)

    with {:ok, digits} <- extract_digits(raw),
         {:ok, config} <- fetch_country_config(country_code),
         :ok <- validate_length(digits, config) do
      {:ok, "#{config.prefix}#{digits}"}
    end
  end

  @doc """
  Returns true if the raw string represents a plausible phone number for the
  configured default country.
  """
  @spec valid?(String.t()) :: boolean()
  def valid?(raw) when is_binary(raw) do
    case format(raw) do
      {:ok, _} -> true
      _ -> false
    end
  end

  @doc """
  Returns the E.164 prefix for the configured default country code.
  """
  @spec country_prefix() :: {:ok, String.t()} | {:error, String.t()}
  def country_prefix do
    country_code = Application.fetch_env!(:phone_formatter, :default_country_code)

    case fetch_country_config(country_code) do
      {:ok, %{prefix: prefix}} -> {:ok, prefix}
      err -> err
    end
  end

  @doc """
  Returns a list of all supported country codes.
  """
  @spec supported_countries() :: list(String.t())
  def supported_countries, do: Map.keys(@country_configs)

  # --- Private helpers ---

  defp extract_digits(raw) do
    digits = String.replace(raw, ~r/[^\d]/, "")

    if digits == "" do
      {:error, "Input contains no digits"}
    else
      {:ok, digits}
    end
  end

  defp fetch_country_config(code) do
    case Map.fetch(@country_configs, String.upcase(code)) do
      {:ok, config} -> {:ok, config}
      :error -> {:error, "Unsupported country code: #{code}"}
    end
  end

  defp validate_length(digits, %{length: expected}) do
    if String.length(digits) == expected or
         String.length(digits) == expected + 1 do
      :ok
    else
      {:error, "Unexpected phone number length: #{String.length(digits)} digits"}
    end
  end

  defp validate_pattern(digits, %{national_pattern: pattern}) do
    if Regex.match?(pattern, digits) do
      :ok
    else
      {:error, "Digits do not match national number pattern"}
    end
  end

  defp apply_format(digits, config, :e164), do: "#{config.prefix}#{digits}"
  defp apply_format(digits, _config, :national), do: digits

  defp apply_format(digits, config, :international),
    do: "#{config.prefix} #{format_groups(digits)}"

  defp apply_format(digits, config, _unknown), do: "#{config.prefix}#{digits}"

  defp format_groups(digits) do
    digits
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.map(&Enum.join/1)
    |> Enum.join(" ")
  end
end
```
