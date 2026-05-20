# Annotated Example 20

- **Smell name:** Unrelated multi-clause function
- **Expected smell location:** `CampaignEngine.trigger/1`
- **Affected function(s):** `trigger/1`
- **Short explanation:** `trigger/1` processes email campaign blasts, in-app onboarding sequences, and A/B experiment assignments — three unrelated marketing operations — merged into one multi-clause function with no shared logic or abstraction.

```elixir
defmodule CampaignEngine do
  @moduledoc """
  Marketing campaign engine responsible for triggering email blasts,
  onboarding sequences, and A/B experiment assignments.
  """

  alias CampaignEngine.{
    EmailBlast,
    OnboardingSequence,
    ABExperiment,
    ContactSegmenter,
    TemplateRenderer,
    BulkMailer,
    SequenceScheduler,
    ExperimentStore,
    EventTracker,
    CampaignStore
  }

  require Logger

  @doc """
  Trigger a marketing campaign action.

  Accepts a `%EmailBlast{}`, `%OnboardingSequence{}`, or `%ABExperiment{}`
  and initiates the corresponding campaign operation.

  ## Examples

      iex> CampaignEngine.trigger(%EmailBlast{campaign_id: "c1", segment: :churned_users})
      {:ok, %{recipients: 1230, queued_at: ~U[2024-05-01 10:00:00Z]}}

  """
  # VALIDATION: SMELL START - Unrelated multi-clause function
  # VALIDATION: This is a smell because bulk email blasting, drip onboarding
  # sequence scheduling, and A/B experiment user assignment involve different
  # data pipelines, timing mechanisms, and success metrics. Grouping them under
  # one `trigger/1` function abuses multi-clause pattern matching to mix
  # completely unrelated marketing operations.

  def trigger(%EmailBlast{
        campaign_id: campaign_id,
        segment: segment,
        template: template,
        sender_name: sender_name,
        reply_to: reply_to,
        scheduled_at: scheduled_at
      }) do
    with {:ok, campaign} <- CampaignStore.find(campaign_id),
         :ok <- validate_campaign_approved(campaign),
         {:ok, contacts} <- ContactSegmenter.resolve(segment),
         :ok <- validate_blast_size(contacts),
         {:ok, rendered_template} <- TemplateRenderer.preview(template, sample_contact()),
         _ = Logger.info("Blast preview OK, enqueueing #{length(contacts)} recipients"),
         {:ok, job} <-
           BulkMailer.enqueue_blast(%{
             campaign_id: campaign_id,
             contacts: Enum.map(contacts, & &1.id),
             template: template,
             sender_name: sender_name,
             reply_to: reply_to,
             scheduled_at: scheduled_at
           }),
         :ok <- CampaignStore.mark_scheduled(campaign_id, length(contacts), scheduled_at),
         :ok <- EventTracker.track(:blast_scheduled, %{campaign_id: campaign_id, count: length(contacts)}) do
      {:ok, %{recipients: length(contacts), queued_at: scheduled_at, job_id: job.id}}
    end
  end

  # trigger onboarding drip sequence for a new user
  def trigger(%OnboardingSequence{
        user_id: user_id,
        sequence_key: sequence_key,
        locale: locale,
        product_area: product_area
      }) do
    steps = SequenceScheduler.resolve_steps(sequence_key, locale, product_area)

    with :ok <- validate_sequence_not_started(user_id, sequence_key),
         {:ok, sequence} <-
           SequenceScheduler.enqueue_for_user(%{
             user_id: user_id,
             sequence_key: sequence_key,
             steps: steps,
             started_at: DateTime.utc_now()
           }),
         :ok <-
           EventTracker.track(:onboarding_started, %{
             user_id: user_id,
             sequence: sequence_key,
             steps: length(steps)
           }) do
      Logger.info("Onboarding sequence #{sequence_key} started for user #{user_id}")
      {:ok, %{sequence_id: sequence.id, steps: length(steps)}}
    end
  end

  # trigger A/B experiment assignment for eligible users
  def trigger(%ABExperiment{
        experiment_id: experiment_id,
        eligible_segment: segment,
        variants: variants,
        allocation: allocation
      })
      when is_list(variants) and length(variants) >= 2 do
    with :ok <- validate_allocation(allocation),
         {:ok, contacts} <- ContactSegmenter.resolve(segment),
         buckets = bucket_users(contacts, variants, allocation),
         {:ok, experiment} <-
           ExperimentStore.record_assignment(%{
             experiment_id: experiment_id,
             buckets: buckets,
             started_at: DateTime.utc_now()
           }),
         :ok <-
           EventTracker.track(:experiment_assigned, %{
             experiment_id: experiment_id,
             total_users: length(contacts)
           }) do
      Logger.info(
        "A/B experiment #{experiment_id} assigned #{length(contacts)} users to #{length(variants)} variants"
      )

      {:ok, %{experiment_id: experiment.id, assigned: length(contacts), buckets: map_sizes(buckets)}}
    end
  end

  # VALIDATION: SMELL END

  defp validate_campaign_approved(%{status: :approved}), do: :ok
  defp validate_campaign_approved(%{status: s}), do: {:error, {:campaign_not_approved, s}}

  defp validate_blast_size(contacts) when length(contacts) > 0, do: :ok
  defp validate_blast_size(_), do: {:error, :empty_segment}

  defp validate_sequence_not_started(user_id, sequence_key) do
    case SequenceScheduler.find_active(user_id, sequence_key) do
      {:ok, _} -> {:error, :sequence_already_active}
      {:error, :not_found} -> :ok
    end
  end

  defp validate_allocation(alloc) when is_map(alloc) do
    total = alloc |> Map.values() |> Enum.sum()
    if abs(total - 1.0) < 0.001, do: :ok, else: {:error, :allocation_must_sum_to_one}
  end

  defp bucket_users(contacts, variants, allocation) do
    Enum.reduce(variants, {contacts, %{}}, fn variant, {remaining, buckets} ->
      count = round(length(contacts) * Map.fetch!(allocation, variant))
      {assigned, rest} = Enum.split(remaining, count)
      {rest, Map.put(buckets, variant, Enum.map(assigned, & &1.id))}
    end)
    |> elem(1)
  end

  defp map_sizes(buckets), do: Map.new(buckets, fn {k, v} -> {k, length(v)} end)
  defp sample_contact, do: %{email: "preview@example.com", name: "Preview User"}
end
```
