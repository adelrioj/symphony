defmodule SymphonyElixirWeb.ObservabilityPubSub do
  @moduledoc """
  PubSub helpers for observability dashboard updates.
  """

  @pubsub SymphonyElixir.PubSub
  @topic "observability:dashboard"
  @profiles_topic "observability:execution-profiles"
  @update_message :observability_updated

  @spec subscribe() :: :ok | {:error, term()}
  def subscribe do
    Phoenix.PubSub.subscribe(@pubsub, @topic)
  end

  @spec broadcast_update() :: :ok
  def broadcast_update, do: safe_broadcast(@topic, @update_message)

  @spec subscribe_profiles() :: :ok | {:error, term()}
  def subscribe_profiles, do: Phoenix.PubSub.subscribe(@pubsub, @profiles_topic)

  @spec broadcast_profiles() :: :ok
  def broadcast_profiles, do: safe_broadcast(@profiles_topic, :profiles_updated)

  @spec subscribe_lane(String.t()) :: :ok | {:error, term()}
  def subscribe_lane(slug) when is_binary(slug), do: Phoenix.PubSub.subscribe(@pubsub, "lane:" <> slug)

  @spec broadcast_lane(String.t()) :: :ok
  def broadcast_lane(slug) when is_binary(slug), do: safe_broadcast("lane:" <> slug, {:lane_updated, slug})

  @spec subscribe_run(String.t()) :: :ok | {:error, term()}
  def subscribe_run(attempt_id) when is_binary(attempt_id), do: Phoenix.PubSub.subscribe(@pubsub, "run:" <> attempt_id)

  @spec broadcast_run(String.t(), term()) :: :ok
  def broadcast_run(attempt_id, message) when is_binary(attempt_id), do: safe_broadcast("run:" <> attempt_id, message)

  defp safe_broadcast(topic, message) do
    if Process.whereis(@pubsub), do: Phoenix.PubSub.broadcast(@pubsub, topic, message), else: :ok
  end
end
