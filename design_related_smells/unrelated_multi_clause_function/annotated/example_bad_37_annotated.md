# Annotated Example 37

- **Smell name:** Unrelated multi-clause function
- **Expected smell location:** `CourseManager.manage/1`
- **Affected function(s):** `manage/1`
- **Short explanation:** `manage/1` handles course publication, student enrollment, and certificate issuance — three unrelated e-learning platform operations — under a single multi-clause function. Each operation involves different actors (instructor vs student vs platform), different validations, and distinct side effects.

```elixir
defmodule CourseManager do
  @moduledoc """
  Manages the lifecycle of online courses on the e-learning platform.
  Handles course publication by instructors, student enrollment,
  and certificate issuance upon course completion.
  """

  alias CourseManager.{
    PublicationRequest,
    EnrollmentRequest,
    CertificateIssuanceRequest,
    CourseStore,
    EnrollmentStore,
    CertificateStore,
    ContentReviewer,
    PaymentProcessor,
    ProgressTracker,
    CertificateRenderer,
    LearnerMailer,
    InstructorMailer
  }

  require Logger

  @doc """
  Manage an e-learning platform action.

  Accepts a `%PublicationRequest{}`, `%EnrollmentRequest{}`, or
  `%CertificateIssuanceRequest{}` and performs the corresponding operation.

  ## Examples

      iex> CourseManager.manage(%PublicationRequest{course_id: "crs_1", instructor_id: 10})
      {:ok, %Course{id: "crs_1", status: :published}}

  """
  # VALIDATION: SMELL START - Unrelated multi-clause function
  # VALIDATION: This is a smell because publishing a course (content review,
  # search indexing), enrolling a student (payment, access provisioning), and
  # issuing a certificate (progress verification, PDF generation) are entirely
  # different e-learning workflows with different actors, validation rules,
  # and outputs. Using a single `manage/1` for all three conflates unrelated
  # educational platform operations.

  def manage(%PublicationRequest{
        course_id: course_id,
        instructor_id: instructor_id,
        pricing: pricing,
        publish_at: publish_at
      }) do
    with {:ok, course} <- CourseStore.find(course_id),
         :ok <- validate_instructor_owns_course(course, instructor_id),
         :ok <- validate_course_complete(course),
         {:ok, review} <- ContentReviewer.submit_for_review(course_id),
         :ok <- await_review_approval(review),
         {:ok, published} <-
           CourseStore.update(course_id, %{
             status: :published,
             pricing: pricing,
             publish_at: publish_at || DateTime.utc_now()
           }),
         :ok <- InstructorMailer.send_publication_confirmation(instructor_id, published) do
      Logger.info("Course #{course_id} published by instructor #{instructor_id}")
      {:ok, published}
    end
  end

  # manage student enrollment into a published course
  def manage(%EnrollmentRequest{
        course_id: course_id,
        learner_id: learner_id,
        payment_method: payment_method,
        coupon_code: coupon_code
      }) do
    with {:ok, course} <- CourseStore.find(course_id),
         :ok <- validate_course_published(course),
         :ok <- validate_not_already_enrolled(course_id, learner_id),
         {:ok, discount} <- resolve_coupon(coupon_code, course.pricing),
         final_price = max(0, course.pricing.amount - discount),
         {:ok, _payment} <- maybe_charge(payment_method, final_price, course_id),
         {:ok, enrollment} <-
           EnrollmentStore.create(%{
             course_id: course_id,
             learner_id: learner_id,
             price_paid: final_price,
             coupon_code: coupon_code,
             enrolled_at: DateTime.utc_now(),
             status: :active
           }),
         :ok <- ProgressTracker.initialize(learner_id, course_id),
         :ok <- LearnerMailer.send_enrollment_confirmation(learner_id, course, enrollment) do
      Logger.info("Learner #{learner_id} enrolled in course #{course_id}")
      {:ok, enrollment}
    end
  end

  # manage certificate issuance upon verified course completion
  def manage(%CertificateIssuanceRequest{
        course_id: course_id,
        learner_id: learner_id,
        completion_date: completion_date
      }) do
    with {:ok, enrollment} <- EnrollmentStore.find(course_id, learner_id),
         :ok <- validate_enrollment_active(enrollment),
         {:ok, progress} <- ProgressTracker.get_summary(learner_id, course_id),
         :ok <- validate_course_completed(progress),
         {:ok, course} <- CourseStore.find(course_id),
         {:ok, certificate} <-
           CertificateStore.create(%{
             course_id: course_id,
             learner_id: learner_id,
             instructor_id: course.instructor_id,
             completion_date: completion_date,
             certificate_number: generate_certificate_number(learner_id, course_id),
             issued_at: DateTime.utc_now()
           }),
         {:ok, pdf_url} <- CertificateRenderer.render(certificate, course),
         {:ok, _} <- CertificateStore.update(certificate.id, %{pdf_url: pdf_url}),
         :ok <- LearnerMailer.send_certificate(learner_id, certificate, pdf_url) do
      Logger.info("Certificate issued to learner #{learner_id} for course #{course_id}")
      {:ok, %{certificate_id: certificate.id, pdf_url: pdf_url}}
    end
  end

  # VALIDATION: SMELL END

  defp validate_instructor_owns_course(%{instructor_id: id}, id), do: :ok
  defp validate_instructor_owns_course(_, _), do: {:error, :not_course_owner}

  defp validate_course_complete(%{sections: sections}) do
    if Enum.any?(sections) do
      :ok
    else
      {:error, :course_has_no_content}
    end
  end

  defp validate_course_published(%{status: :published}), do: :ok
  defp validate_course_published(%{status: s}), do: {:error, {:course_not_published, s}}

  defp validate_not_already_enrolled(course_id, learner_id) do
    case EnrollmentStore.find(course_id, learner_id) do
      {:ok, _} -> {:error, :already_enrolled}
      {:error, :not_found} -> :ok
    end
  end

  defp validate_enrollment_active(%{status: :active}), do: :ok
  defp validate_enrollment_active(%{status: s}), do: {:error, {:enrollment_not_active, s}}

  defp validate_course_completed(%{completion_percentage: pct}) when pct >= 100, do: :ok
  defp validate_course_completed(_), do: {:error, :course_not_fully_completed}

  defp resolve_coupon(nil, _pricing), do: {:ok, 0}

  defp resolve_coupon(code, pricing) do
    case CourseStore.find_coupon(code) do
      {:ok, coupon} -> {:ok, round(pricing.amount * coupon.discount_rate)}
      {:error, :not_found} -> {:error, :invalid_coupon}
    end
  end

  defp maybe_charge(_method, 0, _course_id), do: {:ok, :free}
  defp maybe_charge(method, amount, course_id) do
    PaymentProcessor.charge(method, amount, reference: "enrollment_#{course_id}")
  end

  defp await_review_approval(%{status: :auto_approved}), do: :ok
  defp await_review_approval(%{status: :pending}), do: {:error, :pending_content_review}

  defp generate_certificate_number(learner_id, course_id) do
    "CERT-#{course_id}-#{learner_id}-#{System.os_time(:second)}"
  end
end
```
