"""App Store version and release operations."""

from typing import Optional

from asc.client import ASCClient
from asc.models import AppStoreVersion, AppStoreVersionLocalization, Build


EDITABLE_VERSION_STATES = frozenset({
    "PREPARE_FOR_SUBMISSION",
    "READY_FOR_SUBMISSION",
    "DEVELOPER_REJECTED",
    "METADATA_REJECTED",
    "REJECTED",
    "INVALID_BINARY",
    "WAITING_FOR_EXPORT_COMPLIANCE",
})


def list_app_store_versions(
    client: ASCClient, app_id: str, platform: Optional[str] = None
) -> list[AppStoreVersion]:
    params = {"include": "build"}
    if platform:
        params["filter[platform]"] = platform
    result = client.get_all_paginated_with_includes(
        f"/v1/apps/{app_id}/appStoreVersions", params=params
    )
    return [AppStoreVersion.from_api(item, result["included"]) for item in result["data"]]


def get_app_store_version(client: ASCClient, version_id: str) -> AppStoreVersion:
    result = client.get(
        f"/v1/appStoreVersions/{version_id}", params={"include": "build"}
    )
    included = result.get("included", [])
    return AppStoreVersion.from_api(result["data"], included)


def create_app_store_version(
    client: ASCClient,
    app_id: str,
    version_string: str,
    platform: str = "IOS",
    release_type: Optional[str] = None,
) -> AppStoreVersion:
    body: dict = {
        "data": {
            "type": "appStoreVersions",
            "attributes": {
                "versionString": version_string,
                "platform": platform,
            },
            "relationships": {
                "app": {
                    "data": {"type": "apps", "id": app_id}
                }
            },
        }
    }
    if release_type:
        body["data"]["attributes"]["releaseType"] = release_type
    result = client.post("/v1/appStoreVersions", body)
    return AppStoreVersion.from_api(result["data"])


def find_editable_version(
    client: ASCClient,
    app_id: str,
    platform: str = "IOS",
) -> Optional[AppStoreVersion]:
    """Return the most recently created appStoreVersion in an editable state, or None.

    "Editable" means the developer can still modify metadata or attach a build —
    see ``EDITABLE_VERSION_STATES`` for the full set.
    """
    versions = list_app_store_versions(client, app_id, platform=platform)
    editable = [v for v in versions if v.state in EDITABLE_VERSION_STATES]
    if not editable:
        return None
    editable.sort(key=lambda v: v.created_date or "", reverse=True)
    return editable[0]


def set_version_release_type(
    client: ASCClient,
    version_id: str,
    release_type: str,
) -> AppStoreVersion:
    """Set ``releaseType`` on an appStoreVersion (MANUAL, AFTER_APPROVAL, SCHEDULED)."""
    result = client.patch(
        f"/v1/appStoreVersions/{version_id}",
        {
            "data": {
                "type": "appStoreVersions",
                "id": version_id,
                "attributes": {"releaseType": release_type},
            }
        },
    )
    return AppStoreVersion.from_api(result["data"])


def set_build_for_version(
    client: ASCClient, version_id: str, build_id: str
) -> AppStoreVersion:
    body = {
        "data": {
            "type": "appStoreVersions",
            "id": version_id,
            "relationships": {
                "build": {
                    "data": {"type": "builds", "id": build_id}
                }
            },
        }
    }
    result = client.patch(f"/v1/appStoreVersions/{version_id}", body)
    return AppStoreVersion.from_api(result["data"])


def clear_build_for_version(
    client: ASCClient, version_id: str
) -> AppStoreVersion:
    """Detach whatever build is currently associated with the appStoreVersion.

    Sets the ``build`` relationship data to null. Attaching a fresh build over an
    already-attached one can be rejected by App Store Connect, so callers that
    re-run a release clear the old build first, then set the newest one.
    """
    body = {
        "data": {
            "type": "appStoreVersions",
            "id": version_id,
            "relationships": {
                "build": {"data": None}
            },
        }
    }
    result = client.patch(f"/v1/appStoreVersions/{version_id}", body)
    return AppStoreVersion.from_api(result["data"])


