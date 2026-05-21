```elixir
defmodule Compliance.DocumentRegistry do
  @moduledoc """
  Manages compliance document identifiers and metadata for regulatory filings.
  Covers GDPR data processing records, LGPD consent documents, SOC 2 evidence
  artifacts, and internal policy acknowledgement records.

  Document IDs follow the pattern: `{REGULATION}-{JURISDICTION}-{SEQUENCE}`,
  e.g. `GDPR-EU-000042`.
  """

  @separator "-"
  @sequence_pad 6
  @valid_regulations ~w(GDPR LGPD CCPA SOC2 ISO27001 HIPAA)
  @valid_jurisdictions ~w(BR EU US CA AU GB)

  @doc """
  Builds a canonical compliance document identifier.

  ## Parameters
    - `regulation`: An uppercase regulation code, e.g. `"GDPR"`.
    - `jurisdiction`: A two-letter jurisdiction code, e.g. `"EU"`.
    - `sequence`: A numeric or string sequence identifier.
  """
  def build_document_id(regulation, jurisdiction, sequence)
      when is_binary(regulation) and is_binary(jurisdiction) do
    padded =
      sequence
      |> to_string()
      |> String.pad_leading(@sequence_pad, "0")

    Enum.join(
      [String.upcase(regulation), String.upcase(jurisdiction), padded],
      @separator
    )
  end

  @doc """
  Validates that a regulation and jurisdiction pair are supported.
  Returns `:ok` or `{:error, reason}`.
  """
  def validate_regulation_jurisdiction(regulation, jurisdiction)
      when is_binary(regulation) and is_binary(jurisdiction) do
    cond do
      String.upcase(regulation) not in @valid_regulations ->
        {:error, {:regulation, :unsupported}}

      String.upcase(jurisdiction) not in @valid_jurisdictions ->
        {:error, {:jurisdiction, :unsupported}}

      true ->
        :ok
    end
  end

  @doc """
  Parses a document ID string into its component parts.
  Returns `{:ok, %{regulation, jurisdiction, sequence}}` or `{:error, :invalid_format}`.
  """
  def parse_document_id(doc_id) when is_binary(doc_id) do
    case String.split(doc_id, @separator, parts: 3) do
      [regulation, jurisdiction, sequence] ->
        {:ok,
         %{
           regulation: regulation,
           jurisdiction: jurisdiction,
           sequence: sequence
         }}

      _ ->
        {:error, :invalid_format}
    end
  end

  @doc """
  Returns a retention expiry date for a document based on its regulation.
  """
  def retention_expiry(:gdpr, %Date{} = created_on) do
    %{created_on | year: created_on.year + 7}
  end

  def retention_expiry(:hipaa, %Date{} = created_on) do
    %{created_on | year: created_on.year + 6}
  end

  def retention_expiry(_, %Date{} = created_on) do
    %{created_on | year: created_on.year + 5}
  end

  @doc """
  Checks whether a document ID string matches the expected pattern.
  """
  def valid_document_id?(doc_id) when is_binary(doc_id) do
    Regex.match?(~r/^[A-Z0-9]+-[A-Z]{2}-\d+$/, doc_id)
  end

  def valid_document_id?(_), do: false

  @doc """
  Returns all supported regulation codes.
  """
  def supported_regulations, do: @valid_regulations

  @doc """
  Returns all supported jurisdiction codes.
  """
  def supported_jurisdictions, do: @valid_jurisdictions
end
```
