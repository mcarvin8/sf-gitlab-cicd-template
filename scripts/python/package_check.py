#!/usr/bin/env python3
"""
package_check.py — Determine Apex test classes for a Salesforce deployment package.

With sfdx-git-delta as the package source, structural XML validation is not needed
(sgd always produces well-formed, namespace-correct manifests). This script focuses on:
  - Stripping ConnectedApp consumerKey elements before deploy
  - Extracting Apex test classes from @tests / @isTest annotations
  - CMT-driven test overrides (Custom Metadata switch-based test selection)
  - Returning the DESTRUCTIVE_TESTS env var when destroying Apex in production

Output: space-separated test class names, or the string "not a test".
"""
import argparse
import json
import logging
import os
import re
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import Any, Dict, List, Optional, Set, Tuple

APEX_TYPES: Set[str] = {"apexclass", "apextrigger"}
NS_URI = "http://soap.sforce.com/2006/04/metadata"
NS = {"sforce": NS_URI}
ET.register_namespace("", NS_URI)

logging.basicConfig(level=logging.DEBUG, format="%(message)s")


# ── Argument parsing ──────────────────────────────────────────────────────────

def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Determine required Apex tests for a Salesforce package manifest."
    )
    parser.add_argument("-x", "--manifest", default="manifest/package.xml")
    parser.add_argument("-s", "--stage", default="deploy")
    parser.add_argument("-e", "--environment", default=None)
    parser.add_argument(
        "-c",
        "--cmt-tests-config",
        default="package_check_cmt_tests.json",
        help="JSON rules file for CMT-driven test overrides",
    )
    return parser.parse_args()


# ── Package parsing ───────────────────────────────────────────────────────────

def parse_package(package_path: str) -> Optional[ET.Element]:
    """Parse package.xml and return the root element, or None when no types are present."""
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
    """Collect all <members> values for a given metadata type across all <types> blocks."""
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
    """Strip consumerKey from each ConnectedApp metadata file before deploy."""
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


# ── CMT-driven test overrides ─────────────────────────────────────────────────

def cmt_record_in_package(root: ET.Element, qualified_name: str) -> bool:
    return qualified_name in get_metadata_members_by_type(root, "CustomMetadata")


def cmt_qualified_name_to_paths(qualified_name: str) -> Tuple[str, str, str]:
    if "." not in qualified_name:
        raise ValueError(f"Invalid cmt_record_qualified_name: {qualified_name!r} (expected Type.Name)")
    type_label, developer_name = qualified_name.split(".", 1)
    return (
        f"{type_label}__mdt",
        developer_name,
        f"force-app/main/default/customMetadata/{type_label}.{developer_name}.md-meta.xml",
    )


def parse_switch_field_from_cmt_file(file_path: str, field_api: str) -> bool:
    tree = ET.parse(file_path)
    for elem in tree.getroot().iter():
        if not elem.tag.endswith("values"):
            continue
        field_text = value_text = None
        for sub in elem:
            tag = sub.tag.split("}")[-1]
            if tag == "field" and sub.text:
                field_text = sub.text.strip()
            elif tag == "value" and sub.text is not None:
                value_text = sub.text.strip().lower()
        if field_text == field_api:
            return value_text in ("true", "1")
    logging.warning("%s not found in %s; treating switch as off.", field_api, file_path)
    return False


def soql_string_literal(value: str) -> str:
    return value.replace("'", "''")


def resolve_sf_executable() -> Optional[str]:
    for name in ("sf", "sf.cmd", "sf.exe"):
        path = shutil.which(name)
        if path:
            return path
    return None


def query_org_cmt_switch_field(object_api: str, developer_name: str, field_api: str) -> bool:
    sf_exe = resolve_sf_executable()
    if not sf_exe:
        logging.error("ERROR: sf CLI not found on PATH.")
        sys.exit(1)
    soql = f"SELECT {field_api} FROM {object_api} WHERE DeveloperName = '{soql_string_literal(developer_name)}'"
    try:
        proc = subprocess.run(
            [sf_exe, "data", "query", "-q", soql, "--json"],
            capture_output=True, text=True, timeout=120, check=False,
        )
    except subprocess.TimeoutExpired:
        logging.error("ERROR: sf data query timed out for %s.%s", object_api, developer_name)
        sys.exit(1)
    try:
        data = json.loads(proc.stdout or "{}")
    except json.JSONDecodeError:
        logging.error("ERROR: Invalid JSON from sf data query.")
        sys.exit(1)
    if proc.returncode != 0 or data.get("status") != 0:
        err = (data.get("message") or proc.stderr or proc.stdout or "unknown")[:800]
        logging.error("ERROR: sf data query failed: %s", err)
        sys.exit(1)
    records = (data.get("result") or {}).get("records") or []
    if not records:
        logging.info("No %s row for DeveloperName=%s; treating switch as off.", object_api, developer_name)
        return False
    val = records[0].get(field_api)
    if isinstance(val, bool):
        return val
    return str(val).lower() in ("true", "1", "yes") if val is not None else False


