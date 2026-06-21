```elixir
defmodule Mix.Tasks.Db.Seed do
  @shortdoc "Seeds the database with initial reference data"

  @moduledoc """
  Populates the database with the reference data required for the application
  to operate. Runs after a fresh schema creation or full reset.

      mix db.seed

  This task is strictly additive: existing records are skipped via on-conflict
  upsert semantics, making it safe to re-run in any environment.
  """

  use Mix.Task

  alias MyApp.Repo
  alias MyApp.Accounts.Role
  alias MyApp.Catalog.Category

  @roles [
    %{name: "admin", description: "Full system access"},
    %{name: "editor", description: "Can create and edit content"},
    %{name: "viewer", description: "Read-only access"}
  ]

  @categories [
    %{slug: "electronics", label: "Electronics"},
    %{slug: "clothing", label: "Clothing & Apparel"},
    %{slug: "books", label: "Books & Media"},
    %{slug: "home-garden", label: "Home & Garden"},
    %{slug: "sports", label: "Sports & Outdoors"}
  ]

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")
    Mix.shell().info("Starting database seed...")

    with :ok <- seed_roles(),
         :ok <- seed_categories() do
      Mix.shell().info("Seed complete.")
    else
      {:error, reason} ->
        Mix.shell().error("Seed failed: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp seed_roles do
    Enum.each(@roles, fn attrs ->
      %Role{}
      |> Role.changeset(attrs)
      |> Repo.insert!(
        on_conflict: {:replace, [:description]},
        conflict_target: :name
      )
    end)

    Mix.shell().info("  ✓ Roles seeded (#{length(@roles)})")
    :ok
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp seed_categories do
    Enum.each(@categories, fn attrs ->
      %Category{}
      |> Category.changeset(attrs)
      |> Repo.insert!(
        on_conflict: {:replace, [:label]},
        conflict_target: :slug
      )
    end)

    Mix.shell().info("  ✓ Categories seeded (#{length(@categories)})")
    :ok
  rescue
    e -> {:error, Exception.message(e)}
  end
end
```
