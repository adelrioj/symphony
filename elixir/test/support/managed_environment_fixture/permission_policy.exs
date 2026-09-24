defmodule SymphonyElixir.ManagedEnvironmentFixture.PermissionPolicy do
  @moduledoc false
  @scope_keys ~w(service_account allowed_secret_versions denied_secret_versions image_repository denied_image_repository denied_backup_object denied_workstation iam_review_reference)
  @contexts ~w(ordinary root docker privileged_docker)
  @segment "[a-zA-Z0-9][a-zA-Z0-9_-]{0,127}"
  @secret Regex.compile!("\\Aprojects/#{@segment}/secrets/#{@segment}/versions/[1-9][0-9]*\\z")
  @workstation Regex.compile!(
                 "\\Aprojects/#{@segment}/locations/#{@segment}/workstationClusters/#{@segment}/workstationConfigs/#{@segment}/workstations/#{@segment}\\z"
               )

  def validate(kind, profile) when is_map(profile) do
    case Map.get(profile, "metadata_policy", "deny_all") do
      "deny_all" -> {:ok, %{mode: "deny_all"}}
      "scoped_gcp" when kind != "google_workstations" -> {:error, :scoped_gcp_requires_workstations}
      "scoped_gcp" -> scoped(profile["permission_scope"])
      _ -> {:error, :invalid_metadata_policy}
    end
  end

  def validate(_, _), do: {:error, :invalid_metadata_policy}

  defp scoped(nil), do: {:error, :permission_scope_required}

  defp scoped(scope) do
    if exact_keys?(scope, @scope_keys) and
         matches?(
           scope["service_account"],
           ~r/\A[a-z][a-z0-9-]{0,62}@[a-z][a-z0-9-]{0,62}\.iam\.gserviceaccount\.com\z/
         ) and
         secret_access_scope?(scope) and image_access_scope?(scope) and
         backup?(scope["denied_backup_object"]) and matches?(scope["denied_workstation"], @workstation) and
         review_reference?(scope["iam_review_reference"]) do
      {:ok, %{mode: "scoped_gcp", scope: scope}}
    else
      {:error, :invalid_permission_scope}
    end
  end

  defp secret_access_scope?(scope) do
    versions?(scope["allowed_secret_versions"]) and versions?(scope["denied_secret_versions"]) and
      MapSet.disjoint?(MapSet.new(scope["allowed_secret_versions"]), MapSet.new(scope["denied_secret_versions"]))
  end

  defp image_access_scope?(scope) do
    repository?(scope["image_repository"]) and repository?(scope["denied_image_repository"]) and
      scope["image_repository"]["name"] != scope["denied_image_repository"]["name"]
  end

  defp review_reference?(reference),
    do: is_binary(reference) and byte_size(reference) in 1..4096 and String.trim(reference) != ""

  defp versions?(values),
    do:
      is_list(values) and length(values) in 1..16 and Enum.uniq(values) == values and
        Enum.all?(values, &matches?(&1, @secret))

  defp repository?(value) do
    if exact_keys?(value, ~w(name image)) and is_binary(value["name"]) do
      case Regex.run(
             ~r/\Aprojects\/([a-z][a-z0-9-]*)\/locations\/([a-z][a-z0-9-]*)\/repositories\/([a-z][a-z0-9_-]*)\z/,
             value["name"]
           ) do
        [_, project, location, repository] ->
          prefix = Regex.escape("#{location}-docker.pkg.dev/#{project}/#{repository}/")
          matches?(value["image"], Regex.compile!("\\A#{prefix}[a-z0-9]+(?:[._/-][a-z0-9]+)*@sha256:[0-9a-f]{64}\\z"))

        _ ->
          false
      end
    else
      false
    end
  end

  defp backup?(value) do
    exact_keys?(value, ~w(bucket object generation)) and
      matches?(value["bucket"], ~r/\A[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]\z/) and
      is_binary(value["object"]) and byte_size(value["object"]) in 1..1024 and String.valid?(value["object"]) and
      matches?(value["generation"], ~r/\A[1-9][0-9]{0,29}\z/)
  end

  def checks(%{mode: "scoped_gcp", scope: scope}) do
    [
      {"identity", 200},
      {"allowed_image", 200},
      {"denied_image", 403},
      {"backup_denied", 403},
      {"gateway_denied", 403},
      {"iam_diagnostics", 200},
      {"other_clouds_denied", 200}
    ] ++
      indexed(scope["allowed_secret_versions"], "allowed_secret", 200) ++
      indexed(scope["denied_secret_versions"], "denied_secret", 403)
  end

  def checks(%{mode: "deny_all"}), do: [{"metadata_denied", 200}]

  defp indexed(values, prefix, status),
    do: values |> Enum.with_index() |> Enum.map(fn {_, index} -> {"#{prefix}:#{index}", status} end)

  def evaluate(%{mode: "scoped_gcp", scope: scope} = policy, observations) do
    valid =
      exact_keys?(observations, @contexts) and
        Enum.all?(@contexts, fn context ->
          value = observations[context]

          exact_keys?(value, ~w(complete identity checks)) and value["complete"] == true and
            value["identity"] == scope["service_account"] and valid_checks?(value["checks"], checks(policy))
        end)

    if valid, do: :ok, else: {:error, :permission_evidence_incomplete}
  end

  def evaluate(%{mode: "deny_all"} = policy, observations) do
    if exact_keys?(observations, ~w(complete checks)) and observations["complete"] == true and
         valid_checks?(observations["checks"], checks(policy)),
       do: :ok,
       else: {:error, :permission_evidence_incomplete}
  end

  def evaluate(_, _), do: {:error, :permission_evidence_incomplete}

  defp valid_checks?(observed, expected) do
    exact_keys?(observed, Enum.map(expected, &elem(&1, 0))) and
      Enum.all?(expected, fn {id, status} ->
        exact_keys?(observed[id], ~w(status ok)) and observed[id]["status"] == status and observed[id]["ok"] == true
      end)
  end

  defp exact_keys?(value, keys), do: is_map(value) and Enum.sort(Map.keys(value)) == Enum.sort(keys)
  defp matches?(value, pattern), do: is_binary(value) and byte_size(value) <= 2048 and Regex.match?(pattern, value)
end
