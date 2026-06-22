```elixir
defmodule Mix.Tasks.Db.SeedPlans do
  use Mix.Task

  alias MyApp.Billing.Plan
  alias MyApp.Repo

  @shortdoc "Seeds the subscription_plans table with default plan definitions."

  @moduledoc """
  Seeds initial subscription plan records required for a fresh environment.
  Idempotent: existing plans identified by their `code` are left untouched.

  ## Usage

      mix db.seed_plans

  ## Options

      --env  Target environment (defaults to current Mix environment)

  This task is intentionally separate from database migrations.
  Migrations modify schema structure; this task manages reference data.
  """

  @default_plans [
    %{code: "starter", label: "Starter", monthly_price_cents: 900, max_seats: 3},
    %{code: "growth", label: "Growth", monthly_price_cents: 2900, max_seats: 15},
    %{code: "enterprise", label: "Enterprise", monthly_price_cents: 9900, max_seats: 200}
  ]

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    {inserted, skipped} = seed_plans(@default_plans)

    Mix.shell().info("Seeding complete: #{inserted} inserted, #{skipped} skipped.")
  end

  @spec seed_plans([map()]) :: {non_neg_integer(), non_neg_integer()}
  defp seed_plans(plan_definitions) do
    Enum.reduce(plan_definitions, {0, 0}, fn attrs, {ins, skip} ->
      case insert_if_absent(attrs) do
        {:ok, :inserted} -> {ins + 1, skip}
        {:ok, :skipped} -> {ins, skip + 1}
      end
    end)
  end

  @spec insert_if_absent(map()) :: {:ok, :inserted} | {:ok, :skipped}
  defp insert_if_absent(attrs) do
    case Repo.get_by(Plan, code: attrs.code) do
      %Plan{} ->
        {:ok, :skipped}

      nil ->
        {:ok, _plan} =
          %Plan{}
          |> Plan.changeset(attrs)
          |> Repo.insert()

        {:ok, :inserted}
    end
  end
end

defmodule MyApp.Billing.Plan do
  use Ecto.Schema
  import Ecto.Changeset

  @moduledoc """
  Schema for subscription plan definitions.
  """

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          code: String.t(),
          label: String.t(),
          monthly_price_cents: non_neg_integer(),
          max_seats: pos_integer()
        }

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "subscription_plans" do
    field :code, :string
    field :label, :string
    field :monthly_price_cents, :integer
    field :max_seats, :integer
    timestamps()
  end

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(plan, attrs) do
    plan
    |> cast(attrs, [:code, :label, :monthly_price_cents, :max_seats])
    |> validate_required([:code, :label, :monthly_price_cents, :max_seats])
    |> validate_number(:monthly_price_cents, greater_than_or_equal_to: 0)
    |> validate_number(:max_seats, greater_than: 0)
    |> unique_constraint(:code)
  end
end
```
