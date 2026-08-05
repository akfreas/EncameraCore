"""MCP server for App Store Connect API."""

import os
from dataclasses import asdict
from typing import Any, Optional

from mcp.server.fastmcp import FastMCP

from asc.auth import Credentials
from asc.client import ASCClient
from asc.pricing import iap, subscriptions
from asc import releases
from asc.xcode_cloud import (
    artifacts as xc_artifacts,
    build_actions as xc_build_actions,
    build_runs as xc_build_runs,
    environments as xc_environments,
    issues as xc_issues,
    products as xc_products,
    scm as xc_scm,
    test_results as xc_test_results,
    workflows as xc_workflows,
)

mcp = FastMCP("App Store Connect")

_client: Optional[ASCClient] = None


def _get_client() -> ASCClient:
    global _client
    if _client is None:
        yaml_path = os.environ.get("ASC_CREDENTIALS_PATH")
        creds = Credentials.load(yaml_path)
        _client = ASCClient(creds)
    return _client


@mcp.tool()
def list_subscription_groups(app_id: Optional[str] = None) -> list[dict]:
    """List all subscription groups for the app.
    Returns id and name for each group. Use the group id with list_subscriptions to see the subscriptions in that group."""
    client = _get_client()
    aid = app_id or client.resolve_app_id()
    groups = subscriptions.list_subscription_groups(client, aid)
    return [asdict(g) for g in groups]


@mcp.tool()
def list_subscriptions(group_id: str) -> list[dict]:
    """List all subscriptions in a subscription group.
    Returns id, name, product_id, state for each subscription.
    Use the subscription id with get_subscription_prices or get_subscription_price_points."""
    client = _get_client()
    subs = subscriptions.list_subscriptions(client, group_id)
    return [asdict(s) for s in subs]


@mcp.tool()
def get_subscription_prices(subscription_id: str) -> list[dict]:
    """Get current prices for a subscription across all territories.
    Returns territory (3-letter code like USA, IND), currency, price, and start_date for each territory.
    This shows what customers currently pay, not the available price tiers."""
    client = _get_client()
    prices = subscriptions.get_subscription_prices(client, subscription_id)
    return [asdict(p) for p in prices]


@mcp.tool()
def get_subscription_price_points(
    subscription_id: str,
    territory: Optional[str] = None,
    target_price: Optional[float] = None,
) -> list[dict]:
    """Get available price points (tiers) that a subscription can be set to.
    These are NOT current prices — use get_subscription_prices for that.
    Use territory (3-letter code, e.g. 'USA', 'IND') to filter to one country.
    Use target_price to find the closest match — returns 3 price points above and below the target.
    Always use target_price with territory to avoid massive result sets.
    The returned price point id is needed for set_subscription_price."""
    client = _get_client()
    points = subscriptions.get_subscription_price_points(client, subscription_id, territory)
    if target_price is not None:
        points.sort(key=lambda p: float(p.customer_price))
        below = [p for p in points if float(p.customer_price) <= target_price][-3:]
        above = [p for p in points if float(p.customer_price) > target_price][:3]
        points = below + above
    return [asdict(p) for p in points]


@mcp.tool()
def set_subscription_price(
    subscription_id: str, price_point_id: str, start_date: Optional[str] = None
) -> dict:
    """Set the price for a subscription in a specific territory using a price point ID from get_subscription_price_points.
    For approved subscriptions that already have prices, a start_date (YYYY-MM-DD) is REQUIRED —
    the API rejects creating an "initial" price again. The start_date must be at least 2 days in the future.
    The price point ID encodes the subscription, territory, and price tier, so no separate territory param is needed.
    IAP prices are set differently — use set_iap_price_schedule for those."""
    client = _get_client()
    return subscriptions.set_subscription_price(client, subscription_id, price_point_id, start_date)


@mcp.tool()
def delete_subscription_price(price_id: str) -> str:
    """Delete a scheduled subscription price change. Only works for future-dated price changes, not current prices.
    The price_id comes from get_subscription_prices."""
    client = _get_client()
    subscriptions.delete_subscription_price(client, price_id)
    return "Deleted"


