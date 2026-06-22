```elixir
defmodule Mix.Tasks.Data.Backfill.UserSlugs do
  @moduledoc """
  Backfills the `slug` field for all users that do not yet have one.

  Runs in dry-run mode by default, printing what would change without
  writing to the database. Pass `--commit` to persist the changes.

  ## Usage

      mix data.backfill.user_slugs
      mix data.backfill.user_slugs --commit
      mix data.backfill.user_slugs --commit --batch-size 100

  """

  use Mix.Task

  import Ecto.Query, only: [from: 2]

  alias Platform.{Repo, Accounts.User}
  alias Platform.SlugGenerator

  @shortdoc "Backfills missing user slug fields"

  @default_batch_size 200

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [commit: :boolean, batch_size: :integer],
        aliases: [c: :commit]
      )

    commit? = Keyword.get(opts, :commit, false)
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)

    Mix.Task.run("app.start")

    mode_label = if commit?, do: "COMMIT", else: "DRY RUN"
    Mix.shell().info("\n[#{mode_label}] Backfilling user slugs (batch size: #{batch_size})\n")

    {processed, updated, skipped} = process_all(batch_size, commit?)

    print_summary(processed, updated, skipped, commit?)
  end

  defp process_all(batch_size, commit?) do
    from(u in User, where: is_nil(u.slug), order_by: [asc: u.id])
    |> Repo.all()
    |> Enum.chunk_every(batch_size)
    |> Enum.reduce({0, 0, 0}, fn batch, {proc, upd, skip} ->
      {b_proc, b_upd, b_skip} = process_batch(batch, commit?)
      {proc + b_proc, upd + b_upd, skip + b_skip}
    end)
  end

  defp process_batch(users, commit?) do
    Enum.reduce(users, {0, 0, 0}, fn user, {proc, upd, skip} ->
      case build_slug(user) do
        {:ok, slug} ->
          apply_update(user, slug, commit?)
          {proc + 1, upd + 1, skip}

        {:error, reason} ->
          Mix.shell().error("  [skip] user #{user.id}: #{inspect(reason)}")
          {proc + 1, upd, skip + 1}
      end
    end)
  end

  defp build_slug(%User{id: id, name: name}) when is_binary(name) and name != "" do
    SlugGenerator.generate_unique(User, name)
  end

  defp build_slug(%User{id: id}) do
    SlugGenerator.generate_unique(User, "user-#{id}")
  end

  defp apply_update(user, slug, false) do
    Mix.shell().info("  [would update] user #{user.id} → slug: \"#{slug}\"")
  end

  defp apply_update(user, slug, true) do
    case user |> User.slug_changeset(%{slug: slug}) |> Repo.update() do
      {:ok, _} ->
        Mix.shell().info("  [updated] user #{user.id} → \"#{slug}\"")

      {:error, changeset} ->
        errors = format_errors(changeset)
        Mix.shell().error("  [failed] user #{user.id}: #{errors}")
    end
  end

  defp print_summary(processed, updated, skipped, commit?) do
    action = if commit?, do: "Updated", else: "Would update"

    Mix.shell().info("""

    Backfill complete.
      Processed : #{processed}
      #{action}  : #{updated}
      Skipped   : #{skipped}
    #{unless commit?, do: "\nRun with --commit to apply changes.", else: ""}
    """)
  end

  defp format_errors(changeset) do
    changeset.errors
    |> Enum.map_join(", ", fn {field, {msg, _}} -> "#{field}: #{msg}" end)
  end
end
```
