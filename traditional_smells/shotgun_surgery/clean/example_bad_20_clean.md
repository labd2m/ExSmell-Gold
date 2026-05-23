```elixir
defmodule Education.CourseAccessManager do
  @moduledoc """
  Manages learner enrollment, content access levels, pricing,
  certificate issuance, and support channel assignment for
  different enrollment types in the online learning platform.
  """

  alias Education.{
    Enrollment, Course, Learner, PaymentGateway,
    CertificateEngine, ContentVault, SupportRouter, ProgressTracker
  }

  def enroll_learner(%Learner{} = learner, %Course{} = course, enrollment_type) do
    with {:ok, price}      <- compute_price(course, enrollment_type),
         :ok               <- process_payment(learner, price, enrollment_type),
         {:ok, enrollment} <- create_enrollment(learner, course, enrollment_type),
         :ok               <- SupportRouter.assign(learner.id, get_support_channel(enrollment_type)) do
      {:ok, enrollment}
    end
  end

  defp compute_price(course, enrollment_type) do
    price = calculate_enrollment_price(course, enrollment_type)
    {:ok, price}
  end

  defp process_payment(_learner, 0.00, _type), do: :ok

  defp process_payment(learner, price, _type) do
    case PaymentGateway.charge(learner.payment_method, price) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:payment_failed, reason}}
    end
  end

  defp create_enrollment(learner, course, enrollment_type) do
    access_level    = get_content_access_level(enrollment_type)
    cert_type       = get_certificate_type(enrollment_type)

    enrollment = %Enrollment{
      learner_id:       learner.id,
      course_id:        course.id,
      enrollment_type:  enrollment_type,
      access_level:     access_level,
      certificate_type: cert_type,
      enrolled_at:      DateTime.utc_now(),
      expires_at:       compute_expiry(enrollment_type),
      status:           :active
    }

    with {:ok, saved} <- Enrollment.insert(enrollment) do
      ProgressTracker.initialize(learner.id, course.id)
      ContentVault.grant_access(learner.id, course.id, access_level)
      {:ok, saved}
    end
  end

  defp compute_expiry(:free),     do: nil
  defp compute_expiry(:enrolled), do: nil
  defp compute_expiry(:premium),  do: Date.add(Date.utc_today(), 365)

  def issue_certificate(%Enrollment{status: :active} = enrollment, completion_score) do
    if completion_score >= 70 do
      cert_type = get_certificate_type(enrollment.enrollment_type)
      CertificateEngine.generate(enrollment, cert_type, score: completion_score)
    else
      {:error, :minimum_score_not_met}
    end
  end

  def issue_certificate(%Enrollment{status: status}, _score) do
    {:error, {:invalid_enrollment_status, status}}
  end

  def upgrade_enrollment(%Enrollment{enrollment_type: :free} = enrollment, new_type) do
    price = calculate_enrollment_price(
      %Course{id: enrollment.course_id, base_price: enrollment.original_price},
      new_type
    )

    with :ok <- process_payment(%Learner{id: enrollment.learner_id}, price, new_type) do
      new_access = get_content_access_level(new_type)
      updated = %{enrollment | enrollment_type: new_type, access_level: new_access}
      ContentVault.upgrade_access(enrollment.learner_id, enrollment.course_id, new_access)
      Enrollment.update(updated)
    end
  end

  def upgrade_enrollment(_, _), do: {:error, :already_paid_enrollment}

  def get_content_access_level(:free),     do: :preview
  def get_content_access_level(:enrolled), do: :full
  def get_content_access_level(:premium),  do: :extended
  def get_content_access_level(_),         do: :none

  def calculate_enrollment_price(%Course{}, :free), do: 0.00

  def calculate_enrollment_price(%Course{base_price: price}, :enrolled) do
    Float.round(price, 2)
  end

  def calculate_enrollment_price(%Course{base_price: price}, :premium) do
    Float.round(price * 1.4, 2)
  end

  def calculate_enrollment_price(%Course{base_price: price}, _type) do
    Float.round(price * 0.5, 2)
  end

  def get_certificate_type(:free),     do: :none
  def get_certificate_type(:enrolled), do: :completion
  def get_certificate_type(:premium),  do: :distinction
  def get_certificate_type(_),         do: :none

  def get_support_channel(:free),     do: :community_forum
  def get_support_channel(:enrolled), do: :email
  def get_support_channel(:premium),  do: :live_chat
  def get_support_channel(_),         do: :community_forum

  def list_enrollment_types, do: [:free, :enrolled, :premium]

  def get_enrollment_summary(%Enrollment{} = enrollment) do
    %{
      type:             enrollment.enrollment_type,
      access_level:     get_content_access_level(enrollment.enrollment_type),
      certificate_type: get_certificate_type(enrollment.enrollment_type),
      support_channel:  get_support_channel(enrollment.enrollment_type),
      status:           enrollment.status
    }
  end
end
```