@mcp.tool()
def list_in_app_purchases(app_id: Optional[str] = None) -> list[dict]:
    """List all in-app purchases for the app.
    Returns id, name, product_id, iap_type (CONSUMABLE, NON_CONSUMABLE), and state.
    Use the id with get_iap_price_schedule or get_iap_price_points."""
    client = _get_client()
    aid = app_id or client.resolve_app_id()
    iaps = iap.list_in_app_purchases(client, aid)
    return [asdict(i) for i in iaps]


@mcp.tool()
def get_iap_price_points(
    iap_id: str,
    territory: Optional[str] = None,
    target_price: Optional[float] = None,
) -> list[dict]:
    """Get available price points (tiers) that an IAP can be set to.
    These are NOT current prices — use get_iap_price_schedule for that.
    Use territory (3-letter code, e.g. 'USA', 'IND') to filter to one country.
    Use target_price to find the closest match — returns 3 price points above and below the target.
    Always use target_price with territory to avoid massive result sets.
    The returned price point id is needed for set_iap_price_schedule."""
    client = _get_client()
    points = iap.get_iap_price_points(client, iap_id, territory)
    if target_price is not None:
        points.sort(key=lambda p: float(p.customer_price))
        below = [p for p in points if float(p.customer_price) <= target_price][-3:]
        above = [p for p in points if float(p.customer_price) > target_price][:3]
        points = below + above
    return [asdict(p) for p in points]


@mcp.tool()
def get_iap_price_schedule(iap_id: str, territory: Optional[str] = None) -> list[dict]:
    """Get the current prices for an IAP across all territories, with resolved price amounts.
    Returns territory, currency, price, and whether it's a manual or automatic price.
    Manual prices are ones you explicitly set; automatic prices are Apple's equalized prices for other territories.
    Filter by territory (3-letter code, e.g. 'USA', 'IND') to see just one country."""
    client = _get_client()
    prices = iap.get_iap_price_schedule(client, iap_id, territory)
    return [asdict(p) for p in prices]


@mcp.tool()
def set_iap_price_schedule(
    iap_id: str, base_territory: str, manual_prices: list[dict]
) -> dict:
    """Set the price schedule for an in-app purchase. Takes effect immediately.
    IMPORTANT: You MUST always include the base territory (usually 'USA') price point in manual_prices,
    otherwise the API returns a 409 ENTITY_ERROR.BASE_TERRITORY_INTERVAL_REQUIRED error.
    To set a custom price for one territory while keeping others auto-equalized:
    1. Get the current base territory price point id via get_iap_price_points
    2. Get the target territory price point id via get_iap_price_points
    3. Include both in manual_prices

    manual_prices: list of {"territory_id": str, "price_point_id": str}
    base_territory: 3-letter territory code (e.g. 'USA')"""
    client = _get_client()
    return iap.set_iap_price_schedule(client, iap_id, base_territory, manual_prices)


@mcp.tool()
def list_app_store_versions(app_id: Optional[str] = None, platform: Optional[str] = None) -> list[dict]:
    """List all App Store versions for the app, with their current state and attached build.
    States include PREPARE_FOR_SUBMISSION, WAITING_FOR_REVIEW, IN_REVIEW, READY_FOR_SALE, etc.
    Filter by platform (IOS, MAC_OS, TV_OS, VISION_OS) if the app supports multiple."""
    client = _get_client()
    aid = app_id or client.resolve_app_id()
    versions = releases.list_app_store_versions(client, aid, platform)
    return [asdict(v) for v in versions]


@mcp.tool()
def get_app_store_version(version_id: str) -> dict:
    """Get details for a specific App Store version, including its state and attached build."""
    client = _get_client()
    version = releases.get_app_store_version(client, version_id)
    return asdict(version)


@mcp.tool()
def create_app_store_version(
    version_string: str,
    platform: str = "IOS",
    release_type: Optional[str] = None,
    app_id: Optional[str] = None,
) -> dict:
    """Create a new App Store version (release) for the app.
    version_string: the public version number, e.g. '2.4.1'.
    platform: IOS, MAC_OS, TV_OS, or VISION_OS. Defaults to IOS.
    release_type: optional — MANUAL or AFTER_APPROVAL. If omitted, uses the app's default."""
    client = _get_client()
    aid = app_id or client.resolve_app_id()
    version = releases.create_app_store_version(client, aid, version_string, platform, release_type)
    return asdict(version)


