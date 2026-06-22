```elixir
defmodule MyApp.Media.TranscriptionJob do
  @moduledoc """
  An Oban worker that submits audio files to a speech-to-text service,
  polls for completion, and persists the resulting transcript. The job
  uses Oban's `snooze` return value to re-schedule itself for polling
  rather than blocking a worker thread while awaiting transcription,
  keeping the job queue throughput high.
  """

  use Oban.Worker, queue: :transcription, max_attempts: 10

  require Logger

  alias MyApp.Repo
  alias MyApp.Media.{Recording, Transcript}
  alias MyApp.Integrations.SpeechClient

  @poll_delay_seconds 15
  @max_poll_attempts 40

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"recording_id" => recording_id} = args, attempt: attempt}) do
    case Repo.get(Recording, recording_id) do
      nil ->
        Logger.warning("transcription_job_recording_not_found", id: recording_id)
        :ok

      recording ->
        handle_recording(recording, args, attempt)
    end
  end

  @spec handle_recording(Recording.t(), map(), pos_integer()) ::
          :ok | {:snooze, pos_integer()} | {:error, term()}
  defp handle_recording(recording, args, attempt) do
    case Map.get(args, "provider_job_id") do
      nil ->
        submit_for_transcription(recording)

      provider_job_id ->
        poll_transcription(recording, provider_job_id, attempt)
    end
  end

  @spec submit_for_transcription(Recording.t()) ::
          {:snooze, pos_integer()} | {:error, term()}
  defp submit_for_transcription(recording) do
    case SpeechClient.submit(recording.storage_url, language: recording.language) do
      {:ok, provider_job_id} ->
        Logger.info("transcription_submitted", recording_id: recording.id, job: provider_job_id)
        {:snooze, @poll_delay_seconds}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec poll_transcription(Recording.t(), String.t(), pos_integer()) ::
          :ok | {:snooze, pos_integer()} | {:error, term()}
  defp poll_transcription(recording, provider_job_id, attempt) do
    if attempt > @max_poll_attempts do
      Logger.error("transcription_poll_timeout", recording_id: recording.id)
      {:error, :poll_timeout}
    else
      case SpeechClient.status(provider_job_id) do
        {:ok, :completed, text} ->
          persist_transcript(recording, text)

        {:ok, :processing} ->
          {:snooze, @poll_delay_seconds}

        {:ok, :failed} ->
          {:error, :provider_transcription_failed}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @spec persist_transcript(Recording.t(), String.t()) ::
          :ok | {:error, term()}
  defp persist_transcript(recording, text) do
    result =
      %Transcript{}
      |> Transcript.changeset(%{
        recording_id: recording.id,
        text: text,
        word_count: text |> String.split() |> length(),
        transcribed_at: DateTime.utc_now()
      })
      |> Repo.insert()

    case result do
      {:ok, _} ->
        Logger.info("transcription_persisted", recording_id: recording.id)
        :ok

      {:error, changeset} ->
        {:error, changeset}
    end
  end
end
```