def list_builds(
    client: ASCClient,
    app_id: str,
    processing_state: Optional[str] = None,
) -> list[Build]:
    params: dict = {}
    if processing_state:
        params["filter[processingState]"] = processing_state
    items = client.get_all(f"/v1/apps/{app_id}/builds", params=params or None)
    return [Build.from_api(item) for item in items]


def get_version_localizations(
    client: ASCClient, version_id: str
) -> list[AppStoreVersionLocalization]:
    items = client.get_all(
        f"/v1/appStoreVersions/{version_id}/appStoreVersionLocalizations"
    )
    return [AppStoreVersionLocalization.from_api(item) for item in items]


_LOCALIZATION_API_KEYS = {
    "description": "description",
    "promotional_text": "promotionalText",
    "whats_new": "whatsNew",
    "keywords": "keywords",
}


def _localization_attributes(**fields) -> dict:
    return {
        _LOCALIZATION_API_KEYS[k]: v
        for k, v in fields.items()
        if k in _LOCALIZATION_API_KEYS and v is not None
    }


def update_version_localization(
    client: ASCClient,
    localization_id: str,
    *,
    description: Optional[str] = None,
    promotional_text: Optional[str] = None,
    whats_new: Optional[str] = None,
    keywords: Optional[str] = None,
) -> dict:
    """Update one or more fields on an existing appStoreVersionLocalization."""
    attrs = _localization_attributes(
        description=description,
        promotional_text=promotional_text,
        whats_new=whats_new,
        keywords=keywords,
    )
    return client.patch(
        f"/v1/appStoreVersionLocalizations/{localization_id}",
        {
            "data": {
                "type": "appStoreVersionLocalizations",
                "id": localization_id,
                "attributes": attrs,
            }
        },
    )


def create_version_localization(
    client: ASCClient,
    version_id: str,
    locale: str,
    *,
    description: Optional[str] = None,
    promotional_text: Optional[str] = None,
    whats_new: Optional[str] = None,
    keywords: Optional[str] = None,
) -> dict:
    """Create a new appStoreVersionLocalization for the given locale."""
    attrs: dict = {"locale": locale}
    attrs.update(_localization_attributes(
        description=description,
        promotional_text=promotional_text,
        whats_new=whats_new,
        keywords=keywords,
    ))
    return client.post(
        "/v1/appStoreVersionLocalizations",
        {
            "data": {
                "type": "appStoreVersionLocalizations",
                "attributes": attrs,
                "relationships": {
                    "appStoreVersion": {
                        "data": {"type": "appStoreVersions", "id": version_id}
                    }
                },
            }
        },
    )


def prepare_review_submission(client: ASCClient, app_id: str, version_id: str) -> str:
    """Create a review submission and stage the version on it (does NOT submit).

    After this returns, the review submission exists and holds the app store
    version as an item, but ``submitted`` is still False — App Store Connect
    shows the version as "Ready for Review". Call
    :func:`confirm_review_submission` with the returned submission id to actually
    send it to Apple.
    """
    # Step 1: Create a review submission for the app
    submission = client.post("/v1/reviewSubmissions", {
        "data": {
            "type": "reviewSubmissions",
            "relationships": {
                "app": {
                    "data": {"type": "apps", "id": app_id}
                }
            },
        }
    })
    submission_id = submission["data"]["id"]

    # Step 2: Add the app store version as a submission item
    client.post("/v1/reviewSubmissionItems", {
        "data": {
            "type": "reviewSubmissionItems",
            "relationships": {
                "reviewSubmission": {
                    "data": {"type": "reviewSubmissions", "id": submission_id}
                },
                "appStoreVersion": {
                    "data": {"type": "appStoreVersions", "id": version_id}
                },
            },
        }
    })
    return submission_id


def confirm_review_submission(client: ASCClient, submission_id: str) -> dict:
    """Confirm (send to Apple) a review submission staged by
    :func:`prepare_review_submission`."""
    return client.patch(f"/v1/reviewSubmissions/{submission_id}", {
        "data": {
            "type": "reviewSubmissions",
            "id": submission_id,
            "attributes": {"submitted": True},
        }
    })


def submit_for_review(client: ASCClient, app_id: str, version_id: str) -> dict:
    """Stage the version on a review submission and immediately confirm it."""
    submission_id = prepare_review_submission(client, app_id, version_id)
    return confirm_review_submission(client, submission_id)
