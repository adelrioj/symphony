"""Qualification-only probes. No credentials, response bodies or exception text leave this process."""
import base64
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

LIMIT = 1048576
AUDIENCE = "https://symphony.invalid/qualification"
SEGMENT = r"[A-Za-z0-9][A-Za-z0-9_-]{0,127}"
ACCOUNT = r"[a-z][a-z0-9-]{0,62}@[a-z][a-z0-9-]{0,62}\.iam\.gserviceaccount\.com"
CONFIG = rf"projects/{SEGMENT}/locations/{SEGMENT}/workstationClusters/{SEGMENT}/workstationConfigs/{SEGMENT}"
WORKSTATION = CONFIG + rf"/workstations/{SEGMENT}"
INSTANCE = rf"projects/{SEGMENT}/zones/{SEGMENT}/instances/{SEGMENT}"
SCOPE_KEYS = {"service_account", "allowed_secret_versions", "denied_secret_versions", "image_repository", "denied_image_repository", "denied_backup_object", "denied_workstation", "iam_review_reference"}
AR = ["artifactregistry.repositories.uploadArtifacts", "artifactregistry.repositories.deleteArtifacts", "artifactregistry.repositories.setIamPolicy"]
WS_CONFIG = ["workstations.workstations.create", "workstations.workstationConfigs.update", "workstations.workstationConfigs.delete", "workstations.workstationConfigs.setIamPolicy"]
WS_CLUSTER = ["workstations.workstationConfigs.create", "workstations.workstationClusters.update", "workstations.workstationClusters.delete"]
SECRET = ["secretmanager.secrets.setIamPolicy", "secretmanager.secrets.update", "secretmanager.secrets.delete", "secretmanager.versions.add", "secretmanager.versions.destroy"]
WS = ["workstations.workstations.update", "workstations.workstations.start", "workstations.workstations.stop", "workstations.workstations.delete", "workstations.workstations.use", "workstations.workstations.setIamPolicy"]
COMPUTE = ["compute.instances.update", "compute.instances.delete", "compute.instances.start", "compute.instances.stop", "compute.instances.setMetadata", "compute.instances.setTags", "compute.instances.setServiceAccount", "compute.instances.setIamPolicy"]
SA = ["iam.serviceAccounts.actAs", "iam.serviceAccounts.getAccessToken", "iam.serviceAccounts.getOpenIdToken", "iam.serviceAccounts.signBlob", "iam.serviceAccounts.signJwt", "iam.serviceAccounts.setIamPolicy", "iam.serviceAccountKeys.create"]
BACKUP = ["storage.objects.create", "storage.objects.delete", "storage.objects.update", "storage.buckets.setIamPolicy"]
PROJECT = ["compute.instances.create", "compute.disks.create", "compute.firewalls.create", "compute.firewalls.update", "resourcemanager.projects.setIamPolicy", "workstations.workstationClusters.create"] + WS_CLUSTER
FORBIDDEN = sorted(set(AR + WS_CONFIG + WS_CLUSTER + WS + SECRET + COMPUTE + SA + BACKUP + PROJECT))
# Fixed permissions of roles/artifactregistry.reader, allowed only on the approved repository.
# Unknown permissions, including future writes, must require a new reviewed source change.
ARTIFACT_READER = {
    f"artifactregistry.{resource}.{action}"
    for resource in ("attachments", "dockerimages", "files", "locations", "mavenartifacts",
                     "npmpackages", "packages", "pythonpackages", "repositories", "rules",
                     "tags", "versions")
    for action in ("get", "list")
} | {
    "artifactregistry.files.download", "artifactregistry.projectconfigs.get",
    "artifactregistry.projectsettings.get", "artifactregistry.repositories.downloadArtifacts",
    "artifactregistry.repositories.exportArtifacts", "artifactregistry.repositories.listEffectiveTags",
    "artifactregistry.repositories.listTagBindings", "artifactregistry.repositories.readViaVirtualRepository",
    "resourcemanager.projects.get",
}


def approved_permissions(scope, resource):
    if resource == scope["image_repository"]["name"]:
        return ARTIFACT_READER
    if resource in {value.rsplit("/versions/", 1)[0] for value in scope["allowed_secret_versions"]}:
        return {"secretmanager.versions.access", "resourcemanager.projects.get", "resourcemanager.projects.list"}
    return set()


