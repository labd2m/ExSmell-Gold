```elixir
defmodule Mix.Tasks.Seed.Roles do
  @moduledoc """
  Seeds the database with the standard system role definitions required
  for the application's permission model. This task is idempotent and
  safe to run multiple times in any environment.

  ## Usage

      mix seed.roles
      mix seed.roles --env staging

  ## Options

    * `--env` - Target environment label for log output (default: `development`)
  """

  use Mix.Task

  alias Platform.Accounts.Role
  alias Platform.Repo

  @shortdoc "Seeds system roles into the database"

  @system_roles [
    %{name: "super_admin", display_name: "Super Administrator", level: 100},
    %{name: "org_admin", display_name: "Organization Administrator", level: 80},
    %{name: "billing_manager", display_name: "Billing Manager", level: 60},
    %{name: "member", display_name: "Member", level: 40},
    %{name: "viewer", display_name: "Viewer", level: 20}
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [env: :string])
    env_label = Keyword.get(opts, :env, "development")

    Mix.Task.run("app.start")
    Mix.shell().info("Seeding system roles for [#{env_label}]...")

    results = Enum.map(@system_roles, &upsert_role/1)

    summarize(results, env_label)
  end

  @spec upsert_role(map()) :: {:inserted, String.t()} | {:skipped, String.t()} | {:error, String.t()}
  defp upsert_role(%{name: name} = attrs) do
    case Repo.get_by(Role, name: name) do
      nil ->
        case Repo.insert(Role.system_changeset(%Role{}, attrs)) do
          {:ok, role} -> {:inserted, role.name}
          {:error, changeset} -> {:error, "#{name}: #{format_errors(changeset)}"}
        end

      _existing ->
        {:skipped, name}
    end
  end

  @spec summarize(list(), String.t()) :: :ok
  defp summarize(results, env_label) do
    inserted = Enum.count(results, &match?({:inserted, _}, &1))
    skipped = Enum.count(results, &match?({:skipped, _}, &1))
    errors = Enum.filter(results, &match?({:error, _}, &1))

    Mix.shell().info("  Inserted: #{inserted}")
    Mix.shell().info("  Skipped:  #{skipped}")

    Enum.each(errors, fn {:error, msg} ->
      Mix.shell().error("  Error: #{msg}")
    end)

    if Enum.empty?(errors) do
      Mix.shell().info("Role seeding complete for [#{env_label}].")
    else
      Mix.raise("Role seeding encountered #{length(errors)} error(s).")
    end
  end

  @spec format_errors(Ecto.Changeset.t()) :: String.t()
  defp format_errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map(fn {field, messages} -> "#{field}: #{Enum.join(messages, ", ")}" end)
    |> Enum.join("; ")
  end
end

defmodule Platform.Accounts.Role do
  @moduledoc "Ecto schema representing a system-level permission role."

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          name: String.t(),
          display_name: String.t(),
          level: non_neg_integer()
        }

  schema "roles" do
    field :name, :string
    field :display_name, :string
    field :level, :integer, default: 0

    timestamps(type: :utc_datetime)
  end

  @spec system_changeset(t(), map()) :: Ecto.Changeset.t()
  def system_changeset(%__MODULE__{} = role, params) do
    role
    |> cast(params, [:name, :display_name, :level])
    |> validate_required([:name, :display_name, :level])
    |> validate_length(:name, min: 2, max: 64)
    |> validate_number(:level, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> unique_constraint(:name)
  end
end
```