@mcp.tool()
def set_build_for_version(version_id: str, build_id: str) -> dict:
    """Attach a build to an App Store version. The build must have finished processing.
    Use list_builds to find available builds and their IDs.
    version_id: the App Store version ID from list_app_store_versions or create_app_store_version.
    build_id: the build ID from list_builds."""
    client = _get_client()
    version = releases.set_build_for_version(client, version_id, build_id)
    return asdict(version)


@mcp.tool()
def list_builds(
    app_id: Optional[str] = None,
    processing_state: Optional[str] = None,
) -> list[dict]:
    """List builds uploaded to App Store Connect.
    Filter by processing_state: PROCESSING, FAILED, INVALID, VALID.
    Returns id, version (build number), processing state, upload date, and min OS version."""
    client = _get_client()
    aid = app_id or client.resolve_app_id()
    builds = releases.list_builds(client, aid, processing_state)
    return [asdict(b) for b in builds]


@mcp.tool()
def get_version_localizations(version_id: str) -> list[dict]:
    """Get all localizations for an App Store version — description, keywords, what's new,
    promotional text, and URLs for each locale.
    version_id: the App Store version ID from list_app_store_versions."""
    client = _get_client()
    locs = releases.get_version_localizations(client, version_id)
    return [asdict(loc) for loc in locs]


@mcp.tool()
def submit_for_review(version_id: str, app_id: Optional[str] = None) -> dict:
    """Submit an App Store version for review.
    The version must have a build attached and all required metadata filled in.
    version_id: the App Store version ID from list_app_store_versions."""
    client = _get_client()
    aid = app_id or client.resolve_app_id()
    return releases.submit_for_review(client, aid, version_id)


# ---------------------------------------------------------------------------
# Xcode Cloud tools
#
# Typical failure-diagnosis flow:
#   1. list_ci_products (or get_ci_product_for_app) → find the product id
#   2. list_ci_workflows → find the workflow id
#   3. list_ci_build_runs → find the failed run (completion_status=FAILED/ERRORED)
#   4. list_ci_build_actions → find which action failed
#   5. list_ci_issues → read the actual error messages
# ---------------------------------------------------------------------------


@mcp.tool()
def list_ci_products() -> list[dict]:
    """List all Xcode Cloud products visible to the API key.
    A ciProduct is the Xcode Cloud record tied to one ASC app (or framework).
    Returns id, name, product_type (APP or FRAMEWORK), and the linked app_id."""
    return [asdict(p) for p in xc_products.list_products(_get_client())]


@mcp.tool()
def get_ci_product(product_id: str) -> dict:
    """Get a single Xcode Cloud product by id."""
    return asdict(xc_products.get_product(_get_client(), product_id))


@mcp.tool()
def get_ci_product_for_app(app_id: Optional[str] = None) -> Optional[dict]:
    """Find the ciProduct tied to an ASC app. If app_id is omitted, uses
    the configured app_id/bundle_id. Returns None if no Xcode Cloud product
    exists for that app."""
    client = _get_client()
    aid = app_id or client.resolve_app_id()
    product = xc_products.get_product_for_app(client, aid)
    return asdict(product) if product else None


@mcp.tool()
def list_ci_workflows(product_id: str) -> list[dict]:
    """List workflows under a ciProduct.
    Returns id, name, description, is_enabled, clean, container_file_path, repository_id.
    Use the id with list_ci_build_runs."""
    return [asdict(w) for w in xc_workflows.list_workflows_for_product(_get_client(), product_id)]


@mcp.tool()
def get_ci_workflow(workflow_id: str) -> dict:
    """Get a workflow by id. raw_attributes contains the full workflow config
    (start conditions, actions, environment) as Apple returns it."""
    return asdict(xc_workflows.get_workflow(_get_client(), workflow_id))


