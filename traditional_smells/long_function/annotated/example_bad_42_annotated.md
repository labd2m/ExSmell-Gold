# Annotated Example — Code Smell: Long Function

## Metadata

- **Smell name:** Long Function
- **Expected smell location:** `ELearning.EnrollmentService.enroll/3`
- **Affected function(s):** `enroll/3`
- **Short explanation:** `enroll/3` handles prerequisite checking, seat-availability enforcement, payment processing, enrollment persistence, LMS-account provisioning, first-lesson scheduling, certificate-template creation, and confirmation-email dispatch all in one deeply nested function body.

---

```elixir
defmodule ELearning.EnrollmentService do
  @moduledoc """
  Manages course enrollments including prerequisite verification,
  payment, LMS provisioning, and scheduling.
  """

  require Logger

  alias ELearning.{
    Course, Enrollment, Prerequisite, PaymentGateway,
    LMSProvisioner, LessonScheduler, Certificate, Mailer
  }

  @grace_period_days   7
  @cert_expiry_years   2

  # VALIDATION: SMELL START - Long Function
  # VALIDATION: This is a smell because `enroll/3` sequences prerequisite
  # validation, seat-limit checks, coupon resolution, payment charging,
  # enrollment record creation, LMS account setup, first-lesson scheduling,
  # certificate template creation, and confirmation email into one function
  # that exceeds 100 lines with no helper function extraction.
  def enroll(learner, course_id, opts \\ []) do
    coupon_code = Keyword.get(opts, :coupon_code)
    gift_by     = Keyword.get(opts, :gift_by)

    # 1. Load and validate the course
    case Course.get(course_id) do
      nil ->
        {:error, :course_not_found}

      %Course{published: false} ->
        {:error, :course_not_available}

      %Course{} = course ->
        # 2. Check prerequisites
        required_prereqs = Prerequisite.list_for_course(course.id)

        completed_ids =
          learner.id
          |> Enrollment.completed_course_ids()

        missing_prereqs =
          Enum.reject(required_prereqs, &(&1.required_course_id in completed_ids))

        if missing_prereqs != [] do
          {:error, {:prerequisites_not_met, Enum.map(missing_prereqs, & &1.required_course_id)}}
        else
          # 3. Check if already enrolled
          if Enrollment.exists?(learner.id, course.id) do
            {:error, :already_enrolled}
          else
            # 4. Check seat availability
            if course.seat_limit do
              enrolled_count = Enrollment.count_active(course.id)

              if enrolled_count >= course.seat_limit do
                {:error, :no_seats_available}
              end
            end

            # 5. Resolve pricing (coupon / gift)
            {final_price_cents, discount_applied} =
              cond do
                gift_by != nil ->
                  {0, :gift}

                coupon_code != nil ->
                  case Course.apply_coupon(course.id, coupon_code) do
                    {:ok, discounted} ->
                      Logger.info("Coupon #{coupon_code} applied — #{discounted} cents")
                      {discounted, {:coupon, coupon_code}}

                    {:error, _} ->
                      Logger.warning("Invalid coupon #{coupon_code} — charging full price")
                      {course.price_cents, :none}
                  end

                true ->
                  {course.price_cents, :none}
              end

            # 6. Process payment if price > 0
            payment_ref =
              if final_price_cents > 0 do
                case PaymentGateway.charge(learner.payment_method_id, %{
                  amount_cents:  final_price_cents,
                  currency:      course.currency || "usd",
                  description:   "Enrollment: #{course.title}",
                  metadata:      %{course_id: course.id, learner_id: learner.id}
                }) do
                  {:error, reason} ->
                    Logger.error("Payment failed for #{learner.id}: #{inspect(reason)}")
                    throw({:payment_failed, reason})

                  {:ok, charge} ->
                    charge.id
                end
              else
                nil
              end

            # 7. Create enrollment record
            enrollment_attrs = %{
              learner_id:       learner.id,
              course_id:        course.id,
              price_paid_cents: final_price_cents,
              discount:         discount_applied,
              payment_ref:      payment_ref,
              gifted_by:        gift_by,
              status:           :active,
              expires_at:       Date.add(Date.utc_today(), course.duration_days + @grace_period_days),
              enrolled_at:      DateTime.utc_now()
            }

            case Enrollment.insert(enrollment_attrs) do
              {:error, reason} ->
                Logger.error("Enrollment insert failed: #{inspect(reason)}")
                {:error, :persistence_failed}

              {:ok, enrollment} ->
                # 8. Provision LMS access
                case LMSProvisioner.grant_access(learner, course) do
                  {:ok, lms_user_id} ->
                    Enrollment.set_lms_user_id(enrollment.id, lms_user_id)

                  {:error, reason} ->
                    Logger.warning("LMS provisioning failed: #{inspect(reason)}")
                end

                # 9. Schedule first lesson
                first_lesson = Course.first_lesson(course.id)

                if first_lesson do
                  LessonScheduler.schedule(%{
                    learner_id:  learner.id,
                    lesson_id:   first_lesson.id,
                    scheduled_for: DateTime.add(DateTime.utc_now(), 86_400, :second)
                  })
                end

                # 10. Create certificate template
                if course.grants_certificate do
                  Certificate.create_template(%{
                    learner_id:   learner.id,
                    course_id:    course.id,
                    issued_name:  "#{learner.first_name} #{learner.last_name}",
                    expires_on:   Date.add(Date.utc_today(), @cert_expiry_years * 365)
                  })
                end

                # 11. Send confirmation email
                email_body = """
                Hi #{learner.first_name},

                You're enrolled in "#{course.title}"!

                Start date    : #{Date.utc_today()}
                Access until  : #{enrollment.expires_at}
                Price paid    : #{if final_price_cents == 0, do: "Free", else: "$#{final_price_cents / 100}"}

                Head to your dashboard to start learning:
                https://learn.example.com/courses/#{course.slug}
                """

                case Mailer.send_email(learner.email, "You're enrolled: #{course.title}", email_body) do
                  {:ok, _}         -> :ok
                  {:error, reason} -> Logger.warning("Confirmation email failed: #{inspect(reason)}")
                end

                {:ok, enrollment}
            end
          catch
            {:payment_failed, reason} -> {:error, {:payment_failed, reason}}
          end
        end
    end
  end
  # VALIDATION: SMELL END
end
```
