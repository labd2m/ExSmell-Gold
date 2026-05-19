```elixir
defmodule Payroll.TaxResidency do
  defstruct [:country, :state, :municipality, :tax_id, :regime, :exempt, :treaty_country]
end

defmodule Payroll.BenefitDeduction do
  defstruct [:benefit_type, :provider, :employee_contribution_cents, :employer_contribution_cents, :pre_tax]
end

defmodule Payroll.EarningsHistory do
  defstruct [:month, :gross_cents, :bonus_cents, :overtime_cents, :commission_cents]
end

defmodule Payroll.CompensationBreakdown do
  defstruct [
    :base_salary_cents,
    :bonus_cents,
    :overtime_cents,
    :commission_cents,
    :allowances,
    :deductions,
    :benefits
  ]
end

defmodule Payroll.EmployeeRecord do
  @enforce_keys [:id, :name, :department, :compensation]
  defstruct [
    :id,
    :name,
    :department,
    :job_grade,
    :hire_date,
    :contract_type,
    :compensation,
    :tax_residency,
    :bank_details,
    :earnings_history,
    :dependants_count,
    :custom_fields
  ]
end

defmodule Payroll.PayrollRun do
  @enforce_keys [:run_id, :period, :employees]
  defstruct [:run_id, :period, :pay_date, :currency, :employees, :run_type, :notes]
end

defmodule Payroll.EmployeeRepo do
  @moduledoc "Simulates loading all active employees for a payroll run."

  @spec build_run(String.t(), String.t()) :: Payroll.PayrollRun.t()
  def build_run(run_id, period) do
    employees =
      Enum.map(1..6_000, fn i ->
        base = Enum.random(300_000..2_000_000)

        %Payroll.EmployeeRecord{
          id: "EMP-#{i}",
          name: "Employee #{i}",
          department: "dept-#{rem(i, 40)}",
          job_grade: "G#{rem(i, 8) + 1}",
          hire_date: Date.utc_today() |> Date.add(-rem(i * 31, 3_650)),
          contract_type: Enum.random([:clt, :pj, :intern]),
          compensation: %Payroll.CompensationBreakdown{
            base_salary_cents: base,
            bonus_cents: if(rem(i, 4) == 0, do: div(base, 12), else: 0),
            overtime_cents: if(rem(i, 10) == 0, do: Enum.random(10_000..100_000), else: 0),
            commission_cents: if(rem(i, 5) == 0, do: Enum.random(5_000..200_000), else: 0),
            allowances: %{
              meal_voucher_cents: 55_000,
              transport_cents: 22_000,
              home_office_cents: if(rem(i, 3) == 0, do: 15_000, else: 0)
            },
            deductions: %{
              inss_cents: div(base, 11),
              fgts_cents: div(base, 12),
              health_plan_cents: 25_000,
              dental_cents: 5_000
            },
            benefits: Enum.map(1..4, fn j ->
              %Payroll.BenefitDeduction{
                benefit_type: Enum.random(["health", "dental", "life_insurance", "pension"]),
                provider: "Provider #{j}",
                employee_contribution_cents: j * 5_000,
                employer_contribution_cents: j * 10_000,
                pre_tax: j < 3
              }
            end)
          },
          tax_residency: %Payroll.TaxResidency{
            country: "BR",
            state: Enum.random(["SP", "RJ", "MG", "RS", "BA"]),
            municipality: "São Paulo",
            tax_id: "#{String.pad_leading("#{i}", 11, "0")}",
            regime: :irrf_tabela_progressiva,
            exempt: rem(i, 50) == 0,
            treaty_country: nil
          },
          bank_details: %{
            bank_code: "341",
            agency: String.pad_leading("#{rem(i, 9_999)}", 4, "0"),
            account: String.pad_leading("#{i}", 8, "0"),
            account_type: :checking,
            pix_key: "#{i}@payroll.internal"
          },
          earnings_history: Enum.map(1..12, fn m ->
            %Payroll.EarningsHistory{
              month: "#{2024}-#{String.pad_leading("#{m}", 2, "0")}",
              gross_cents: base + Enum.random(-50_000..100_000),
              bonus_cents: if(rem(m, 3) == 0, do: div(base, 12), else: 0),
              overtime_cents: Enum.random(0..50_000),
              commission_cents: Enum.random(0..80_000)
            }
          end),
          dependants_count: rem(i, 5),
          custom_fields: %{
            cost_center: "CC-#{rem(i, 30)}",
            project_code: "PROJ-#{rem(i, 20)}",
            union_member: rem(i, 7) == 0
          }
        }
      end)

    %Payroll.PayrollRun{
      run_id: run_id,
      period: period,
      pay_date: Date.utc_today() |> Date.add(5),
      currency: "BRL",
      employees: employees,
      run_type: :regular,
      notes: "Monthly payroll run for #{period}"
    }
  end
end

defmodule Payroll.TaxCalculator do
  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{runs: []}, opts)
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:calculate, run}, _from, state) do
    results =
      Enum.map(run.employees, fn emp ->
        gross = emp.compensation.base_salary_cents + emp.compensation.bonus_cents
        inss = div(gross, 11)
        irrf = max(0, div(gross - inss, 5) - 45_000)
        %{employee_id: emp.id, gross_cents: gross, inss_cents: inss, irrf_cents: irrf}
      end)

    {:reply, {:ok, results}, %{state | runs: [run.run_id | state.runs]}}
  end
end

defmodule Payroll.TaxCalculationClient do
  @moduledoc "Builds the payroll run and submits it to the tax calculation server."

  require Logger

  @spec calculate_all(pid(), {String.t(), String.t()}) ::
          {:ok, list(map())} | {:error, term()}
  def calculate_all(calculator_pid, {run_id, period}) do
    Logger.info("Building payroll run #{run_id} for period #{period}")

    run = Payroll.EmployeeRepo.build_run(run_id, period)

    Logger.info(
      "Payroll run built — #{length(run.employees)} employees — submitting for tax calculation"
    )

    result = GenServer.call(calculator_pid, {:calculate, run}, :infinity)

    case result do
      {:ok, tax_lines} ->
        Logger.info("Tax calculation complete — #{length(tax_lines)} lines produced")
        {:ok, tax_lines}

      error ->
        Logger.error("Tax calculation failed: #{inspect(error)}")
        {:error, error}
    end
  end
end
```
