```elixir
defmodule Privacy.PiiMasker do
  @moduledoc """
  Masks personally identifiable information before data is written to
  logs, exported to analytics pipelines, or returned in admin API responses.
  Complies with the company's data-minimisation policy under LGPD/GDPR.
  """

  @masked_value "[MASKED]"

  @default_pii_fields ~w(
    email
    phone
    cpf
    ssn
    date_of_birth
    full_name
    address
    ip_address
    credit_card_number
  )a


  def mask_user(user, level \\ :standard) do
    require Privacy.PiiMasker

    fields_to_mask =
      case level do
        :minimal  -> [:email, :phone]
        :standard -> @default_pii_fields
        :full     -> Map.keys(user)
      end

    Privacy.PiiMasker.mask_fields(user, fields_to_mask)
  end

  def mask_for_log(record) do
    require Privacy.PiiMasker
    Privacy.PiiMasker.mask_fields(record, @default_pii_fields)
  end

  def mask_for_export(records, extra_fields \\ []) do
    require Privacy.PiiMasker

    fields = @default_pii_fields ++ extra_fields

    Enum.map(records, fn record ->
      Privacy.PiiMasker.mask_fields(record, fields)
    end)
  end

  def safe_inspect(record) do
    require Privacy.PiiMasker

    masked = Privacy.PiiMasker.mask_fields(record, @default_pii_fields)
    inspect(masked)
  end

  def audit_diff(before_record, after_record) do
    require Privacy.PiiMasker

    %{
      before: Privacy.PiiMasker.mask_fields(before_record, @default_pii_fields),
      after:  Privacy.PiiMasker.mask_fields(after_record,  @default_pii_fields),
      changed_keys:
        Map.keys(before_record)
        |> Enum.filter(fn k -> Map.get(before_record, k) != Map.get(after_record, k) end)
    }
  end

  def redact_nested(data, path) when is_list(path) do
    case path do
      [key] ->
        require Privacy.PiiMasker
        Privacy.PiiMasker.mask_fields(data, [key])

      [head | tail] ->
        case Map.get(data, head) do
          nested when is_map(nested) ->
            Map.put(data, head, redact_nested(nested, tail))

          _ ->
            data
        end
    end
  end

  def default_pii_fields, do: @default_pii_fields
end
```
