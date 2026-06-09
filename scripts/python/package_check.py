#!/usr/bin/env python3
"""
package_check.py — Pre-deploy checks for Salesforce deployment packages.

Responsibilities:
  - Stripping ConnectedApp consumerKey elements before deploy
  - Detecting whether the package contains Apex (ApexClass / ApexTrigger)
  - Returning DESTRUCTIVE_TESTS env var when destroying Apex in production

Output:
  "not a test"        : no Apex in package, or non-production destructive deploy
  DESTRUCTIVE_TESTS   : production destructive deploy with Apex present
  "apex"              : Apex present in non-destroy package (caller runs apextestlist)
"""
import argparse
import logging
import os
import re
import sys
import xml.etree.ElementTree as ET
from typing import List, Optional

APEX_TYPES = {"apexclass", "apextrigger"}
NS_URI = "http://soap.sforce.com/2006/04/metadata"
NS = {"sforce": NS_URI}
ET.register_namespace("", NS_URI)

logging.basicConfig(level=logging.DEBUG, format="%(message)s")


# ── Argument parsing ──────────────────────────────────────────────────────────

def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Pre-deploy checks for a Salesforce package manifest."
    )
    parser.add_argument("-x", "--manifest", default="manifest/package.xml")
    parser.add_argument("-s", "--stage", default="deploy")
    parser.add_argument("-e", "--environment", default=None)
    return parser.parse_args()


# ── Package parsing ───────────────────────────────────────────────────────────

def parse_package(package_path: str) -> Optional[ET.Element]:
    try:
        root = ET.parse(package_path).getroot()
    except FileNotFoundError:
        logging.error("ERROR: %s not found.", package_path)
        sys.exit(1)
    except ET.ParseError as exc:
        logging.error("ERROR: Cannot parse %s: %s", package_path, exc)
        sys.exit(1)
    if not root.findall("sforce:types", NS):
        logging.info("Package has no metadata types — nothing to deploy.")
        return None
    return root


def get_metadata_members_by_type(root: ET.Element, type_name: str) -> List[str]:
    want = type_name.lower()
    out: List[str] = []
    for block in root.findall("sforce:types", NS):
        names = [n.text for n in block.findall("sforce:name", NS)]
        if len(names) != 1 or (names[0] or "").lower() != want:
            continue
        out.extend(m.text for m in block.findall("sforce:members", NS) if m.text)
    return out


# ── Connected Apps ────────────────────────────────────────────────────────────

def process_connected_app(member_list: List[str]) -> None:
    for member in member_list:
        path = f"force-app/main/default/connectedApps/{member}.connectedApp-meta.xml"
        if not os.path.exists(path):
            logging.error("ERROR: ConnectedApp file not found: %s", path)
            sys.exit(1)
        logging.info("Stripping consumerKey from ConnectedApp: %s", member)
        _remove_consumer_key(path)


def _remove_consumer_key(file_path: str) -> None:
    try:
        tree = ET.parse(file_path)
        root = tree.getroot()
    except ET.ParseError:
        logging.error("ERROR: Cannot parse %s", file_path)
        sys.exit(1)
    key_elem = root.find(".//sforce:consumerKey", NS)
    if key_elem is None:
        logging.info("No consumerKey found in %s", file_path)
        return
    for parent in root.iter():
        if key_elem in list(parent):
            parent.remove(key_elem)
            break
    xml_str = ET.tostring(root, encoding="utf-8", method="xml").decode()
    with open(file_path, "w", encoding="utf-8") as f:
        f.write('<?xml version="1.0" encoding="UTF-8"?>\n' + xml_str)
    logging.info("Removed consumerKey from %s", file_path)


# ── Destructive deploy tests ──────────────────────────────────────────────────

def determine_destructive_tests(deleted_apex: Optional[set] = None) -> str:
    """Return test classes for production destructive deploys from DESTRUCTIVE_TESTS env var."""
    tests_env = os.environ.get("DESTRUCTIVE_TESTS", "").strip()
    if not tests_env:
        logging.warning(
            "WARNING: DESTRUCTIVE_TESTS is not set. "
            "Set it in CI/CD variables to a space-separated list of test classes to run "
            "when destroying Apex in production."
        )
        return "not a test"
    if deleted_apex:
        declared_tests = set(re.sub(r"[\s,]+", " ", tests_env).split())
        also_deleted = declared_tests & deleted_apex
        if also_deleted:
            logging.warning(
                "WARNING: The following classes are listed in DESTRUCTIVE_TESTS but are also "
                "being deleted in this package — they cannot run as tests: %s",
                ", ".join(sorted(also_deleted)),
            )
    return tests_env


# ── Main scan ─────────────────────────────────────────────────────────────────

def scan_package(package_path: str, stage: str, env: str) -> str:
    root = parse_package(package_path)
    if root is None:
        return "not a test"

    apex_required = False
    logging.info("Deployment package contents:")
    for block in root.findall("sforce:types", NS):
        names = [n.text for n in block.findall("sforce:name", NS)]
        if len(names) != 1 or not names[0]:
            continue
        metadata_name = names[0]
        members = [m.text for m in block.findall("sforce:members", NS) if m.text]
        logging.info("  %s: %s", metadata_name, ", ".join(members))
        if metadata_name.lower() == "connectedapp" and stage != "destroy":
            process_connected_app(members)
        elif metadata_name.lower() in APEX_TYPES:
            apex_required = True

    if not apex_required:
        logging.info("Apex tests not required.")
        return "not a test"

    if stage == "destroy":
        if (env or "").lower() == "production":
            logging.info("Apex tests required for production destructive deploy.")
            deleted_apex = (
                set(get_metadata_members_by_type(root, "ApexClass"))
                | set(get_metadata_members_by_type(root, "ApexTrigger"))
            )
            return determine_destructive_tests(deleted_apex)
        logging.info("Apex tests not required for non-production destructive deploy.")
        return "not a test"

    logging.info("Apex present — test annotation discovery delegated to apextestlist plugin.")
    return "apex"


def main() -> None:
    args = parse_args()
    result = scan_package(args.manifest, args.stage, args.environment)
    logging.info(result)
    print(result)


if __name__ == "__main__":
    main()
