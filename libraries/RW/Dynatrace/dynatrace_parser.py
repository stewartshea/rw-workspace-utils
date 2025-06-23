# dynatrace_parser.py
from __future__ import annotations
import json
import re
from typing import Any, Dict, List, Set

CLEAN_SUFFIX_RE = re.compile(r"\s+on port \d+$", re.I)

def _clean(raw: str) -> str:
    """
    Return a tidy resource name:
    • strips “ on port ####”
    • if Dynatrace used a long prefix ‘… – name’, keep only last token
    • trims whitespace
    """
    name = CLEAN_SUFFIX_RE.sub("", raw).strip()
    if " - " in name:
        name = name.split(" - ")[-1].strip()
    return name

def parse_dynatrace_entities(payload: str | Dict[str, Any]) -> List[str]:
    """Return a unique list of cleaned entity names (best-guess order)."""
    if isinstance(payload, str):
        payload = json.loads(payload)

    candidates: Set[str] = set()

    def collect(raw_name: str | None):
        if not raw_name:
            return
        clean = _clean(raw_name)
        candidates.add(clean)
        if clean != raw_name:
            candidates.add(raw_name)

    # 1) Top-level 'impactedEntities'
    for ent in payload.get("impactedEntities", []):
        collect(ent.get("name"))

    # 2) Full JSON details
    details = payload.get("problemDetailsJSON", {})
    for ent in details.get("impactedEntities", []):
        collect(ent.get("name"))
    for ent in details.get("affectedEntities", []):
        collect(ent.get("name"))
    rc = details.get("rootCauseEntity")
    if isinstance(rc, dict):
        collect(rc.get("name"))

    # 3) Impact analysis block
    for imp in details.get("impactAnalysis", {}).get("impacts", []):
        ie = imp.get("impactedEntity") or {}
        collect(ie.get("name"))

    # 4) Evidence details
    for ev in details.get("evidenceDetails", {}).get("details", []):
        # groupingEntity may be null
        grouping = ev.get("groupingEntity") or {}
        collect(grouping.get("name"))

        # entity may always exist, but guard anyway
        entity = ev.get("entity") or {}
        collect(entity.get("name"))

    # 5) Any stringRepresentation tags (optional)
    for tag in details.get("entityTags", []):
        collect(tag.get("stringRepresentation"))

    # Deterministic order: shorter names first (likely “clean”)
    ordered = [n for n in candidates if n]
    ordered.sort(key=lambda x: (len(x), x))
    return ordered