@mcp.tool()
def create_ci_workflow(
    product_id: str,
    repository_id: str,
    attributes: dict[str, Any],
    xcode_version_id: Optional[str] = None,
    macos_version_id: Optional[str] = None,
) -> dict:
    """Create a new workflow. attributes is the full ciWorkflow attribute dict
    (name, description, branchStartCondition, actions, containerFilePath, etc.)
    Pass xcode_version_id and macos_version_id to pin the environment —
    fetch them from list_ci_xcode_versions / list_ci_macos_versions."""
    return asdict(xc_workflows.create_workflow(
        _get_client(), product_id, repository_id, attributes, xcode_version_id, macos_version_id,
    ))


@mcp.tool()
def update_ci_workflow(workflow_id: str, attributes: dict[str, Any]) -> dict:
    """Patch workflow attributes. Only send the keys you want to change."""
    return asdict(xc_workflows.update_workflow(_get_client(), workflow_id, attributes))


@mcp.tool()
def delete_ci_workflow(workflow_id: str) -> str:
    """Delete a workflow. Irreversible."""
    xc_workflows.delete_workflow(_get_client(), workflow_id)
    return "Deleted"


@mcp.tool()
def list_ci_build_runs(
    workflow_id: Optional[str] = None,
    product_id: Optional[str] = None,
    limit: Optional[int] = None,
) -> list[dict]:
    """List build runs, newest first. Pass workflow_id to scope to one workflow,
    or product_id to see runs across all workflows in a product.
    Returns number, execution_progress, completion_status, start_reason,
    cancel_reason, created/started/finished dates, source_commit_sha, and
    issue_counts. To investigate a failure, look for completion_status in
    FAILED/ERRORED/CANCELED."""
    client = _get_client()
    if workflow_id:
        runs = xc_build_runs.list_build_runs_for_workflow(client, workflow_id, limit)
    elif product_id:
        runs = xc_build_runs.list_build_runs_for_product(client, product_id, limit)
    else:
        raise ValueError("Must provide either workflow_id or product_id")
    return [asdict(r) for r in runs]


@mcp.tool()
def get_ci_build_run(build_run_id: str) -> dict:
    """Get full details for a specific build run."""
    return asdict(xc_build_runs.get_build_run(_get_client(), build_run_id))


@mcp.tool()
def find_ci_build_runs_for_commit(
    commit_sha: str,
    workflow_id: Optional[str] = None,
    product_id: Optional[str] = None,
    limit: int = 200,
) -> list[dict]:
    """Find Xcode Cloud build runs whose source commit matches commit_sha.
    Use this to map a PR head SHA (from `gh pr view --json headRefOid`) to the
    Xcode Cloud runs Apple kicked off for it — typically one PR-validation run
    plus a TestFlight archive run. Pass workflow_id to scope to one workflow
    (faster), otherwise pass product_id to scan every workflow in the product.
    Accepts full SHA or any prefix of >=7 chars. Each returned run's
    builds_ids list points at the resulting App Store Connect builds — use
    list_ci_build_run_builds to dereference them."""
    runs = xc_build_runs.find_build_runs_by_commit(
        _get_client(), commit_sha, product_id=product_id, workflow_id=workflow_id, limit=limit,
    )
    return [asdict(r) for r in runs]


@mcp.tool()
def list_ci_build_run_builds(build_run_id: str) -> list[dict]:
    """List the App Store Connect builds (TestFlight uploads) produced by a
    Xcode Cloud build run. Empty for runs that didn't archive — PR validation
    runs, test-only runs, and failed runs that never reached the upload step.
    Returns the same Build shape as list_builds (version, processing state,
    upload date)."""
    return [asdict(b) for b in xc_build_runs.list_builds_for_build_run(_get_client(), build_run_id)]


