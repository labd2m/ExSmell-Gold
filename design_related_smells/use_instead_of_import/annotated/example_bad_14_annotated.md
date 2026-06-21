# example_bad_14_annotated.md

## Metadata

- **Smell Name:** "Use" instead of "import"
- **Expected Smell Location:** `CRM.LeadManager` module, `use CRM.SearchHelpers` directive
- **Affected Function(s):** Module-level directive (affects the entire `CRM.LeadManager` module)
- **Short Explanation:** `CRM.LeadManager` uses `use CRM.SearchHelpers` to access lead-querying and sorting functions. The `__using__/1` macro also silently injects `import CRM.FilterUtils` into the caller, propagating filter-building helpers into `LeadManager` without any explicit declaration. Since the module only needs the search helpers, `import CRM.SearchHelpers` would expose only the intended functions and keep the dependency surface explicit.

## Code

```elixir
defmodule CRM.FilterUtils do
  @moduledoc """
  Composable filter predicate builders for CRM entity queries.
  """

  def by_field(field, value) do
    fn record -> Map.get(record, field) == value end
  end

  def by_range(field, min, max) do
    fn record ->
      val = Map.get(record, field)
      not is_nil(val) and val >= min and val <= max
    end
  end

  def by_keyword(fields, keyword) do
    lower = String.downcase(keyword)

    fn record ->
      Enum.any?(fields, fn f ->
        record
        |> Map.get(f, "")
        |> to_string()
        |> String.downcase()
        |> String.contains?(lower)
      end)
    end
  end

  def combine_and(filters) do
    fn record -> Enum.all?(filters, & &1.(record)) end
  end

  def combine_or(filters) do
    fn record -> Enum.any?(filters, & &1.(record)) end
  end
end

defmodule CRM.SearchHelpers do
  @moduledoc """
  Lead and contact search, ranking, and pagination helpers shared across
  CRM modules via `use`.
  """

  defmacro __using__(_opts) do
    quote do
      import CRM.FilterUtils  # propagates filter dependency into every caller

      def search(records, query, fields \\ [:name, :email, :company]) do
        if is_nil(query) or query == "" do
          records
        else
          filter = by_keyword(fields, query)
          Enum.filter(records, filter)
        end
      end

      def sort_by_field(records, field, direction \\ :asc) do
        Enum.sort_by(records, &Map.get(&1, field), direction)
      end

      def paginate(records, page, per_page \\ 25) do
        offset = (page - 1) * per_page

        %{
          data:        Enum.slice(records, offset, per_page),
          page:        page,
          per_page:    per_page,
          total:       length(records),
          total_pages: ceil(length(records) / per_page)
        }
      end

      def score_lead(lead) do
        base = 0
        base = if lead[:email], do: base + 20, else: base
        base = if lead[:phone], do: base + 15, else: base
        base = if lead[:company], do: base + 25, else: base
        base = if lead[:deal_value_cents] && lead.deal_value_cents > 0, do: base + 30, else: base
        base + (lead[:interaction_count] || 0) * 2
      end
    end
  end
end

defmodule CRM.LeadManager do
  @moduledoc """
  Manages CRM leads through their lifecycle: creation, qualification, assignment,
  scoring, stage progression, and archival.
  """

  # VALIDATION: SMELL START - "Use" instead of "import"
  # VALIDATION: This is a smell because `use CRM.SearchHelpers` triggers
  # VALIDATION: `__using__/1`, which injects `import CRM.FilterUtils` into
  # VALIDATION: `LeadManager`. Filter-building functions like `by_field/2`,
  # VALIDATION: `by_range/3`, `combine_and/1`, and `combine_or/1` silently
  # VALIDATION: enter this module's namespace. The manager only needs the
  # VALIDATION: search, sort, paginate, and score helpers; `import CRM.SearchHelpers`
  # VALIDATION: would be explicit and sufficient.
  use CRM.SearchHelpers
  # VALIDATION: SMELL END

  @stages [:new, :contacted, :qualified, :proposal, :negotiation, :won, :lost]
  @auto_qualify_score 60

  def create(params) do
    with :ok <- validate_params(params) do
      lead = %{
        id:                lead_id(),
        name:              params.name,
        email:             params[:email],
        phone:             params[:phone],
        company:           params[:company],
        deal_value_cents:  params[:deal_value_cents] || 0,
        stage:             :new,
        owner_id:          params[:owner_id],
        interaction_count: 0,
        score:             0,
        tags:              params[:tags] || [],
        created_at:        DateTime.utc_now(),
        updated_at:        DateTime.utc_now()
      }

      {:ok, %{lead | score: score_lead(lead)}}
    end
  end

  def advance_stage(%{stage: current} = lead) do
    idx  = Enum.find_index(@stages, &(&1 == current))
    next = Enum.at(@stages, idx + 1)

    cond do
      current in [:won, :lost] -> {:error, :terminal_stage}
      is_nil(next)             -> {:error, :no_next_stage}
      true                     ->
        {:ok, %{lead | stage: next, updated_at: DateTime.utc_now()}}
    end
  end

  def record_interaction(lead, _interaction_type) do
    updated = %{lead |
      interaction_count: lead.interaction_count + 1,
      updated_at:        DateTime.utc_now()
    }
    scored = %{updated | score: score_lead(updated)}
    {:ok, scored}
  end

  def qualify_if_ready(lead) do
    if lead.score >= @auto_qualify_score and lead.stage == :contacted do
      advance_stage(lead)
    else
      {:ok, lead}
    end
  end

  def assign(lead, owner_id) do
    {:ok, %{lead | owner_id: owner_id, updated_at: DateTime.utc_now()}}
  end

  def list(leads, opts \\ []) do
    query    = opts[:query]
    sort_by  = opts[:sort_by] || :created_at
    page     = opts[:page] || 1
    per_page = opts[:per_page] || 25

    leads
    |> maybe_filter_stage(opts[:stage])
    |> search(query)
    |> sort_by_field(sort_by, opts[:direction] || :desc)
    |> paginate(page, per_page)
  end

  defp maybe_filter_stage(leads, nil), do: leads

  defp maybe_filter_stage(leads, stage) do
    filter = by_field(:stage, stage)
    Enum.filter(leads, filter)
  end

  defp validate_params(%{name: name}) when is_binary(name) and name != "", do: :ok
  defp validate_params(_), do: {:error, :missing_name}

  defp lead_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false) |> then(&"LD-#{&1}")
  end
end
```