def require(condition, code="permission_probe_inconclusive"):
    if not condition:
        raise RuntimeError(code)


def matches(pattern, value):
    return isinstance(value, str) and len(value) <= 4096 and re.fullmatch(pattern, value) is not None


def keys(value, expected):
    return isinstance(value, dict) and set(value) == set(expected)


def digest(value):
    return hashlib.sha256(value).hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def validate_scope(scope):
    require(keys(scope, SCOPE_KEYS), "invalid_permission_scope")
    require(matches(ACCOUNT, scope["service_account"]))
    for key in ("allowed_secret_versions", "denied_secret_versions"):
        values = scope[key]
        require(isinstance(values, list) and 1 <= len(values) <= 16)
        require(all(matches(rf"projects/{SEGMENT}/secrets/{SEGMENT}/versions/[1-9][0-9]*", v) for v in values))
        require(len(set(values)) == len(values))
    require(not set(scope["allowed_secret_versions"]) & set(scope["denied_secret_versions"]))
    for key in ("image_repository", "denied_image_repository"):
        repo = scope[key]
        require(keys(repo, ("name", "image")))
        require(matches(r"projects/([a-z][a-z0-9-]*)/locations/([a-z][a-z0-9-]*)/repositories/([a-z][a-z0-9_-]*)", repo["name"]))
        parts = repo["name"].split("/")
        prefix = re.escape(f"{parts[3]}-docker.pkg.dev/{parts[1]}/{parts[5]}/")
        require(matches(prefix + r"[a-z0-9]+(?:[._/-][a-z0-9]+)*@sha256:[0-9a-f]{64}", repo["image"]))
    require(scope["image_repository"]["name"] != scope["denied_image_repository"]["name"])
    backup = scope["denied_backup_object"]
    require(keys(backup, ("bucket", "object", "generation")))
    require(matches(r"[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]", backup["bucket"]))
    require(isinstance(backup["object"], str) and 1 <= len(backup["object"].encode()) <= 1024)
    require(matches(r"[1-9][0-9]{0,29}", backup["generation"]))
    require(matches(WORKSTATION, scope["denied_workstation"]))
    require(isinstance(scope["iam_review_reference"], str) and 0 < len(scope["iam_review_reference"]) <= 4096 and scope["iam_review_reference"].strip())


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, new_url):
        return None


class Transport:
    def __init__(self, seconds=25):
        self.deadline = time.monotonic() + seconds
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())

    def __call__(self, method, url, headers, body=None):
        remaining = self.deadline - time.monotonic()
        require(remaining > 0, "permission_probe_deadline")
        request = urllib.request.Request(url, data=body, headers=headers, method=method)
        try:
            with self.opener.open(request, timeout=min(3, remaining)) as response:
                data = response.read(LIMIT + 1)
                require(len(data) <= LIMIT, "permission_response_too_large")
                return response.status, data
        except urllib.error.HTTPError as error:
            # Classify bounded error data in memory; never serialize its body or messages.
            try:
                data = error.read(LIMIT + 1)
                require(len(data) <= LIMIT, "permission_response_too_large")
                return error.code, data
            finally:
                error.close()
        except (urllib.error.URLError, OSError, TimeoutError):
            raise RuntimeError("permission_transport_failed") from None


