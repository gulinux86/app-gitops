#!/usr/bin/env python3
"""Checks the rendered applications for what this repository's rules forbid and what
the cluster would otherwise reject after the merge.

Reads the files scripts/ci/render.sh wrote. Every check reports all its findings
before failing, so one run lists everything a pull request has to fix.

  - no Secret (the repository is public), no Ingress and no Service of type
    LoadBalancer (a controller-created load balancer never enters Terraform state);
  - every container image pinned by digest — the chart's schema checks its own image,
    this also covers plain manifests;
  - no two HTTPRoutes claiming the same path on the same gateway: the gateway would
    pick one and the other application would go dark without an error anywhere;
  - with --registry: every image exists in its registry, and runs as a numeric
    non-root user unless the pod sets runAsUser. `runAsNonRoot` cannot verify a user
    given by name, so such a pod never starts (CreateContainerConfigError).

Usage: scripts/ci/check.py <rendered dir> [--registry]
"""

import argparse
import json
import pathlib
import re
import subprocess
import sys

import yaml

DIGEST = re.compile(r"@sha256:[a-f0-9]{64}$")
NUMERIC_NON_ROOT = re.compile(r"^[1-9][0-9]*(:[0-9]+)?$")
WORKLOADS = {"Deployment", "StatefulSet", "DaemonSet", "ReplicaSet", "Job"}
# The nodes Karpenter launches; the user an image declares can differ by platform.
PLATFORM = "linux/amd64"


def documents(rendered):
    for path in sorted(pathlib.Path(rendered).glob("*.yaml")):
        for doc in yaml.safe_load_all(path.read_text()):
            if isinstance(doc, dict) and doc.get("kind"):
                yield path.stem, doc


def pod_spec(doc):
    kind, spec = doc["kind"], doc.get("spec") or {}
    if kind == "Pod":
        return spec
    if kind == "CronJob":
        spec = (spec.get("jobTemplate") or {}).get("spec") or {}
        return (spec.get("template") or {}).get("spec")
    if kind in WORKLOADS:
        return (spec.get("template") or {}).get("spec")
    return None


def containers(doc):
    """(container, effective runAsUser) for every container of a workload."""
    pod = pod_spec(doc)
    if not pod:
        return
    pod_user = (pod.get("securityContext") or {}).get("runAsUser")
    for container in (pod.get("initContainers") or []) + (pod.get("containers") or []):
        user = (container.get("securityContext") or {}).get("runAsUser", pod_user)
        yield container, user


def name_of(release, doc):
    return f"{release}: {doc['kind']}/{doc.get('metadata', {}).get('name', '?')}"


def check_forbidden(docs, errors):
    for release, doc in docs:
        kind = doc["kind"]
        if kind == "Secret":
            errors.append(f"{name_of(release, doc)} — no Secret in a public repository")
        elif kind == "Ingress":
            errors.append(f"{name_of(release, doc)} — use an HTTPRoute on the platform gateway")
        elif kind == "Service" and (doc.get("spec") or {}).get("type") == "LoadBalancer":
            errors.append(f"{name_of(release, doc)} — no LoadBalancer Service; route through the gateway")


def check_digests(docs, errors):
    for release, doc in docs:
        for container, _ in containers(doc):
            image = container.get("image", "")
            if not DIGEST.search(image):
                errors.append(f"{name_of(release, doc)} — image {image!r} is not pinned by digest")


def check_routes(docs, errors):
    claimed = {}
    for release, doc in docs:
        if doc["kind"] != "HTTPRoute":
            continue
        spec = doc.get("spec") or {}
        namespace = doc.get("metadata", {}).get("namespace", "")
        parents = [(p.get("namespace", namespace), p.get("name")) for p in spec.get("parentRefs") or []]
        hosts = spec.get("hostnames") or ["*"]
        for rule in spec.get("rules") or []:
            for match in rule.get("matches") or []:
                path = (match.get("path") or {}).get("value", "/")
                for parent in parents:
                    for host in hosts:
                        key = (parent, host, path)
                        owner = name_of(release, doc)
                        if key in claimed and claimed[key] != owner:
                            errors.append(
                                f"path {path} on gateway {parent[0]}/{parent[1]} is routed by both "
                                f"{claimed[key]} and {owner}"
                            )
                        claimed.setdefault(key, owner)


def crane(*args):
    return subprocess.run(["crane", *args], capture_output=True, text=True, check=False)


def check_registry(docs, errors):
    users = {}
    for release, doc in docs:
        for container, user in containers(doc):
            users.setdefault(container.get("image", ""), []).append((name_of(release, doc), user))
    for image, uses in sorted(users.items()):
        if not DIGEST.search(image):
            continue  # already reported
        print(f"  {image}")
        config = crane("config", "--platform", PLATFORM, image)
        if config.returncode != 0:
            errors.append(
                f"{uses[0][0]} — cannot read {image} from its registry: {config.stderr.strip()} "
                "(a wrong digest, or a private image CI has no credentials for — ECR images need the ECR_READ_ROLE_ARN secret)"
            )
            continue
        image_user = (json.loads(config.stdout).get("config") or {}).get("User", "")
        for owner, run_as in uses:
            if run_as not in (None, 0):
                continue
            if not NUMERIC_NON_ROOT.match(image_user):
                shown = image_user or "root (no USER)"
                errors.append(
                    f"{owner} — {image} runs as {shown!r}; runAsNonRoot needs a numeric "
                    "non-root user, so set podSecurityContext.runAsUser"
                )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("rendered")
    parser.add_argument("--registry", action="store_true", help="also read each image from its registry (needs crane)")
    args = parser.parse_args()

    docs = list(documents(args.rendered))
    if not docs:
        print(f"nothing rendered in {args.rendered}", file=sys.stderr)
        return 1
    checks = [check_forbidden, check_digests, check_routes] + ([check_registry] if args.registry else [])

    errors = []
    for check in checks:
        print(f"== {check.__name__.removeprefix('check_')}")
        check(docs, errors)
    for error in errors:
        print(f"::error::{error}")
    print(f"{len(docs)} objects, {len(errors)} problem(s)")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
