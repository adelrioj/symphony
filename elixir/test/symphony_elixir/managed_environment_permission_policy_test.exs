Code.require_file("../support/managed_environment_fixture/permission_policy.exs", __DIR__)

defmodule SymphonyElixir.ManagedEnvironmentPermissionPolicyTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.ManagedEnvironmentFixture.PermissionPolicy

  test "unknown policy never falls back to success" do
    assert {:error, :invalid_metadata_policy} = PermissionPolicy.validate("google_workstations", %{"metadata_policy" => "allow_any"})
    assert {:error, :invalid_metadata_policy} = PermissionPolicy.validate("google_workstations", %{"metadata_policy" => nil})
    assert {:ok, %{mode: "deny_all"}} = PermissionPolicy.validate("google_workstations", %{})
    assert {:ok, %{mode: "deny_all"}} = PermissionPolicy.validate("kubernetes", %{"metadata_policy" => "deny_all"})
  end

  test "scoped policy requires controls and Workstations" do
    assert {:error, :permission_scope_required} = PermissionPolicy.validate("google_workstations", %{"metadata_policy" => "scoped_gcp"})
    assert {:error, :scoped_gcp_requires_workstations} = PermissionPolicy.validate("kubernetes", profile())
    assert {:ok, _} = PermissionPolicy.validate("google_workstations", profile())
    for key <- Map.keys(profile()["permission_scope"]) do
      invalid = update_in(profile(), ["permission_scope"], &Map.delete(&1, key))
      assert {:error, :invalid_permission_scope} = PermissionPolicy.validate("google_workstations", invalid)
    end
  end

  test "rejects executable fields, overlapping controls, mutable versions and inconsistent registry hosts" do
    for invalid <- [
      put_in(profile(), ["permission_scope", "url"], "https://evil.invalid"),
      put_in(profile(), ["permission_scope", "allowed_secret_versions"], ["projects/qual/secrets/allowed/versions/latest"]),
      put_in(profile(), ["permission_scope", "denied_secret_versions"], profile()["permission_scope"]["allowed_secret_versions"]),
      put_in(profile(), ["permission_scope", "image_repository", "image"], "evil.invalid/qual/images/worker@sha256:" <> String.duplicate("a", 64)),
      put_in(profile(), ["permission_scope", "image_repository", "executable"], "/tmp/probe"),
      put_in(profile(), ["permission_scope", "denied_backup_object", "generation"], "latest")
    ] do
      assert {:error, :invalid_permission_scope} = PermissionPolicy.validate("google_workstations", invalid)
    end
  end

  test "every execution context and every check must complete" do
    {:ok, policy} = PermissionPolicy.validate("google_workstations", profile())
    observations = observations(policy)
    assert :ok = PermissionPolicy.evaluate(policy, observations)
    for context <- ~w(ordinary root docker privileged_docker) do
      assert {:error, :permission_evidence_incomplete} = PermissionPolicy.evaluate(policy, Map.delete(observations, context))
      assert {:error, :permission_evidence_incomplete} = PermissionPolicy.evaluate(policy, put_in(observations, [context, "complete"], false))
      assert {:error, :permission_evidence_incomplete} = PermissionPolicy.evaluate(policy, update_in(observations, [context, "checks"], &Map.delete(&1, "gateway_denied")))
    end
  end

  test "forbidden success, authentication failures, missing resources and transport failures never establish denial" do
    {:ok, policy} = PermissionPolicy.validate("google_workstations", profile())
    for status <- [200, 401, 404, "timeout", nil] do
      value = put_in(observations(policy), ["ordinary", "checks", "gateway_denied", "status"], status)
      assert {:error, :permission_evidence_incomplete} = PermissionPolicy.evaluate(policy, value)
    end
    value = put_in(observations(policy), ["ordinary", "checks", "allowed_secret:0", "status"], 403)
    assert {:error, :permission_evidence_incomplete} = PermissionPolicy.evaluate(policy, value)
  end

  test "unverified identity or credential-bearing evidence cannot be accepted" do
    {:ok, policy} = PermissionPolicy.validate("google_workstations", profile())
    for value <- [
      put_in(observations(policy), ["root", "identity"], "other@qual.iam.gserviceaccount.com"),
      put_in(observations(policy), ["root", "token"], "SYNTHETIC_TOKEN_SENTINEL"),
      put_in(observations(policy), ["root", "checks", "gateway_denied", "body"], "SYNTHETIC_TOKEN_SENTINEL")
    ] do
      result = PermissionPolicy.evaluate(policy, value)
      assert {:error, :permission_evidence_incomplete} = result
      refute inspect(result) =~ "SYNTHETIC_TOKEN_SENTINEL"
    end
  end

  test "real Python probe rejects false denials, malformed credentials and permission-query failures without networking" do
    script = ~S"""
    import base64, copy, importlib.util, json, sys, time
    spec = importlib.util.spec_from_file_location("probe", sys.argv[1])
    p = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(p)
    scope = json.loads(base64.b64decode(sys.argv[2]))
    manifest = b'{"schemaVersion":2,"layers":[]}'
    for key in ("image_repository", "denied_image_repository"):
        scope[key]["image"] = scope[key]["image"].split("@")[0] + "@sha256:" + p.digest(manifest)
    sentinel = "SYNTHETIC_TOKEN_SENTINEL"
    secret = b"harmless-qualification-value"
    receipt = {"controls": {"allowed_secret:0":p.digest(secret), "denied_secret:0":p.digest(secret),
               "allowed_image":p.digest(manifest), "denied_image":p.digest(manifest), "backup_denied":p.digest(b"control")},
               "scope_sha256":p.digest(p.canonical(scope)), "review_sha256":"a"*64, "resources":{},
               "queries":[{"service":"artifact","resource":scope["image_repository"]["name"],"permissions":p.AR}]}
    mode = None
    requests = []
    def transport(method, url, headers, body=None):
        requests.append((method, url))
        if "169.254.169.254" in url:
            return 404, b""
        if url.endswith("/email"):
            return 200, scope["service_account"].encode()
        if url.endswith("/token"):
            if mode == "malformed_token":
                return 200, b'{"access_token": null, "token_type":"Bearer","expires_in":3600}'
            return 200, p.canonical({"access_token":sentinel,"token_type":"Bearer","expires_in":3600})
        if "/identity?" in url:
            claims={"email":scope["service_account"],"email_verified":True,"aud":p.AUDIENCE,"exp":int(time.time())+3600}
            if mode == "wrong_identity":
                claims["email"]="other@qual.iam.gserviceaccount.com"
            return 200, b"header."+base64.urlsafe_b64encode(p.canonical(claims)).rstrip(b"=")+b".signature"
        assert headers["Authorization"] == "Bearer " + sentinel
        if url.endswith(":testIamPermissions"):
            assert method == "POST" and json.loads(body) == {"permissions":p.AR}
            if mode == "query_error": return 403, b""
            if mode == "query_missing": return 200, b"{}"
            if mode == "query_granted": return 200, p.canonical({"permissions":[p.AR[0]]})
            if mode == "query_unrequested": return 200, b'{"permissions":["invented.permission"]}'
            return 200, b'{"permissions":[]}'
        if "/secrets/allowed/" in url:
            if mode == "positive_failed": return 403, b""
            return 200, p.canonical({"name":scope["allowed_secret_versions"][0],"payload":{"data":base64.b64encode(secret).decode()}})
        if "/images/worker/" in url:
            return 200, manifest
        if mode in (200, 401, 404, 302):
            return mode, sentinel.encode()
        if mode == "timeout":
            raise RuntimeError("permission_transport_failed")
        if mode == "malformed_denial": return 403, sentinel.encode()
        if mode == "billing_denial":
            return 403, p.canonical({"error":{"code":403,"errors":[{"domain":"global","reason":"accountDisabled"}]}})
        if "/manifests/" in url:
            if mode == "malformed_manifest": return 403, p.canonical({"errors":[{"code":"DENIED","message":"billing disabled " + sentinel}]})
            message = 'Permission "artifactregistry.repositories.downloadArtifacts" denied on resource "' + scope["denied_image_repository"]["name"] + '" (or it may not exist)'
            return 403, p.canonical({"errors":[{"code":"DENIED","message":message}]})
        if "storage.googleapis.com" in url:
            if mode == "billing_object": return 403, p.canonical({"error":{"code":403,"errors":[{"domain":"global","reason":"UserProjectAccountProblem"}]}})
            return 403, p.canonical({"error":{"code":403,"errors":[{"domain":"global","reason":"forbidden"}]}})
        permission = "workstations.workstations.use" if url.endswith(":generateAccessToken") else "secretmanager.versions.access"
        if mode == "unknown_gateway" and url.endswith(":generateAccessToken"):
            return 403, p.canonical({"error":{"code":403,"status":"PERMISSION_DENIED"}})
        if mode == "wrong_permission": permission = "unrelated.permission"
        return 403, p.canonical({"error":{"code":403,"status":"PERMISSION_DENIED","details":[
            {"@type":"type.googleapis.com/google.rpc.ErrorInfo","domain":"googleapis.com","reason":"IAM_PERMISSION_DENIED","metadata":{"permission":permission}}]}})
    probe = p.Probe(scope, transport)
    evidence = probe.worker(receipt)
    assert evidence["complete"] and sentinel not in json.dumps(evidence)
    assert any(url.endswith(":generateAccessToken") for _,url in requests)
    assert any("/o/harmless%2Fcontrol.txt?alt=media&generation=123" in url for _,url in requests)
    for mode in (200, 401, 404, 302, "timeout", "malformed_token", "wrong_identity", "positive_failed", "query_error", "query_missing", "query_granted", "query_unrequested", "malformed_denial", "billing_denial", "malformed_manifest", "billing_object", "unknown_gateway", "wrong_permission"):
        try: probe.worker(receipt)
        except (RuntimeError, ValueError): pass
        else: raise AssertionError("false pass: " + str(mode))
    for status in (200, 401, 404, None):
        try: p.require_denied(status, b"{}", "secret", "")
        except RuntimeError: pass
        else: raise AssertionError("false denial")
    for url in ("https://evil.invalid/token", "https://storage.googleapis.com.evil.invalid", "https://storage.googleapis.com:444", "https://user@storage.googleapis.com"):
        try: probe.request(url, sentinel)
        except RuntimeError: pass
        else: raise AssertionError("arbitrary destination accepted")
    opener=p.Transport().opener
    assert not any(isinstance(h,p.urllib.request.ProxyHandler) and h.proxies for h in opener.handlers)
    assert p.NoRedirect().redirect_request(None,None,302,None,None,"https://evil.invalid") is None
    print("worker-permission-smoke-ok")
    """
    assert {output, 0} = python(script, profile()["permission_scope"])
    assert String.trim(output) == "worker-permission-smoke-ok"
  end

  test "independent preflight blocks missing controls and stale or incomplete IAM review before workers exist" do
    script = ~S"""
    import base64, copy, importlib.util, json, sys, time
    spec=importlib.util.spec_from_file_location("probe",sys.argv[1])
    p=importlib.util.module_from_spec(spec); spec.loader.exec_module(p)
    scope=json.loads(base64.b64decode(sys.argv[2]))
    manifest=b'{"schemaVersion":2,"layers":[]}'
    for k in ("image_repository","denied_image_repository"):
        scope[k]["image"]=scope[k]["image"].split("@")[0]+"@sha256:"+p.digest(manifest)
    config=scope["denied_workstation"].rsplit("/workstationConfigs/",1)[0]+"/workstationConfigs/worker"
    controller="controller@qual.iam.gserviceaccount.com"
    verifier="verifier@qual.iam.gserviceaccount.com"
    instance="projects/qual/zones/europe-west1-b/instances/control"
    accounts=["projects/qual/serviceAccounts/"+v for v in (scope["service_account"],controller,verifier)]
    named=[("config",config),("config",scope["denied_workstation"].rsplit("/workstations/",1)[0]),("workstation",scope["denied_workstation"])]
    named += [("artifact",scope[k]["name"]) for k in ("image_repository","denied_image_repository")]
    named += [("compute",instance)]+[("account",a) for a in accounts]+[("storage",scope["denied_backup_object"]["bucket"]),("project","projects/qual")]
    cluster=config.rsplit("/workstationConfigs/",1)[0]
    named += [("cluster",cluster)]
    named += [("secret",r.rsplit("/versions/",1)[0]) for r in scope["allowed_secret_versions"]+scope["denied_secret_versions"]]
    objects={}
    for service,resource in named:
        body={"name":resource,"uid":"uid-"+service,"id":"123"}
        if service=="config" and resource==config:
            body.update({"container":{"image":scope["image_repository"]["image"]},"host":{"gceInstance":{"serviceAccount":scope["service_account"]}}})
        if service=="compute": body["name"]="control"
        if service=="project": body.update({"projectId":"qual","projectNumber":"123"})
        objects[resource]=body
    review={"worker_service_account":scope["service_account"],"verifier_service_account":verifier,
            "scope_sha256":p.digest(p.canonical(scope)),"reviewed_at":int(time.time())-10,"expires_at":int(time.time())+600,
            "compute_instances":[instance],"service_accounts":accounts,"forbidden_permissions":p.FORBIDDEN,
            "resource_fingerprints":{r:p.digest(p.canonical(b)) for r,b in objects.items()},
            "effective_bindings":{r:{"ancestry":["organizations/123","projects/qual"],"bindings":[{"role":"roles/viewer","members":["serviceAccount:"+scope["service_account"]]}],"effective_permissions":[]} for r in objects}}
    review["effective_bindings"][scope["image_repository"]["name"]]["effective_permissions"]=["artifactregistry.repositories.downloadArtifacts","artifactregistry.repositories.get"]
    review["effective_bindings"][scope["allowed_secret_versions"][0].rsplit("/versions/",1)[0]]["effective_permissions"]=["secretmanager.versions.access"]
    packet={"scope":scope,"config":{"name":config,"uid":"uid-config","controller_service_account":controller}}
    mode=None
    seen=[]
    def transport(method,url,headers,body=None):
        assert headers["Authorization"]=="Bearer SYNTHETIC_VERIFIER_TOKEN"
        assert method=="GET"
        seen.append(url)
        if "/secrets/" in url and url.endswith(":access"):
            if mode in (401,403,404): return mode,b""
            resource=url.split("/v1/")[1].removesuffix(":access")
            return 200,p.canonical({"name":resource,"payload":{"data":"aGFybWxlc3M="}})
        if "/manifests/" in url: return 200,manifest
        if "?alt=media" in url: return 200,b"harmless"
        if "storage.googleapis.com" in url: resource=url.split("/b/")[1]
        elif "compute.googleapis.com" in url: resource=url.split("/compute/v1/")[1]
        else: resource=url.split("/v1/")[1]
        return 200,p.canonical(objects[resource])
    result=p.preflight(packet,transport,(verifier,"SYNTHETIC_VERIFIER_TOKEN"),(review,"a"*64))
    assert set(result["controls"])=={"allowed_secret:0","denied_secret:0","allowed_image","denied_image","backup_denied"}
    assert "SYNTHETIC" not in json.dumps(result) and "harmless" not in json.dumps(result["controls"])
    services={q["service"] for q in result["queries"]}
    assert {"artifact","config","workstation","compute","account","storage","project","secret"} <= services
    assert "cluster" not in services and cluster in result["resources"]
    for mode in (401,403,404):
        try: p.preflight(packet,transport,(verifier,"SYNTHETIC_VERIFIER_TOKEN"),(review,"a"*64))
        except RuntimeError: pass
        else: raise AssertionError("unreadable control passed")
    mode=None
    for key,value in (("expires_at",0),("forbidden_permissions",[]),("resource_fingerprints",{}),("effective_bindings",{})):
        bad=copy.deepcopy(review); bad[key]=value
        try: p.preflight(packet,transport,(verifier,"SYNTHETIC_VERIFIER_TOKEN"),(bad,"a"*64))
        except RuntimeError: pass
        else: raise AssertionError("invalid review passed")
    for permission in ("compute.instances.setTags", "compute.disks.resize", "iam.serviceAccounts.actAs", "secretmanager.versions.access", "unknown.future.write"):
        bad=copy.deepcopy(review)
        bad["effective_bindings"][instance]["effective_permissions"]=[permission]
        try: p.preflight(packet,transport,(verifier,"SYNTHETIC_VERIFIER_TOKEN"),(bad,"a"*64))
        except RuntimeError: pass
        else: raise AssertionError("unapproved effective grant passed: " + permission)
    for resource,permission in ((scope["denied_image_repository"]["name"],"artifactregistry.repositories.downloadArtifacts"),
                                (scope["denied_secret_versions"][0].rsplit("/versions/",1)[0],"secretmanager.versions.access")):
        bad=copy.deepcopy(review)
        bad["effective_bindings"][resource]["effective_permissions"]=[permission]
        try: p.preflight(packet,transport,(verifier,"SYNTHETIC_VERIFIER_TOKEN"),(bad,"a"*64))
        except RuntimeError: pass
        else: raise AssertionError("read grant outside approved resource passed")
    try: p.preflight(packet,transport,(controller,"SYNTHETIC_VERIFIER_TOKEN"),(review,"a"*64))
    except RuntimeError: pass
    else: raise AssertionError("controller used as verifier")
    print("independent-preflight-smoke-ok")
    """
    assert {output, 0} = python(script, profile()["permission_scope"])
    assert String.trim(output) == "independent-preflight-smoke-ok"
  end

  defp python(script, scope) do
    path = Path.expand("../support/managed_environment_fixture/gcp_permission_probe.py", __DIR__)
    System.cmd("python3", ["-B", "-c", script, path, Base.encode64(Jason.encode!(scope))], stderr_to_stdout: true)
  end

  defp profile do
    %{"metadata_policy" => "scoped_gcp", "permission_scope" => %{
      "service_account" => "worker@qual.iam.gserviceaccount.com",
      "allowed_secret_versions" => ["projects/qual/secrets/allowed/versions/1"],
      "denied_secret_versions" => ["projects/qual/secrets/denied/versions/2"],
      "image_repository" => %{"name" => "projects/qual/locations/europe-west1/repositories/images", "image" => "europe-west1-docker.pkg.dev/qual/images/worker@sha256:" <> String.duplicate("a", 64)},
      "denied_image_repository" => %{"name" => "projects/qual/locations/europe-west1/repositories/control", "image" => "europe-west1-docker.pkg.dev/qual/control/control@sha256:" <> String.duplicate("b", 64)},
      "denied_backup_object" => %{"bucket" => "qual-control", "object" => "harmless/control.txt", "generation" => "123"},
      "denied_workstation" => "projects/qual/locations/europe-west1/workstationClusters/cluster/workstationConfigs/control/workstations/control",
      "iam_review_reference" => "/private/qualification/iam-review.json"
    }}
  end

  defp observations(policy) do
    checks = Map.new(PermissionPolicy.checks(policy), fn {id, status} -> {id, %{"status" => status, "ok" => true}} end)
    Map.new(~w(ordinary root docker privileged_docker), &{&1, %{"complete" => true, "identity" => policy.scope["service_account"], "checks" => checks}})
  end
end