@mcp.tool()
def list_ci_git_references(
    workflow_id: Optional[str] = None,
    repository_id: Optional[str] = None,
    kind: Optional[str] = None,
) -> list[dict]:
    """List the branches and tags a workflow (or repository) can build.

    Pass workflow_id to resolve the repository automatically, or repository_id
    directly. kind filters to BRANCH or TAG. Deleted refs are omitted. The
    returned id is the source_branch_or_tag_id that start_ci_build_run wants."""
    client = _get_client()
    if repository_id is None:
        if workflow_id is None:
            raise ValueError("Provide either workflow_id or repository_id")
        repo = xc_scm.get_repository_for_workflow(client, workflow_id)
        if repo is None:
            return []
        repository_id = repo.id
    return [asdict(r) for r in xc_scm.list_git_references(client, repository_id, kind=kind)]


@mcp.tool()
def start_ci_build_run(
    workflow_id: str,
    source_branch_or_tag_id: Optional[str] = None,
    pull_request_id: Optional[str] = None,
) -> dict:
    """Start a new build run for a workflow. Supply exactly one of
    source_branch_or_tag_id (from list_ci_git_references) or pull_request_id
    (from scmPullRequests), unless the workflow is fully manual."""
    return asdict(xc_build_runs.start_build_run(
        _get_client(), workflow_id, source_branch_or_tag_id, pull_request_id,
    ))


@mcp.tool()
def cancel_ci_build_run(build_run_id: str) -> dict:
    """Cancel an in-flight build run."""
    return asdict(xc_build_runs.cancel_build_run(_get_client(), build_run_id))


@mcp.tool()
def list_ci_build_actions(build_run_id: str) -> list[dict]:
    """List actions for a build run (BUILD, TEST, ANALYZE, ARCHIVE).
    Returns id, name, action_type, execution_progress, completion_status,
    and issue_counts. A failed run will have at least one action with
    completion_status=FAILED — drill into it with list_ci_issues."""
    return [asdict(a) for a in xc_build_actions.list_build_actions_for_run(_get_client(), build_run_id)]


@mcp.tool()
def get_ci_build_action(build_action_id: str) -> dict:
    """Get a single build action by id."""
    return asdict(xc_build_actions.get_build_action(_get_client(), build_action_id))


@mcp.tool()
def list_ci_issues(build_action_id: str) -> list[dict]:
    """List issues (errors, warnings, analyzer findings, test failures) for a
    build action. issue_type is ERROR / WARNING / ANALYZER_WARNING / TEST_FAILURE.
    message contains the compiler/runner output; file_path and line_number
    point at the source. This is where the 'why did it fail' text lives."""
    return [asdict(i) for i in xc_issues.list_issues_for_action(_get_client(), build_action_id)]


@mcp.tool()
def get_ci_issue(issue_id: str) -> dict:
    """Get a single issue by id."""
    return asdict(xc_issues.get_issue(_get_client(), issue_id))


@mcp.tool()
def list_ci_artifacts(build_action_id: str) -> list[dict]:
    """List artifacts (archives, log bundles, result bundles) produced by a
    build action. download_url is short-lived — fetch immediately if needed."""
    return [asdict(a) for a in xc_artifacts.list_artifacts_for_action(_get_client(), build_action_id)]


@mcp.tool()
def get_ci_artifact(artifact_id: str) -> dict:
    """Get a single artifact by id."""
    return asdict(xc_artifacts.get_artifact(_get_client(), artifact_id))


@mcp.tool()
def list_ci_test_results(build_action_id: str) -> list[dict]:
    """List test results for a TEST build action. Each entry has class_name,
    name, status, and per-device destination_test_results."""
    return [asdict(t) for t in xc_test_results.list_test_results_for_action(_get_client(), build_action_id)]


@mcp.tool()
def get_ci_test_result(test_result_id: str) -> dict:
    """Get a single test result by id."""
    return asdict(xc_test_results.get_test_result(_get_client(), test_result_id))


@mcp.tool()
def list_ci_macos_versions() -> list[dict]:
    """Available macOS versions for Xcode Cloud workflows."""
    return [asdict(v) for v in xc_environments.list_macos_versions(_get_client())]


@mcp.tool()
def list_ci_xcode_versions() -> list[dict]:
    """Available Xcode versions for Xcode Cloud workflows."""
    return [asdict(v) for v in xc_environments.list_xcode_versions(_get_client())]


def main():
    mcp.run()


if __name__ == "__main__":
    main()
