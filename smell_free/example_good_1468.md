```elixir
defmodule FeatureFlags.Flag do
  use Ecto.Schema
  import Ecto.Changeset

  @moduledoc """
  Persisted feature flag definition. Flags may target all users,
  a percentage rollout, or an explicit allowlist of account IDs.
  """

  @type targeting :: :all | :percentage | :allowlist

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          key: String.t(),
          enabled: boolean(),
          targeting: targeting(),
          rollout_percentage: integer() | nil,
          allowlist: [String.t()]
        }

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "feature_flags" do
    field :key, :string
    field :enabled, :boolean, default: false
    field :targeting, Ecto.Enum, values: [:all, :percentage, :allowlist]
    field :rollout_percentage, :integer
    field :allowlist, {:array, :string}, default: []
    timestamps()
  end

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(flag, attrs) do
    flag
    |> cast(attrs, [:key, :enabled, :targeting, :rollout_percentage, :allowlist])
    |> validate_required([:key, :enabled, :targeting])
    |> validate_format(:key, ~r/^[a-z0-9_]+$/)
    |> unique_constraint(:key)
    |> validate_rollout_percentage()
  end

  defp validate_rollout_percentage(%{changes: %{targeting: :percentage}} = cs) do
    validate_number(cs, :rollout_percentage, greater_than: 0, less_than_or_equal_to: 100)
  end

  defp validate_rollout_percentage(cs), do: cs
end

defmodule FeatureFlags do
  import Ecto.Query

  alias FeatureFlags.Flag
  alias MyApp.Repo

  @moduledoc """
  Public context for evaluating and managing feature flags.
  Evaluation is deterministic for percentage rollouts using a hashed account ID.
  """

  @spec enabled?(String.t(), String.t()) :: boolean()
  def enabled?(flag_key, account_id)
      when is_binary(flag_key) and is_binary(account_id) do
    case Repo.get_by(Flag, key: flag_key) do
      nil -> false
      %Flag{enabled: false} -> false
      %Flag{targeting: :all} -> true
      %Flag{targeting: :allowlist, allowlist: list} -> account_id in list
      %Flag{targeting: :percentage, rollout_percentage: pct} ->
        percentage_bucket(account_id, flag_key) <= pct
    end
  end

  @spec upsert_flag(map()) :: {:ok, Flag.t()} | {:error, Ecto.Changeset.t()}
  def upsert_flag(attrs) do
    case Repo.get_by(Flag, key: attrs[:key] || attrs["key"]) do
      nil -> %Flag{} |> Flag.changeset(attrs) |> Repo.insert()
      existing -> existing |> Flag.changeset(attrs) |> Repo.update()
    end
  end

  @spec list_flags() :: [Flag.t()]
  def list_flags do
    Flag |> order_by(:key) |> Repo.all()
  end

  defp percentage_bucket(account_id, flag_key) do
    hash_input = "#{flag_key}:#{account_id}"

    :crypto.hash(:md5, hash_input)
    |> :binary.bin_to_list()
    |> Enum.take(4)
    |> Enum.reduce(0, fn byte, acc -> acc * 256 + byte end)
    |> rem(100)
    |> Kernel.+(1)
  end
end
```
