"""Data models for Xcode Cloud resources.

Kept separate from asc.models so the top-level models file doesn't balloon
with CI-specific types. One dataclass per ciResource.
"""

from dataclasses import dataclass, field
from typing import Any, Optional


def _rel_id(data: dict, name: str) -> Optional[str]:
    rel = data.get("relationships", {}).get(name, {}).get("data")
    if isinstance(rel, dict):
        return rel.get("id")
    return None


def _rel_ids(data: dict, name: str) -> list[str]:
    rel = data.get("relationships", {}).get(name, {}).get("data")
    if isinstance(rel, list):
        return [item.get("id") for item in rel if item.get("id")]
    return []


@dataclass
class CiProduct:
    id: str
    name: str
    product_type: str
    created_date: Optional[str]
    app_id: Optional[str]

    @classmethod
    def from_api(cls, data: dict) -> "CiProduct":
        attrs = data.get("attributes", {})
        return cls(
            id=data["id"],
            name=attrs.get("name", ""),
            product_type=attrs.get("productType", ""),
            created_date=attrs.get("createdDate"),
            app_id=_rel_id(data, "app"),
        )


@dataclass
class CiWorkflow:
    id: str
    name: str
    description: str
    is_enabled: bool
    is_locked_for_editing: bool
    clean: bool
    container_file_path: str
    last_modified_date: Optional[str]
    product_id: Optional[str]
    repository_id: Optional[str]
    raw_attributes: dict[str, Any] = field(default_factory=dict)

    @classmethod
    def from_api(cls, data: dict) -> "CiWorkflow":
        attrs = data.get("attributes", {}) or {}
        return cls(
            id=data["id"],
            name=attrs.get("name", ""),
            description=attrs.get("description", ""),
            is_enabled=bool(attrs.get("isEnabled", False)),
            is_locked_for_editing=bool(attrs.get("isLockedForEditing", False)),
            clean=bool(attrs.get("clean", False)),
            container_file_path=attrs.get("containerFilePath", ""),
            last_modified_date=attrs.get("lastModifiedDate"),
            product_id=_rel_id(data, "product"),
            repository_id=_rel_id(data, "repository"),
            raw_attributes=attrs,
        )


@dataclass
class CiBuildRun:
    id: str
    number: Optional[int]
    execution_progress: str
    completion_status: Optional[str]
    start_reason: Optional[str]
    cancel_reason: Optional[str]
    created_date: Optional[str]
    started_date: Optional[str]
    finished_date: Optional[str]
    source_commit_sha: Optional[str]
    source_commit_message: Optional[str]
    source_commit_author: Optional[str]
    destination_commit_sha: Optional[str]
    is_pull_request_build: bool
    issue_counts: dict[str, Any]
    workflow_id: Optional[str]
    product_id: Optional[str]
    source_branch_or_tag_id: Optional[str]
    destination_branch_id: Optional[str]
    pull_request_id: Optional[str]
    builds_ids: list[str]

    @classmethod
    def from_api(cls, data: dict) -> "CiBuildRun":
        attrs = data.get("attributes", {}) or {}
        source = attrs.get("sourceCommit") or {}
        dest = attrs.get("destinationCommit") or {}
        author = source.get("author") or {}
        return cls(
            id=data["id"],
            number=attrs.get("number"),
            execution_progress=attrs.get("executionProgress", ""),
            completion_status=attrs.get("completionStatus"),
            start_reason=attrs.get("startReason"),
            cancel_reason=attrs.get("cancelReason"),
            created_date=attrs.get("createdDate"),
            started_date=attrs.get("startedDate"),
            finished_date=attrs.get("finishedDate"),
            source_commit_sha=source.get("commitSha"),
            source_commit_message=source.get("message"),
            source_commit_author=author.get("displayName") or author.get("emailAddress"),
            destination_commit_sha=dest.get("commitSha"),
            is_pull_request_build=bool(attrs.get("isPullRequestBuild", False)),
            issue_counts=attrs.get("issueCounts") or {},
            workflow_id=_rel_id(data, "workflow"),
            product_id=_rel_id(data, "product"),
            source_branch_or_tag_id=_rel_id(data, "sourceBranchOrTag"),
            destination_branch_id=_rel_id(data, "destinationBranch"),
            pull_request_id=_rel_id(data, "pullRequest"),
            builds_ids=_rel_ids(data, "builds"),
        )


