```elixir
defmodule Academia.Enrollment.CapacityManager do
  @moduledoc """
  Manages course section capacity and waitlist progression for academic enrollment.

  Enforces seat limits, handles waitlist promotion when seats open,
  and provides current capacity snapshots for enrollment dashboards.
  """

  alias Academia.Enrollment.{CourseSection, Enrollment, WaitlistEntry}
  alias Academia.Repo
  import Ecto.Query, warn: false

  @type enroll_result ::
          {:ok, :enrolled, Enrollment.t()}
          | {:ok, :waitlisted, WaitlistEntry.t()}
          | {:error, :already_enrolled}
          | {:error, :already_waitlisted}
          | {:error, :section_not_found}

  @doc """
  Enrolls a student in a course section, or adds them to the waitlist if full.

  Returns a tagged result indicating whether the student was directly enrolled
  or placed on the waitlist.
  """
  @spec enroll(Ecto.UUID.t(), Ecto.UUID.t()) :: enroll_result()
  def enroll(student_id, section_id) do
    Repo.transaction(fn ->
      with {:ok, section} <- fetch_section(section_id),
           :ok <- check_not_enrolled(student_id, section_id),
           :ok <- check_not_waitlisted(student_id, section_id) do
        available = available_seats(section)

        if available > 0 do
          {:ok, :enrolled, create_enrollment!(student_id, section_id)}
        else
          {:ok, :waitlisted, create_waitlist_entry!(student_id, section_id)}
        end
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> unwrap_transaction()
  end

  @doc """
  Withdraws a student from a section, promoting the next waitlisted student if any.
  """
  @spec withdraw(Ecto.UUID.t(), Ecto.UUID.t()) ::
          :ok | {:error, :enrollment_not_found}
  def withdraw(student_id, section_id) do
    Repo.transaction(fn ->
      case Repo.get_by(Enrollment, student_id: student_id, section_id: section_id, status: :active) do
        nil ->
          Repo.rollback(:enrollment_not_found)

        enrollment ->
          enrollment |> Enrollment.changeset(%{status: :withdrawn}) |> Repo.update!()
          promote_next_waitlisted(section_id)
          :ok
      end
    end)
    |> unwrap_transaction()
  end

  @doc """
  Returns a capacity snapshot for a given section.
  """
  @spec capacity_snapshot(Ecto.UUID.t()) ::
          {:ok, %{total: integer(), enrolled: integer(), waitlisted: integer(), available: integer()}}
          | {:error, :section_not_found}
  def capacity_snapshot(section_id) do
    with {:ok, section} <- fetch_section(section_id) do
      enrolled = count_active_enrollments(section_id)
      waitlisted = count_waitlist_entries(section_id)

      {:ok, %{
        total: section.capacity,
        enrolled: enrolled,
        waitlisted: waitlisted,
        available: max(section.capacity - enrolled, 0)
      }}
    end
  end

  defp fetch_section(section_id) do
    case Repo.get(CourseSection, section_id) do
      nil -> {:error, :section_not_found}
      section -> {:ok, section}
    end
  end

  defp check_not_enrolled(student_id, section_id) do
    if Repo.exists?(where(Enrollment, student_id: ^student_id, section_id: ^section_id, status: :active)) do
      {:error, :already_enrolled}
    else
      :ok
    end
  end

  defp check_not_waitlisted(student_id, section_id) do
    if Repo.exists?(where(WaitlistEntry, student_id: ^student_id, section_id: ^section_id)) do
      {:error, :already_waitlisted}
    else
      :ok
    end
  end

  defp available_seats(section) do
    enrolled = count_active_enrollments(section.id)
    max(section.capacity - enrolled, 0)
  end

  defp count_active_enrollments(section_id) do
    Enrollment |> where([e], e.section_id == ^section_id and e.status == :active) |> Repo.aggregate(:count)
  end

  defp count_waitlist_entries(section_id) do
    WaitlistEntry |> where([w], w.section_id == ^section_id) |> Repo.aggregate(:count)
  end

  defp create_enrollment!(student_id, section_id) do
    %Enrollment{}
    |> Enrollment.changeset(%{student_id: student_id, section_id: section_id, status: :active})
    |> Repo.insert!()
  end

  defp create_waitlist_entry!(student_id, section_id) do
    position = count_waitlist_entries(section_id) + 1
    %WaitlistEntry{}
    |> WaitlistEntry.changeset(%{student_id: student_id, section_id: section_id, position: position})
    |> Repo.insert!()
  end

  defp promote_next_waitlisted(section_id) do
    next =
      WaitlistEntry
      |> where([w], w.section_id == ^section_id)
      |> order_by([w], asc: w.position)
      |> limit(1)
      |> Repo.one()

    if next do
      Repo.delete!(next)
      create_enrollment!(next.student_id, section_id)
    end
  end

  defp unwrap_transaction({:ok, result}), do: result
  defp unwrap_transaction({:error, reason}), do: {:error, reason}
end
```
