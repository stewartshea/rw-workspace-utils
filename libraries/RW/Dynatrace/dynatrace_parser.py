# dynatrace_parser.py
from __future__ import annotations
import json, re
from typing import Any, Dict, List, Set


CLEAN_SUFFIX_RE = re.compile(r"\s+on port \d+$", re.I)

def _clean(raw: str) -> str:
    """
    Return a tidy Azure-style resource name:
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

    def collect(raw_name: str):
        if not raw_name:
            return
        clean = _clean(raw_name)
        candidates.add(clean)
        # If we shortened the name, keep the raw one **as a fallback** –
        # SLX search will ignore extras it can’t match.
        if clean != raw_name:
            candidates.add(raw_name)

    # 1) Top-level impactedEntities (your original example)
    for ent in payload.get("impactedEntities", []):
        collect(ent.get("name"))

    # 2) Full JSON details → impactedEntities / affectedEntities / rootCauseEntity
    details = payload.get("problemDetailsJson", {})
    for ent in details.get("impactedEntities", []):
        collect(ent.get("name"))
    for ent in details.get("affectedEntities", []):
        collect(ent.get("name"))
    rc = details.get("rootCauseEntity")
    if rc:
        collect(rc.get("name"))

    # 3) Impact analysis block
    for imp in details.get("impactAnalysis", {}).get("impacts", []):
        ie = imp.get("impactedEntity", {})
        collect(ie.get("name"))

    # 4) evidenceDetails – sometimes additional groupingEntity names
    for ev in details.get("evidenceDetails", {}).get("details", []):
        collect(ev.get("groupingEntity", {}).get("name"))
        collect(ev.get("entity", {}).get("name"))

    # Guarantee deterministic order (original insertion order*)
    ordered = [n for n in candidates if n]            # remove empty
    ordered.sort(key=lambda x: (len(x), x))           # shorter first (likely clean)
    return ordered