class Probe:
    def __init__(self, scope, transport=None):
        validate_scope(scope)
        self.scope = scope
        self.transport = transport or Transport()
        self.hosts = {"secretmanager.googleapis.com", "artifactregistry.googleapis.com", "storage.googleapis.com", "workstations.googleapis.com", "compute.googleapis.com", "iam.googleapis.com", "cloudresourcemanager.googleapis.com"}
        self.hosts.update(scope[k]["image"].split("/")[0] for k in ("image_repository", "denied_image_repository"))

    def request(self, url, token=None, method="GET", body=None, metadata=False):
        parsed = urllib.parse.urlsplit(url)
        require(not parsed.username and not parsed.password and not parsed.fragment and parsed.port is None)
        if metadata:
            require(parsed.scheme == "http" and parsed.hostname in ("metadata.google.internal", "169.254.169.254"))
            headers = {"Metadata-Flavor": "Google"}
        else:
            require(parsed.scheme == "https" and parsed.hostname in self.hosts)
            require(isinstance(token, str) and matches(r"[A-Za-z0-9._~+/-]{1,16384}=*", token))
            headers = {"Authorization": "Bearer " + token}
        headers["Accept"] = "application/json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json"
        if body is not None:
            body = canonical(body)
            headers["Content-Type"] = "application/json"
        status, data = self.transport(method, url, headers, body)
        require(type(status) is int and isinstance(data, bytes) and len(data) <= LIMIT)
        return status, data

    def json(self, url, token=None, **kwargs):
        status, data = self.request(url, token, **kwargs)
        require(status == 200)
        value = json.loads(data)
        require(isinstance(value, dict))
        return value

    def worker_token(self):
        root = "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/"
        status, email = self.request(root + "email", metadata=True)
        require(status == 200 and email.decode().strip() == self.scope["service_account"], "unexpected_worker_identity")
        credentials = self.json(root + "token", metadata=True)
        require(credentials.get("token_type") == "Bearer" and type(credentials.get("expires_in")) is int and credentials["expires_in"] > 0)
        token = credentials.get("access_token")
        require(matches(r"[A-Za-z0-9._~+/-]{1,16384}=*", token), "malformed_metadata_credentials")
        status, identity = self.request(root + "identity?" + urllib.parse.urlencode({"audience": AUDIENCE, "format": "full"}), metadata=True)
        require(status == 200)
        parts = identity.decode("ascii").split(".")
        require(len(parts) == 3 and all(parts), "malformed_metadata_credentials")
        claims = json.loads(base64.urlsafe_b64decode(parts[1] + "=" * (-len(parts[1]) % 4)))
        require(claims.get("email") == self.scope["service_account"] and claims.get("email_verified") is True and claims.get("aud") == AUDIENCE and type(claims.get("exp")) is int and claims["exp"] > time.time())
        # Metadata JWT claims are a guest consistency check, NOT cryptographic identity proof.
        # Controller-side config and VM reads are mandatory before executing this probe.
        return token

    def read_controls(self, token):
        controls = {}
        for kind in ("allowed_secret", "denied_secret"):
            for index, resource in enumerate(self.scope[kind + "_versions"]):
                url = "https://secretmanager.googleapis.com/v1/" + resource + ":access"
                controls[f"{kind}:{index}"] = (url, "secret", resource)
        for key, kind in (("image_repository", "allowed_image"), ("denied_image_repository", "denied_image")):
            image = self.scope[key]["image"]
            host, path = image.split("/", 1)
            name, sha = path.split("@")
            controls[kind] = (f"https://{host}/v2/{name}/manifests/{sha}", "manifest", sha)
        obj = self.scope["denied_backup_object"]
        url = "https://storage.googleapis.com/storage/v1/b/" + obj["bucket"] + "/o/" + urllib.parse.quote(obj["object"], safe="") + "?" + urllib.parse.urlencode({"alt": "media", "generation": obj["generation"]})
        controls["backup_denied"] = (url, "object", obj["generation"])
        return controls

    def readable(self, token, control):
        url, kind, identity = control
        status, body = self.request(url, token)
        require(status == 200)
        if kind == "secret":
            value = json.loads(body)
            require(value.get("name") == identity and isinstance(value.get("payload"), dict))
            body = base64.b64decode(value["payload"]["data"], validate=True)
            require(0 < len(body) <= 65536)
        elif kind == "manifest":
            value = json.loads(body)
            require(value.get("schemaVersion") == 2 and (isinstance(value.get("layers"), list) or isinstance(value.get("manifests"), list)))
            require("sha256:" + digest(body) == identity, "manifest_digest_mismatch")
        else:
            require(len(body) > 0)
        return digest(body)

    def worker(self, receipt):
        require(keys(receipt, ("controls", "queries", "resources", "review_sha256", "scope_sha256")))
        require(receipt["scope_sha256"] == digest(canonical(self.scope)))
        token = self.worker_token()
        deny_other_clouds(self.transport)
        controls = self.read_controls(token)
        require(set(receipt["controls"]) == set(controls))
        checks = {"identity": outcome(200), "other_clouds_denied": outcome(200)}
        # All permitted controls must succeed before a negative observation can count.
        for name, control in controls.items():
            if name.startswith("allowed_"):
                require(self.readable(token, control) == receipt["controls"][name], "positive_control_changed")
                checks[name] = outcome(200)
        for name, control in controls.items():
            if not name.startswith("allowed_"):
                status, body = self.request(control[0], token)
                require_denied(status, body, control[1], self.scope["denied_image_repository"]["name"])
                checks[name] = outcome(status)
        status, body = self.request("https://workstations.googleapis.com/v1/" + self.scope["denied_workstation"] + ":generateAccessToken", token, method="POST", body={"expireTime": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() + 60))})
        require_denied(status, body, "gateway", self.scope["denied_workstation"])
        checks["gateway_denied"] = outcome(status)
        for query in receipt["queries"]:
            self.permission_query(token, query)
        require(receipt["queries"], "permission_queries_missing")
        checks["iam_diagnostics"] = outcome(200)
        return {"complete": True, "identity": self.scope["service_account"], "checks": checks}

    def permission_query(self, token, query):
        # Only recipes generated and checked by the trusted preflight are accepted.
        require(keys(query, ("service", "resource", "permissions")))
        service, resource, permissions = query["service"], query["resource"], query["permissions"]
        expected, url, method = query_recipe(service, resource)
        require(permissions == expected)
        if service == "storage":
            url += "?" + urllib.parse.urlencode({"permissions": permissions}, doseq=True)
            result = self.json(url, token)
        else:
            result = self.json(url, token, method=method, body={"permissions": permissions})
        returned = result.get("permissions")
        require(isinstance(returned, list) and all(isinstance(p, str) and p in permissions for p in returned))
        require(len(set(returned)) == len(returned) and not returned, "forbidden_permission_granted")