def resolve_cmt_switch_enabled(root: ET.Element, rule: Dict[str, Any]) -> bool:
    qname = rule["cmt_record_qualified_name"]
    field_api = rule.get("switch_field") or "Turn_on__c"
    object_api, developer_name, rel_path = cmt_qualified_name_to_paths(qname)
    if rule.get("cmt_object_api_name"):
        object_api = rule["cmt_object_api_name"]
    if rule.get("cmt_developer_name"):
        developer_name = rule["cmt_developer_name"]
    if cmt_record_in_package(root, qname):
        if os.path.isfile(rel_path):
            logging.info("CMT %s in package; reading %s from %s", qname, field_api, rel_path)
            return parse_switch_field_from_cmt_file(rel_path, field_api)
        logging.info("CMT %s in package but file missing; querying org.", qname)
        return query_org_cmt_switch_field(object_api, developer_name, field_api)
    logging.info("CMT %s not in package; querying org.", qname)
    return query_org_cmt_switch_field(object_api, developer_name, field_api)


def load_cmt_rules(config_path: str) -> List[Dict[str, Any]]:
    if not config_path or not os.path.isfile(config_path):
        logging.warning("WARNING: CMT tests config not found: %s", config_path)
        return []
    try:
        with open(config_path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except json.JSONDecodeError as e:
        logging.error("ERROR: Invalid JSON in %s: %s", config_path, e)
        sys.exit(1)
    rules = data.get("rules") or data.get("cmt_switch_rules")
    if not rules:
        return []
    out: List[Dict[str, Any]] = []
    for i, rule in enumerate(rules):
        required = ("apex_type", "apex_name", "cmt_record_qualified_name", "tests_when_enabled", "tests_when_disabled")
        missing = [k for k in required if not rule.get(k)]
        if missing:
            logging.error("ERROR: CMT rule #%s missing keys: %s", i, missing)
            sys.exit(1)
        t = rule["apex_type"].strip().lower()
        if t not in ("apexclass", "apextrigger"):
            logging.error("ERROR: CMT rule #%s apex_type must be ApexClass or ApexTrigger, got %r", i, rule["apex_type"])
            sys.exit(1)
        rule["_apex_type_norm"] = t
        out.append(rule)
    return out


def _tests_value_to_string(val: Any) -> str:
    return " ".join(str(x) for x in val) if isinstance(val, list) else str(val).strip()


def clean_test_class_names(test_line: str, context: str) -> str:
    out = []
    for name in re.sub(r"[\s,]+", " ", test_line.strip()).split():
        if name.lower().endswith(".cls"):
            logging.warning("WARNING: Auto-removing .cls from '%s' (%s)", name, context)
            name = name[:-4]
        out.append(name)
    return " ".join(out)


def build_cmt_test_overrides(
    root: ET.Element, stage: str, rules: List[Dict[str, Any]]
) -> Tuple[Dict[str, str], Dict[str, str]]:
    ov_class: Dict[str, str] = {}
    ov_trigger: Dict[str, str] = {}
    if stage == "destroy" or not rules:
        return ov_class, ov_trigger
    apex_classes = set(get_metadata_members_by_type(root, "ApexClass"))
    apex_triggers = set(get_metadata_members_by_type(root, "ApexTrigger"))
    for rule in rules:
        aname, atype = rule["apex_name"], rule["_apex_type_norm"]
        if atype == "apexclass" and aname not in apex_classes:
            continue
        if atype == "apextrigger" and aname not in apex_triggers:
            continue
        enabled = resolve_cmt_switch_enabled(root, rule)
        raw = rule["tests_when_enabled"] if enabled else rule["tests_when_disabled"]
        tests_str = clean_test_class_names(_tests_value_to_string(raw), aname)
        logging.info("CMT rule %s %s: enabled=%s → tests: %s", atype, aname, enabled, tests_str)
        (ov_class if atype == "apexclass" else ov_trigger)[aname] = tests_str
    return ov_class, ov_trigger


# ── Apex test extraction ───────────────────────────────────────────────────────

def find_apex_tests(file_path: str) -> str:
    try:
        with open(file_path, "r", encoding="utf-8") as f:
            contents = f.read()
    except FileNotFoundError:
        logging.error("ERROR: File not found: %s", file_path)
        sys.exit(1)
    tests: List[str] = []
    if "@istest" in contents.lower():
        tests.append(os.path.splitext(os.path.basename(file_path))[0])
    for match in re.findall(r"@tests\s*:\s*([^\r\n]+)", contents, re.IGNORECASE):
        tests.append(clean_test_class_names(match, file_path))
    if not tests:
        logging.warning("WARNING: No @tests annotation found in %s", file_path)
    return " ".join(tests)


def process_apex_parallel(
    members: List[str],
    apex_type: str,
    test_set: Set[str],
    overrides: Dict[str, str],
) -> Set[str]:
    directory = "classes" if apex_type == "apexclass" else "triggers"
    ext = ".cls" if apex_type == "apexclass" else ".trigger"
    max_workers = (os.cpu_count() or 4) * 2
    with ThreadPoolExecutor(max_workers=max_workers) as executor:
        futures: Dict[Any, str] = {}
        for member in members:
            if member in overrides:
                _t = overrides[member]
                futures[executor.submit(lambda t=_t: t)] = member
            else:
                futures[executor.submit(find_apex_tests, f"force-app/main/default/{directory}/{member}{ext}")] = member
        for future in as_completed(futures):
            member = futures[future]
            try:
                found = future.result()
                if found:
                    test_set.update(found.split())
            except Exception as exc:
                logging.error("ERROR: Processing %s: %s", member, exc)
                sys.exit(1)
    return test_set


def validate_tests(test_set: Set[str]) -> str:
    valid = [t for t in test_set if os.path.isfile(f"force-app/main/default/classes/{t}.cls")]
    for t in test_set - set(valid):
        logging.warning("WARNING: %s is not a valid test class in this project.", t)
    if not valid:
        logging.error("ERROR: None of the test annotations resolve to valid test classes.")
        sys.exit(1)
    return " ".join(valid)


def determine_destructive_tests(deleted_apex: Optional[Set[str]] = None) -> str:
    """Return Apex tests for production destructive deploys from the DESTRUCTIVE_TESTS env var."""
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


# ── Main scan ────────────────────────────────────────────────────────────────

def process_metadata_type(
    root: ET.Element, stage: str, cmt_rules: List[Dict[str, Any]]
) -> Tuple[bool, Set[str]]:
    """Iterate package types, strip ConnectedApp keys, collect Apex test classes."""
    apex_required = False
    test_set: Set[str] = set()
    ov_class, ov_trigger = build_cmt_test_overrides(root, stage, cmt_rules)
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
            if stage != "destroy":
                overrides = ov_class if metadata_name.lower() == "apexclass" else ov_trigger
                test_set = process_apex_parallel(members, metadata_name.lower(), test_set, overrides)
    return apex_required, test_set


def scan_package(package_path: str, stage: str, env: str, cmt_config_path: str) -> str:
    root = parse_package(package_path)
    if root is None:
        return "not a test"
    cmt_rules = load_cmt_rules(cmt_config_path)
    apex_required, test_set = process_metadata_type(root, stage, cmt_rules)
    if apex_required and stage != "destroy":
        logging.info("Apex tests required.")
        return validate_tests(test_set)
    if apex_required and stage == "destroy" and (env or "").lower() == "production":
        logging.info("Apex tests required for production destructive deploy.")
        deleted_apex = (
            set(get_metadata_members_by_type(root, "ApexClass"))
            | set(get_metadata_members_by_type(root, "ApexTrigger"))
        )
        return determine_destructive_tests(deleted_apex)
    logging.info("Apex tests not required.")
    return "not a test"


def main() -> None:
    args = parse_args()
    result = scan_package(args.manifest, args.stage, args.environment, args.cmt_tests_config)
    logging.info(result)
    print(result)


if __name__ == "__main__":
    main()
