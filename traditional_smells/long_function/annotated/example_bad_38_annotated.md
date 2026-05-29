# Annotated Example — Code Smell: Long Function

## Metadata

- **Smell name:** Long Function
- **Expected smell location:** `HR.OnboardingService.onboard_employee/2`
- **Affected function(s):** `onboard_employee/2`
- **Short explanation:** `onboard_employee/2` performs department existence checks, role assignment, system-account provisioning, equipment-request creation, payroll enrollment, benefit-plan selection, buddy assignment, onboarding-checklist creation, and welcome-email dispatch inside a single oversized function.

---

```elixir
defmodule HR.OnboardingService do
  @moduledoc """
  Automates new-employee onboarding including system access
  provisioning, payroll setup, and checklist generation.
  """

  require Logger

  alias HR.{
    Employee, Department, Role, SystemProvisioner,
    EquipmentRequest, Payroll, BenefitsPlan,
    OnboardingChecklist, BuddyMatcher, Mailer
  }

  @default_benefit_plan  :standard
  @probation_months      3

  # VALIDATION: SMELL START - Long Function
  # VALIDATION: This is a smell because `onboard_employee/2` chains
  # department lookup, role validation, system-account provisioning,
  # equipment-request creation, payroll enrollment, benefits-plan
  # assignment, onboarding-buddy matching, checklist seeding, and
  # welcome-email dispatch into a single function of over 100 lines
  # without any delegation to focused private helpers.
  def onboard_employee(employee_attrs, opts \\ []) do
    operator   = Keyword.get(opts, :operator, "hr_system")
    start_date = Keyword.get(opts, :start_date, Date.utc_today())

    # 1. Validate department
    department =
      case Department.get(employee_attrs.department_id) do
        nil    -> nil
        dept   -> dept
      end

    if is_nil(department) do
      {:error, :department_not_found}
    else
      # 2. Validate role
      role =
        case Role.find_by_title(employee_attrs.job_title, department.id) do
          nil  -> nil
          r    -> r
        end

      if is_nil(role) do
        {:error, :role_not_found}
      else
        # 3. Create the employee record
        attrs = %{
          first_name:      employee_attrs.first_name,
          last_name:       employee_attrs.last_name,
          email:           employee_attrs.email,
          phone:           employee_attrs.phone,
          department_id:   department.id,
          role_id:         role.id,
          employment_type: employee_attrs.employment_type || :full_time,
          start_date:      start_date,
          probation_end:   Date.add(start_date, @probation_months * 30),
          status:          :active,
          created_by:      operator,
          inserted_at:     DateTime.utc_now()
        }

        case Employee.insert(attrs) do
          {:error, reason} ->
            Logger.error("Employee insert failed: #{inspect(reason)}")
            {:error, :employee_creation_failed}

          {:ok, employee} ->
            Logger.info("Employee #{employee.id} created (#{employee.email})")

            # 4. Provision system accounts
            systems = role.required_systems || [:slack, :github, :jira]

            provision_results =
              Enum.map(systems, fn system ->
                case SystemProvisioner.create_account(system, %{
                  email:      employee.email,
                  full_name:  "#{employee.first_name} #{employee.last_name}",
                  department: department.name,
                  role:       role.title
                }) do
                  {:ok, account}   -> {:ok, system, account}
                  {:error, reason} ->
                    Logger.warning("Provisioning #{system} failed: #{inspect(reason)}")
                    {:error, system}
                end
              end)

            provisioned = Enum.filter(provision_results, &match?({:ok, _, _}, &1))
            Logger.info("Provisioned #{length(provisioned)}/#{length(systems)} systems for #{employee.id}")

            # 5. Raise equipment request
            equipment_items =
              role.equipment_profile || [:laptop, :monitor, :keyboard, :headset]

            EquipmentRequest.create(%{
              employee_id:   employee.id,
              department_id: department.id,
              items:         equipment_items,
              needed_by:     start_date,
              priority:      :normal,
              requested_by:  operator
            })

            # 6. Enroll in payroll
            case Payroll.enroll(employee.id, %{
              salary_cents:     employee_attrs.salary_cents,
              pay_frequency:    employee_attrs.pay_frequency || :monthly,
              bank_account:     employee_attrs.bank_account,
              tax_code:         employee_attrs.tax_code,
              effective_from:   start_date
            }) do
              {:error, reason} ->
                Logger.error("Payroll enrollment failed for #{employee.id}: #{inspect(reason)}")

              {:ok, _payroll} ->
                Logger.info("Payroll enrolled for #{employee.id}")
            end

            # 7. Assign benefits plan
            plan = BenefitsPlan.find_for_role(role.id) || BenefitsPlan.get(@default_benefit_plan)

            BenefitsPlan.assign_employee(plan.id, employee.id, effective_from: start_date)

            # 8. Match an onboarding buddy
            buddy = BuddyMatcher.find_buddy(department.id, exclude_id: employee.id)

            if buddy do
              Employee.set_buddy(employee.id, buddy.id)
              Logger.info("Buddy #{buddy.id} assigned to new employee #{employee.id}")
            end

            # 9. Seed onboarding checklist
            checklist_items = [
              "Complete I-9 / right-to-work documents",
              "Set up email and Slack",
              "Read company handbook",
              "Complete security-awareness training",
              "Schedule 1-on-1 with manager",
              "Meet your onboarding buddy",
              "Review #{role.title} role expectations"
            ]

            OnboardingChecklist.create_for_employee(employee.id, checklist_items)

            # 10. Send welcome e-mail
            buddy_line =
              if buddy,
                do:   "Your onboarding buddy is #{buddy.first_name} #{buddy.last_name} — say hi!",
                else: ""

            email_body = """
            Hi #{employee.first_name},

            Welcome to the team! We're thrilled to have you join #{department.name}.

            Start date    : #{start_date}
            Role          : #{role.title}
            Your manager  : TBD (see checklist)
            #{buddy_line}

            Please log in to your company portal to complete your onboarding checklist.

            – HR Team
            """

            case Mailer.send_email(employee.email, "Welcome aboard! Your first steps", email_body) do
              {:ok, _}         -> :ok
              {:error, reason} -> Logger.warning("Welcome email failed: #{inspect(reason)}")
            end

            {:ok, employee}
        end
      end
    end
  end
  # VALIDATION: SMELL END
end
```