def query_recipe(service, resource):
    recipes = {
        "artifact": (r"projects/[a-z][a-z0-9-]*/locations/[a-z][a-z0-9-]*/repositories/[a-z][a-z0-9_-]*", AR, "https://artifactregistry.googleapis.com/v1/", ":testIamPermissions"),
        "config": (CONFIG, WS_CONFIG, "https://workstations.googleapis.com/v1/", ":testIamPermissions"),
        "secret": (rf"projects/{SEGMENT}/secrets/{SEGMENT}", SECRET, "https://secretmanager.googleapis.com/v1/", ":testIamPermissions"),
        "workstation": (WORKSTATION, WS, "https://workstations.googleapis.com/v1/", ":testIamPermissions"),
        "compute": (INSTANCE, COMPUTE, "https://compute.googleapis.com/compute/v1/", "/testIamPermissions"),
        "account": (rf"projects/{SEGMENT}/serviceAccounts/{ACCOUNT}", SA, "https://iam.googleapis.com/v1/", ":testIamPermissions"),
        "project": (rf"projects/{SEGMENT}", PROJECT, "https://cloudresourcemanager.googleapis.com/v1/", ":testIamPermissions"),
        "storage": (r"[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]", BACKUP, "https://storage.googleapis.com/storage/v1/b/", "/iam/testPermissions"),
    }
    require(service in recipes)
    pattern, permissions, root, suffix = recipes[service]
    require(matches(pattern, resource))
    return permissions, root + resource + suffix, "GET" if service == "storage" else "POST"


def require_denied(status, body, kind, resource):
    require(status == 403 and isinstance(body, bytes) and len(body) <= LIMIT, "permission_denial_not_established")
    value = json.loads(body)
    require(isinstance(value, dict))
    if kind == "manifest":
        errors = value.get("errors")
        require(isinstance(errors, list) and errors)
        message = 'Permission "artifactregistry.repositories.downloadArtifacts" denied on resource "' + resource + '" (or it may not exist)'
        require(all(isinstance(error, dict) and error.get("code") == "DENIED" and
                    error.get("message") in (message, message + ".") for error in errors))
        return
    error = value.get("error")
    require(isinstance(error, dict) and type(error.get("code")) is int and error["code"] == 403)
    if kind == "object":
        errors = error.get("errors")
        require(isinstance(errors, list) and errors)
        require(all(isinstance(item, dict) and item.get("domain") == "global" and
                    item.get("reason") == "forbidden" for item in errors))
        return
    require(kind in ("secret", "gateway") and error.get("status") == "PERMISSION_DENIED")
    permission = "secretmanager.versions.access" if kind == "secret" else "workstations.workstations.use"
    details = error.get("details")
    require(isinstance(details, list))
    reasons = [item for item in details if isinstance(item, dict) and item.get("@type") == "type.googleapis.com/google.rpc.ErrorInfo"]
    require(reasons and all(item.get("reason") == "IAM_PERMISSION_DENIED" and
                           item.get("domain") == "googleapis.com" and
                           isinstance(item.get("metadata"), dict) and
                           item["metadata"].get("permission") == permission for item in reasons))


