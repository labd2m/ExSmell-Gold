```elixir
defmodule MyApp.ReplicationAgent do
  @moduledoc """
  Manages multi-region data replication for critical records.
  Tracks replication lag, acknowledgements, and triggers repair
  when replicas diverge from the primary.
  """

  use Agent

  alias MyApp.{RegionClient, AuditLog, AlertService, RepairScheduler}
  alias MyApp.Replication.{ReplicationRecord, ReplicaStatus, RepairJob}

  @required_ack_count 2
  @max_lag_seconds 30

  def start_link(_opts) do
    Agent.start_link(
      fn -> %{records: %{}, region_health: %{}} end,
      name: __MODULE__
    )
  end

  def get_record(record_id) do
    Agent.get(__MODULE__, fn state -> Map.get(state.records, record_id) end)
  end

  def list_under_replicated do
    Agent.get(__MODULE__, fn state ->
      state.records
      |> Map.values()
      |> Enum.filter(fn r -> map_size(r.acked_by) < @required_ack_count end)
    end)
  end

  def replicate(record_id, payload, regions) do
    Agent.get_and_update(__MODULE__, fn state ->
      fan_out_results =
        Task.async_stream(regions, fn region ->
          case RegionClient.write(region, record_id, payload) do
            :ok -> {region, :sent}
            {:error, reason} -> {region, {:error, reason}}
          end
        end, timeout: 5_000)
        |> Enum.into(%{}, fn {:ok, {region, result}} -> {region, result} end)

      {sent, failed} =
        Enum.split_with(fan_out_results, fn {_r, result} -> result == :sent end)

      record = %ReplicationRecord{
        id: record_id,
        payload: payload,
        target_regions: regions,
        sent_to: Enum.map(sent, &elem(&1, 0)),
        acked_by: %{},
        failed_regions: Enum.map(failed, &elem(&1, 0)),
        replicated_at: DateTime.utc_now()
      }

      Enum.each(failed, fn {region, {:error, reason}} ->
        AlertService.notify(:replication_send_failed, %{record_id: record_id, region: region, reason: reason})
      end)

      AuditLog.record(:replication_initiated, %{record_id: record_id, regions: length(sent)})
      new_state = put_in(state, [:records, record_id], record)
      {{:ok, record}, new_state}
    end)
  end

  def confirm_replica(record_id, region, checksum) do
    Agent.get_and_update(__MODULE__, fn state ->
      case Map.fetch(state.records, record_id) do
        :error ->
          {{:error, :record_not_found}, state}

        {:ok, record} ->
          replica_status = %ReplicaStatus{
            region: region,
            checksum: checksum,
            acked_at: DateTime.utc_now()
          }

          expected_checksum = :crypto.hash(:sha256, :erlang.term_to_binary(record.payload)) |> Base.encode16()

          if checksum != expected_checksum do
            AlertService.notify(:replication_divergence, %{record_id: record_id, region: region})
            AuditLog.record(:replica_diverged, %{record_id: record_id, region: region})
            {{:error, :checksum_mismatch}, state}
          else
            updated_record = %{record | acked_by: Map.put(record.acked_by, region, replica_status)}
            ack_count = map_size(updated_record.acked_by)

            if ack_count >= @required_ack_count do
              AuditLog.record(:replication_complete, %{record_id: record_id, acks: ack_count})
            end

            new_state = put_in(state, [:records, record_id], updated_record)
            {{:ok, ack_count}, new_state}
          end
      end
    end)
  end

  def trigger_repair(record_id, target_region) do
    Agent.get_and_update(__MODULE__, fn state ->
      case Map.fetch(state.records, record_id) do
        :error ->
          {{:error, :record_not_found}, state}

        {:ok, record} ->
          case RepairScheduler.schedule(%RepairJob{
            record_id: record_id,
            target_region: target_region,
            payload: record.payload,
            scheduled_at: DateTime.utc_now()
          }) do
            {:ok, job_id} ->
              AuditLog.record(:repair_triggered, %{record_id: record_id, region: target_region})
              {{:ok, job_id}, state}

            {:error, reason} ->
              {{:error, reason}, state}
          end
      end
    end)
  end

  def check_lag do
    cutoff = DateTime.add(DateTime.utc_now(), -@max_lag_seconds, :second)

    Agent.get(__MODULE__, fn state ->
      state.records
      |> Map.values()
      |> Enum.filter(fn r ->
        map_size(r.acked_by) < @required_ack_count and
          DateTime.compare(r.replicated_at, cutoff) == :lt
      end)
      |> Enum.map(fn r ->
        lag = DateTime.diff(DateTime.utc_now(), r.replicated_at, :second)
        %{record_id: r.id, acks: map_size(r.acked_by), lag_seconds: lag}
      end)
    end)
  end

end
```