@dataclass
class ScmRepository:
    id: str
    repository_name: str
    owner_name: str
    http_clone_url: Optional[str]
    ssh_clone_url: Optional[str]
    last_accessed_date: Optional[str]

    @classmethod
    def from_api(cls, data: dict) -> "ScmRepository":
        attrs = data.get("attributes", {}) or {}
        return cls(
            id=data["id"],
            repository_name=attrs.get("repositoryName", ""),
            owner_name=attrs.get("ownerName", ""),
            http_clone_url=attrs.get("httpCloneUrl"),
            ssh_clone_url=attrs.get("sshCloneUrl"),
            last_accessed_date=attrs.get("lastAccessedDate"),
        )


@dataclass
class ScmGitReference:
    id: str
    name: str
    canonical_name: str
    kind: str
    is_deleted: bool

    @classmethod
    def from_api(cls, data: dict) -> "ScmGitReference":
        attrs = data.get("attributes", {}) or {}
        return cls(
            id=data["id"],
            name=attrs.get("name", ""),
            canonical_name=attrs.get("canonicalName", ""),
            kind=attrs.get("kind", ""),
            is_deleted=bool(attrs.get("isDeleted", False)),
        )


@dataclass
class CiBuildAction:
    id: str
    name: str
    action_type: str
    execution_progress: str
    completion_status: Optional[str]
    started_date: Optional[str]
    finished_date: Optional[str]
    is_required_to_pass: bool
    issue_counts: dict[str, Any]
    build_run_id: Optional[str]

    @classmethod
    def from_api(cls, data: dict) -> "CiBuildAction":
        attrs = data.get("attributes", {}) or {}
        return cls(
            id=data["id"],
            name=attrs.get("name", ""),
            action_type=attrs.get("actionType", ""),
            execution_progress=attrs.get("executionProgress", ""),
            completion_status=attrs.get("completionStatus"),
            started_date=attrs.get("startedDate"),
            finished_date=attrs.get("finishedDate"),
            is_required_to_pass=bool(attrs.get("isRequiredToPass", False)),
            issue_counts=attrs.get("issueCounts") or {},
            build_run_id=_rel_id(data, "buildRun"),
        )


@dataclass
class CiIssue:
    id: str
    issue_type: str
    message: str
    category: Optional[str]
    file_path: Optional[str]
    line_number: Optional[int]

    @classmethod
    def from_api(cls, data: dict) -> "CiIssue":
        attrs = data.get("attributes", {}) or {}
        file_source = attrs.get("fileSource") or {}
        return cls(
            id=data["id"],
            issue_type=attrs.get("issueType", ""),
            message=attrs.get("message", ""),
            category=attrs.get("category"),
            file_path=file_source.get("fileName") or file_source.get("filePath"),
            line_number=file_source.get("lineNumber"),
        )


@dataclass
class CiArtifact:
    id: str
    file_type: str
    file_name: str
    file_size: Optional[int]
    download_url: Optional[str]

    @classmethod
    def from_api(cls, data: dict) -> "CiArtifact":
        attrs = data.get("attributes", {}) or {}
        return cls(
            id=data["id"],
            file_type=attrs.get("fileType", ""),
            file_name=attrs.get("fileName", ""),
            file_size=attrs.get("fileSize"),
            download_url=attrs.get("downloadUrl"),
        )


@dataclass
class CiTestResult:
    id: str
    class_name: str
    name: str
    status: str
    message: Optional[str]
    file_path: Optional[str]
    line_number: Optional[int]
    destination_test_results: list[dict[str, Any]]

    @classmethod
    def from_api(cls, data: dict) -> "CiTestResult":
        attrs = data.get("attributes", {}) or {}
        file_source = attrs.get("fileSource") or {}
        return cls(
            id=data["id"],
            class_name=attrs.get("className", ""),
            name=attrs.get("name", ""),
            status=attrs.get("status", ""),
            message=attrs.get("message"),
            file_path=file_source.get("fileName") or file_source.get("filePath"),
            line_number=file_source.get("lineNumber"),
            destination_test_results=attrs.get("destinationTestResults") or [],
        )


@dataclass
class CiMacOsVersion:
    id: str
    name: str
    version: str

    @classmethod
    def from_api(cls, data: dict) -> "CiMacOsVersion":
        attrs = data.get("attributes", {}) or {}
        return cls(
            id=data["id"],
            name=attrs.get("name", ""),
            version=attrs.get("version", ""),
        )


@dataclass
class CiXcodeVersion:
    id: str
    name: str
    version: str

    @classmethod
    def from_api(cls, data: dict) -> "CiXcodeVersion":
        attrs = data.get("attributes", {}) or {}
        return cls(
            id=data["id"],
            name=attrs.get("name", ""),
            version=attrs.get("version", ""),
        )