def outcome(status):
    return {"status": status, "ok": True}


def deny_other_clouds(transport):
    # Strict reachability semantics are preserved for non-GCP metadata. Any 2xx is ambiguous.
    endpoints = [
        ("PUT", "http://169.254.169.254/latest/api/token", {"X-aws-ec2-metadata-token-ttl-seconds": "60"}),
        ("GET", "http://169.254.169.254/latest/meta-data/iam/security-credentials/", {}),
        ("GET", "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fmanagement.azure.com%2F", {"Metadata": "true"}),
    ]
    for method, url, headers in endpoints:
        try:
            status, _ = transport(method, url, headers)
        except RuntimeError as error:
            if str(error) == "permission_transport_failed":
                continue
            raise
        require(status in (400, 401, 403, 404, 405), "unexpected_cloud_credentials")


def read_review(path):
    require(os.path.isabs(path), "private_iam_review_required")
    with open(path, "rb") as stream:
        info = os.fstat(stream.fileno())
        require(stat.S_ISREG(info.st_mode) and info.st_mode & 0o077 == 0 and info.st_size <= LIMIT, "private_iam_review_required")
        data = stream.read(LIMIT + 1)
    require(len(data) <= LIMIT)
    return json.loads(data), digest(data)


def verifier_token(worker, controller):
    configuration = os.environ.get("SYMPHONY_PERMISSION_VERIFIER_CONFIGURATION")
    account = os.environ.get("SYMPHONY_PERMISSION_VERIFIER_SERVICE_ACCOUNT")
    require(matches(r"[a-z][a-z0-9-]{0,62}", configuration) and matches(ACCOUNT, account), "independent_verifier_required")
    require(account not in (worker, controller), "independent_verifier_required")
    env = {k: v for k, v in os.environ.items() if "proxy" not in k.lower()}
    result = subprocess.run(["gcloud", "auth", "print-access-token", "--quiet", "--verbosity=error", "--configuration=" + configuration, "--impersonate-service-account=" + account], capture_output=True, timeout=15, env=env, check=False)
    require(result.returncode == 0 and len(result.stdout) <= 16384, "independent_verifier_unavailable")
    token = result.stdout.decode("ascii").strip()
    require(matches(r"[A-Za-z0-9._~+/-]{1,16384}=*", token))
    return account, token


