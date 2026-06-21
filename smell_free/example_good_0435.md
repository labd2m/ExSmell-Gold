```elixir
defmodule Integrations.WebhookEndpointConfig do
  @moduledoc """
  An Ecto embedded schema representing the structured configuration stored
  in the `config` JSONB column of the `webhook_endpoints` table. Using an
  embedded schema rather than raw maps ensures the structure is validated
  and cast on every read and write, preventing invalid configurations from
  being persisted or silently ignored.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false

  embedded_schema do
    field :secret_key, :string
    field :timeout_ms, :integer, default: 10_000
    field :retry_enabled, :boolean, default: true
    field :max_retries, :integer, default: 5
    field :event_types, {:array, :string}, default: []
    field :custom_headers, :map, default: %{}
    field :tls_verify, :boolean, default: true
    field :rate_limit_per_minute, :integer, default: 1_000

    embeds_one :auth, __MODULE__.Auth, on_replace: :update do
      @primary_key false
      field :type, Ecto.Enum, values: [:none, :bearer, :basic, :hmac]
      field :token, :string
      field :username, :string
      field :password, :string
    end
  end

  @type t :: %__MODULE__{
          secret_key: binary(),
          timeout_ms: pos_integer(),
          retry_enabled: boolean(),
          max_retries: non_neg_integer(),
          event_types: [binary()],
          custom_headers: map(),
          tls_verify: boolean(),
          rate_limit_per_minute: pos_integer()
        }

  @doc """
  Builds and validates a changeset for the webhook endpoint configuration.
  Enforces business rules such as retry count limits and timeout bounds.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = config, attrs) do
    config
    |> cast(attrs, [
      :secret_key, :timeout_ms, :retry_enabled, :max_retries,
      :event_types, :custom_headers, :tls_verify, :rate_limit_per_minute
    ])
    |> cast_embed(:auth, with: &auth_changeset/2)
    |> validate_required([:secret_key])
    |> validate_length(:secret_key, min: 32)
    |> validate_number(:timeout_ms, greater_than: 0, less_than_or_equal_to: 60_000)
    |> validate_number(:max_retries, greater_than_or_equal_to: 0, less_than_or_equal_to: 10)
    |> validate_number(:rate_limit_per_minute, greater_than: 0, less_than_or_equal_to: 10_000)
    |> validate_event_types()
    |> validate_custom_headers()
  end

  @doc """
  Returns the default configuration struct with sensible production defaults.
  """
  @spec defaults() :: t()
  def defaults do
    %__MODULE__{
      timeout_ms: 10_000,
      retry_enabled: true,
      max_retries: 5,
      event_types: [],
      custom_headers: %{},
      tls_verify: true,
      rate_limit_per_minute: 1_000
    }
  end

  @doc """
  Returns `true` when the configuration permits delivery of `event_type`.
  An empty `event_types` list means all events are allowed.
  """
  @spec allows_event?(t(), binary()) :: boolean()
  def allows_event?(%__MODULE__{event_types: []}, _event_type), do: true
  def allows_event?(%__MODULE__{event_types: types}, event_type), do: event_type in types

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp auth_changeset(auth, attrs) do
    auth
    |> cast(attrs, [:type, :token, :username, :password])
    |> validate_required([:type])
    |> validate_auth_fields()
  end

  defp validate_auth_fields(%Ecto.Changeset{} = changeset) do
    case get_field(changeset, :type) do
      :bearer -> validate_required(changeset, [:token])
      :basic -> validate_required(changeset, [:username, :password])
      :hmac -> validate_required(changeset, [:token])
      _ -> changeset
    end
  end

  defp validate_event_types(changeset) do
    case get_field(changeset, :event_types) do
      types when is_list(types) ->
        invalid = Enum.reject(types, &(is_binary(&1) and Regex.match?(~r/^[a-z][a-z0-9_.]*$/, &1)))

        if invalid == [] do
          changeset
        else
          add_error(changeset, :event_types, "contains invalid event type names: #{inspect(invalid)}")
        end

      _ ->
        changeset
    end
  end

  defp validate_custom_headers(changeset) do
    case get_field(changeset, :custom_headers) do
      headers when is_map(headers) ->
        invalid = Enum.reject(headers, fn {k, v} -> is_binary(k) and is_binary(v) end)

        if invalid == [] do
          changeset
        else
          add_error(changeset, :custom_headers, "all keys and values must be strings")
        end

      _ ->
        changeset
    end
  end
end
```
