```elixir
defmodule Elearning.CourseEnrollment do
  @moduledoc "Represents a learner's enrollment record for a course."

  defstruct [
    :id,
    :learner_id,
    :course_id,
    :course_title,
    :enrolled_at,
    :completed_at,
    :modules_total,
    :modules_completed,
    :quiz_scores,
    :passing_threshold,
    :study_seconds,
    :certificate_track,
    :instructor_name
  ]

  def get!(id) do
    %__MODULE__{
      id: id,
      learner_id: "LRN-4421",
      course_id: "CRS-202",
      course_title: "Advanced Elixir Patterns",
      enrolled_at: ~U[2024-01-10 00:00:00Z],
      completed_at: ~U[2024-03-05 18:00:00Z],
      modules_total: 12,
      modules_completed: 12,
      quiz_scores: [88, 92, 79, 95, 84, 90],
      passing_threshold: 75,
      study_seconds: 72_000,
      certificate_track: true,
      instructor_name: "Dr. Ana Ferreira"
    }
  end

  def completion_pct(%__MODULE__{modules_total: total, modules_completed: done})
      when total > 0 do
    Float.round(done / total * 100, 1)
  end
  def completion_pct(_), do: 0.0

  def passed?(%__MODULE__{quiz_scores: scores, passing_threshold: threshold}) do
    avg = Enum.sum(scores) / max(length(scores), 1)
    avg >= threshold
  end

  def final_grade(%__MODULE__{quiz_scores: []}), do: 0.0
  def final_grade(%__MODULE__{quiz_scores: scores}) do
    Float.round(Enum.sum(scores) / length(scores), 1)
  end

  def total_study_hours(%__MODULE__{study_seconds: secs}) do
    Float.round(secs / 3600, 1)
  end

  def certificate_eligible?(%__MODULE__{certificate_track: true} = enrollment) do
    completion_pct(enrollment) >= 100.0 and passed?(enrollment)
  end
  def certificate_eligible?(_), do: false

  def duration_days(%__MODULE__{enrolled_at: start, completed_at: nil}) do
    DateTime.diff(DateTime.utc_now(), start, :day)
  end
  def duration_days(%__MODULE__{enrolled_at: start, completed_at: finish}) do
    DateTime.diff(finish, start, :day)
  end
end

defmodule Elearning.Certificate do
  @moduledoc "A generated completion certificate."

  defstruct [
    :serial,
    :enrollment_id,
    :learner_id,
    :course_title,
    :instructor_name,
    :grade,
    :study_hours,
    :issued_at,
    :expires_at
  ]
end

defmodule Elearning.CertificateIssuer do
  @moduledoc """
  Issues completion certificates to learners who have successfully
  finished a certificate-track course above the passing threshold.
  """

  alias Elearning.{CourseEnrollment, Certificate}
  require Logger

  @certificate_validity_days 730

  @doc """
  Attempts to issue certificates for a batch of enrollment IDs.
  Returns a list of `{enrollment_id, result}` tuples.
  """
  def issue_batch(enrollment_ids) do
    Enum.map(enrollment_ids, fn id ->
      enrollment = CourseEnrollment.get!(id)

      if CourseEnrollment.certificate_eligible?(enrollment) do
        cert = issue_certificate(id)
        Logger.info("Certificate issued for enrollment #{id}: serial #{cert.serial}")
        {id, {:ok, cert}}
      else
        Logger.debug("Enrollment #{id} not eligible for certificate.")
        {id, {:error, :not_eligible}}
      end
    end)
  end

  defp issue_certificate(enrollment_id) do
    data = build_certificate_data(enrollment_id)

    %Certificate{
      serial:          generate_serial(),
      enrollment_id:   enrollment_id,
      learner_id:      data.learner_id,
      course_title:    data.course_title,
      instructor_name: data.instructor_name,
      grade:           data.grade,
      study_hours:     data.study_hours,
      issued_at:       DateTime.utc_now(),
      expires_at:      DateTime.add(DateTime.utc_now(), @certificate_validity_days * 86_400)
    }
  end

  defp build_certificate_data(enrollment_id) do
    enrollment  = CourseEnrollment.get!(enrollment_id)
    completion  = CourseEnrollment.completion_pct(enrollment)
    passed      = CourseEnrollment.passed?(enrollment)
    grade       = CourseEnrollment.final_grade(enrollment)
    study_hours = CourseEnrollment.total_study_hours(enrollment)
    eligible    = CourseEnrollment.certificate_eligible?(enrollment)

    %{
      learner_id:      enrollment.learner_id,
      course_title:    enrollment.course_title,
      instructor_name: enrollment.instructor_name,
      completion_pct:  completion,
      passed:          passed,
      grade:           grade,
      study_hours:     study_hours,
      eligible:        eligible
    }
  end

  defp generate_serial do
    :crypto.strong_rand_bytes(8) |> Base.encode16()
  end
end
```
