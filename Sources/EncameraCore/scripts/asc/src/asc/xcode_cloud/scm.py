"""scmRepository and scmGitReference operations.

Starting a build run requires the id of the branch or tag to build, and that
id lives in a different resource tree than the workflow does: a ciWorkflow
points at an scmRepository, and the repository owns the scmGitReferences. Both
relationships come back as links with no ``data`` member, so they have to be
followed rather than read off the parent — hence the helpers here.
"""

from typing import Any, Optional

from asc.client import ASCClient
from asc.xcode_cloud.models import ScmGitReference, ScmRepository


def get_repository_for_workflow(
    client: ASCClient, workflow_id: str
) -> Optional[ScmRepository]:
    """The scmRepository a workflow builds from, or None if it has none."""
    result = client.get(f"/v1/ciWorkflows/{workflow_id}/repository")
    data = result.get("data")
    if not data:
        return None
    return ScmRepository.from_api(data)


def list_git_references(
    client: ASCClient,
    repository_id: str,
    kind: Optional[str] = None,
    include_deleted: bool = False,
) -> list[ScmGitReference]:
    """Branches and tags known to a repository.

    ``kind`` filters to ``"BRANCH"`` or ``"TAG"`` client-side — the endpoint
    exposes kind as an attribute, not a filter. Deleted refs are dropped unless
    ``include_deleted`` is set; Apple keeps them around long after the branch is
    gone, and building one is never what you want.
    """
    items = client.get_all(
        f"/v1/scmRepositories/{repository_id}/gitReferences", params={"limit": 200}
    )
    refs = [ScmGitReference.from_api(item) for item in items]
    if not include_deleted:
        refs = [r for r in refs if not r.is_deleted]
    if kind:
        refs = [r for r in refs if r.kind == kind]
    return refs


def find_git_reference(
    client: ASCClient,
    repository_id: str,
    name: str,
    kind: str = "BRANCH",
) -> Optional[ScmGitReference]:
    """The live branch (or tag) named ``name``, or None if there isn't one."""
    for ref in list_git_references(client, repository_id, kind=kind):
        if ref.name == name:
            return ref
    return None


def find_workflow_git_reference(
    client: ASCClient,
    workflow_id: str,
    name: str,
    kind: str = "BRANCH",
) -> Optional[ScmGitReference]:
    """Resolve ``name`` against the repository a workflow builds from.

    The two-hop version of :func:`find_git_reference`, for callers that hold a
    workflow id and want the git reference id to pass to ``start_build_run``.
    """
    repo = get_repository_for_workflow(client, workflow_id)
    if repo is None:
        return None
    return find_git_reference(client, repo.id, name, kind=kind)


def get_git_reference(client: ASCClient, reference_id: str) -> dict[str, Any]:
    """Raw scmGitReference resource by id."""
    return client.get(f"/v1/scmGitReferences/{reference_id}")["data"]
