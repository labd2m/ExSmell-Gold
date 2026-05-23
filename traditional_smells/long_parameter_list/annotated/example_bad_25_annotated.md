# Annotated Example 25 — Long Parameter List

## Metadata

| Field | Value |
|---|---|
| **Smell name** | Long Parameter List |
| **Expected smell location** | `ProjectManagement.Tasks.create_task/10` |
| **Affected function(s)** | `create_task/10` |
| **Explanation** | The function takes 10 individual parameters covering task content (title, description, project_id), assignment (assignee_id, reporter_id), scheduling (due_date, estimated_hours), classification (priority, label), and collaboration (notify_assignee). These naturally belong in a `%TaskDetails{}` struct and an `%AssignmentConfig{}` struct instead of a flat list. |

---

```elixir
# VALIDATION: SMELL START - Long Parameter List
# VALIDATION: This is a smell because `create_task/10` takes ten individual
# positional parameters. Task content (title, description, project_id),
# people involved (assignee_id, reporter_id), scheduling (due_date,
# estimated_hours), classification (priority, label), and a delivery option
# (notify_assignee) are all passed as a flat list. At the call site, it is
# easy to confuse the two ID fields or omit an optional trailing argument
# in the wrong position.
defmodule ProjectManagement.Tasks do
  @moduledoc """
  Handles task creation, assignment, and notification within projects.
  """

  require Logger

  alias ProjectManagement.Repo
  alias ProjectManagement.Schemas.Task
  alias ProjectManagement.Schemas.TaskHistory
  alias ProjectManagement.ActivityFeed
  alias ProjectManagement.Mailer

  @valid_priorities ~w(low medium high critical)

  def create_task(
        title,
        description,
        project_id,
        assignee_id,
        reporter_id,
        due_date,
        estimated_hours,
        priority,
        label,
        notify_assignee
      ) do
# VALIDATION: SMELL END
    with :ok <- validate_title(title),
         :ok <- validate_priority(priority),
         :ok <- maybe_validate_due_date(due_date),
         :ok <- validate_estimated_hours(estimated_hours) do
      task_attrs = %{
        title: String.trim(title),
        description: description,
        project_id: project_id,
        assignee_id: assignee_id,
        reporter_id: reporter_id,
        due_date: due_date,
        estimated_hours: estimated_hours,
        priority: priority,
        label: label,
        status: :open,
        inserted_at: DateTime.utc_now()
      }

      case Repo.insert(Task.changeset(%Task{}, task_attrs)) do
        {:ok, task} ->
          Repo.insert!(TaskHistory.changeset(%TaskHistory{}, %{
            task_id: task.id,
            actor_id: reporter_id,
            action: :created,
            occurred_at: DateTime.utc_now()
          }))

          ActivityFeed.publish(:task_created, %{
            task_id: task.id,
            project_id: project_id,
            actor_id: reporter_id
          })

          if notify_assignee && assignee_id do
            Mailer.send_task_assignment(assignee_id, task)
          end

          Logger.info("Task #{task.id} created in project #{project_id}")
          {:ok, task}

        {:error, changeset} ->
          Logger.error("Task creation failed: #{inspect(changeset.errors)}")
          {:error, :creation_failed}
      end
    end
  end

  defp validate_title(title) do
    if is_binary(title) and String.length(String.trim(title)) >= 3 do
      :ok
    else
      {:error, :invalid_title}
    end
  end

  defp validate_priority(p) when p in @valid_priorities, do: :ok
  defp validate_priority(p), do: {:error, {:unknown_priority, p}}

  defp maybe_validate_due_date(nil), do: :ok

  defp maybe_validate_due_date(date) do
    case Date.from_iso8601(date) do
      {:ok, _} -> :ok
      _ -> {:error, :invalid_due_date}
    end
  end

  defp validate_estimated_hours(nil), do: :ok

  defp validate_estimated_hours(hours) when is_number(hours) and hours > 0, do: :ok
  defp validate_estimated_hours(_), do: {:error, :invalid_estimated_hours}
end
```
