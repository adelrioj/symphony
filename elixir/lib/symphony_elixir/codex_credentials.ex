defmodule SymphonyElixir.CodexCredentials do
  @moduledoc "Coordinates the single Codex credential owner against current cloud authority, never restored local ownership."

  alias SymphonyElixir.CodexCredentials.{ControlStore, GoogleClient, Record}
  alias SymphonyElixir.GoogleCredentials

  @type result :: {:ok, ControlStore.snapshot()} | {:error, Record.error()}

  @spec read(map(), keyword()) :: result()
  def read(config, opts \\ []), do: ControlStore.read(config, opts)

  @doc "Claims AVAILABLE authority with a globally unique, initially UID-unbound ownership identity."
  @spec claim(map(), map(), keyword()) :: result()
  def claim(config, owner, opts \\ []) do
    opts = GoogleCredentials.options(opts)

    with {:ok, snapshot} <- read(config, opts),
         {:ok, next} <- Record.transition(snapshot.record, {:claim, unique_id(), owner}, unique_id()) do
      ControlStore.replace(config, snapshot, next, opts)
    end
  end

  @doc "Applies one matching active or last-handoff claim event and returns only committed authority."
  @spec transition(map(), String.t(), Record.event(), keyword()) :: result()
  def transition(config, claim_id, event, opts \\ []) do
    opts = GoogleCredentials.options(opts)

    with {:ok, snapshot} <- read(config, opts),
         :ok <- matching_claim(snapshot.record, claim_id),
         :ok <- ordinary_event(event),
         {:ok, next} <- Record.transition(snapshot.record, event, unique_id()),
         :ok <- verify_version(config, event, opts) do
      ControlStore.replace(config, snapshot, next, opts)
    end
  end

  defp matching_claim(record, claim_id) do
    current_claim =
      if record["state"] == "AVAILABLE", do: get_in(record, ["last_handoff", "claim_id"]), else: record["claim_id"]

    if is_binary(claim_id) and claim_id == current_claim,
      do: :ok,
      else: {:error, {:credential_recovery_required, :claim_mismatch}}
  end

  defp ordinary_event({:claim, _claim_id, _owner}), do: {:error, {:credential_recovery_required, :invalid_transition}}
  defp ordinary_event(_event), do: :ok

  defp verify_version(config, {:checkpoint, receipt}, opts) do
    case GoogleClient.version_metadata(config, receipt["secret_version"], opts) do
      {:ok, _metadata} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp verify_version(_config, _event, _opts), do: :ok
  defp unique_id, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
end