def preflight(packet, transport=None, credentials=None, review_input=None):
    scope, config = packet["scope"], packet["config"]
    probe = Probe(scope, transport or Transport(55))
    require(matches(CONFIG, config["name"]) and matches(ACCOUNT, config["controller_service_account"]))
    require(scope["denied_workstation"].rsplit("/workstations/", 1)[0] != config["name"], "unrelated_workstation_required")
    review, review_sha = review_input if review_input is not None else read_review(scope["iam_review_reference"])
    account, token = credentials if credentials is not None else verifier_token(scope["service_account"], config["controller_service_account"])
    require(matches(ACCOUNT, account) and account not in (scope["service_account"], config["controller_service_account"]))
    require(review.get("worker_service_account") == scope["service_account"] and review.get("verifier_service_account") == account)
    require(review.get("scope_sha256") == digest(canonical(scope)))
    require(type(review.get("reviewed_at")) is int and type(review.get("expires_at")) is int and time.time() - 86400 <= review["reviewed_at"] <= time.time() < review["expires_at"] <= review["reviewed_at"] + 86400, "iam_review_stale")
    instances, accounts = review.get("compute_instances"), review.get("service_accounts")
    require(isinstance(instances, list) and 1 <= len(instances) <= 16 and all(matches(INSTANCE, v) for v in instances))
    require(isinstance(accounts, list) and 3 <= len(accounts) <= 16 and all(matches(rf"projects/{SEGMENT}/serviceAccounts/{ACCOUNT}", v) for v in accounts))
    require({scope["service_account"], config["controller_service_account"], account} <= {v.split("/")[-1] for v in accounts})
    resources = [("config", config["name"]), ("config", scope["denied_workstation"].rsplit("/workstations/", 1)[0]), ("workstation", scope["denied_workstation"])]
    resources += [("artifact", scope[k]["name"]) for k in ("image_repository", "denied_image_repository")]
    resources += [("compute", v) for v in instances] + [("account", v) for v in accounts]
    resources += [("storage", scope["denied_backup_object"]["bucket"])]
    resources += [("cluster", v) for v in sorted({config["name"].rsplit("/workstationConfigs/", 1)[0], scope["denied_workstation"].rsplit("/workstationConfigs/", 1)[0]})]
    resources += [("secret", v) for v in sorted({r.rsplit("/versions/", 1)[0] for r in scope["allowed_secret_versions"] + scope["denied_secret_versions"]})]
    projects = sorted({v.split("/")[1] for _, v in resources if v.startswith("projects/")})
    resources += [("project", "projects/" + v) for v in projects]
    require(len(set(resources)) == len(resources))
    observed, queries = {}, []
    for service, resource in resources:
        if service == "cluster":
            # Clusters have no IAM query method. Read their identity; review inherited
            # bindings and query project-scoped capabilities separately, never invent an API.
            require(matches(rf"projects/{SEGMENT}/locations/{SEGMENT}/workstationClusters/{SEGMENT}", resource))
            permissions = None
            url = "https://workstations.googleapis.com/v1/" + resource
        else:
            permissions, url, _ = query_recipe(service, resource)
            url = url.removesuffix(":testIamPermissions").removesuffix("/testIamPermissions").removesuffix("/iam/testPermissions")
        body = probe.json(url, token)
        if service == "config" and resource == config["name"]:
            require(body.get("uid") == config["uid"] and body.get("container", {}).get("image") == scope["image_repository"]["image"])
            require(body.get("host", {}).get("gceInstance", {}).get("serviceAccount") == scope["service_account"], "unexpected_config_identity")
        if service in ("config", "cluster", "workstation", "artifact", "account", "secret"):
            require(body.get("name") == resource)
        if service in ("config", "cluster", "workstation"):
            require(isinstance(body.get("uid"), str) and body["uid"])
        if service == "compute":
            require(body.get("name") == resource.split("/")[-1] and body.get("id"))
        if service == "storage":
            require(body.get("name") == resource and body.get("id"))
        if service == "project":
            require(body.get("projectId") == resource.split("/")[-1] and body.get("projectNumber"))
        observed[resource] = digest(canonical(body))
        if permissions is not None:
            queries.append({"service": service, "resource": resource, "permissions": permissions})
    # This private independent review must bind the current resources and all effective,
    # inherited and conditional grants. Query APIs alone can fail open and prove no boundary.
    require(review.get("resource_fingerprints") == observed, "iam_review_resource_changed")
    require(review.get("forbidden_permissions") == FORBIDDEN, "iam_review_capabilities_incomplete")
    bindings = review.get("effective_bindings")
    require(isinstance(bindings, dict) and set(bindings) == set(observed))
    for resource, evidence in bindings.items():
        require(keys(evidence, ("ancestry", "bindings", "effective_permissions")))
        require(isinstance(evidence["ancestry"], list) and evidence["ancestry"] and all(isinstance(v, str) and v for v in evidence["ancestry"]))
        require(isinstance(evidence["bindings"], list) and all(isinstance(v, dict) and isinstance(v.get("role"), str) and isinstance(v.get("members"), list) for v in evidence["bindings"]))
        require(isinstance(evidence["effective_permissions"], list) and all(isinstance(v, str) for v in evidence["effective_permissions"]))
        require(set(evidence["effective_permissions"]) <= approved_permissions(scope, resource), "iam_review_unapproved_grant")
    controls = {name: probe.readable(token, control) for name, control in probe.read_controls(token).items()}
    return {"controls": controls, "queries": queries, "resources": observed, "review_sha256": review_sha, "scope_sha256": digest(canonical(scope))}


def main():
    try:
        require(len(sys.argv) == 2 and len(sys.argv[1]) <= LIMIT * 2)
        packet = json.loads(base64.b64decode(sys.argv[1], validate=True))
        if packet["action"] == "preflight":
            result = preflight(packet)
        else:
            require(packet["action"] == "worker")
            result = Probe(packet["scope"]).worker(packet["receipt"])
        output = canonical(result)
        require(len(output) <= LIMIT)
        print(output.decode())
    except Exception:
        # Never print exception text: JSON/HTTP/subprocess exceptions can embed secrets.
        print('{"error":"permission_probe_inconclusive"}')
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
