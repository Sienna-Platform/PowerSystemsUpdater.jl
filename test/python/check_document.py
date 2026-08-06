"""Validate a PSY6 system.json against the generated pydantic models.

Exits non-zero on any failure. Fails on a vacuous document so an empty
`components` map cannot produce a green result.
"""
import argparse
import importlib
import json
import sys

DOMAINS = ("core", "operations", "investments", "dynamics")

# From SiennaSchemas/Core/SystemDocument.json. `name`, `description` and
# `frequency` are optional; everything here is required.
REQUIRED_KEYS = {
    "base_power",
    "unit_system",
    "components",
    "supplemental_attributes",
    "supplemental_attribute_associations",
    "time_series_associations",
    "ext",
    "time_series_storage_file",
}


def load_registry():
    registry = {}
    for domain in DOMAINS:
        module = importlib.import_module(f"power_openapi_models.{domain}.models")
        for attr in dir(module):
            obj = getattr(module, attr)
            if isinstance(obj, type) and hasattr(obj, "model_fields"):
                registry.setdefault(attr, obj)
    return registry


def strip_none(value):
    if isinstance(value, dict):
        return {k: strip_none(v) for k, v in value.items() if v is not None}
    if isinstance(value, list):
        return [strip_none(v) for v in value]
    return value


def check(path):
    with open(path) as handle:
        doc = json.load(handle)

    errors = []
    missing = REQUIRED_KEYS - set(doc)
    if missing:
        errors.append(f"missing required envelope keys: {sorted(missing)}")

    registry = load_registry()
    validated = 0
    for type_name, entries in doc.get("components", {}).items():
        cls = registry.get(type_name)
        if cls is None:
            errors.append(f"no generated model for component type {type_name}")
            continue
        for index, entry in enumerate(entries):
            try:
                model = cls.model_validate(entry)
            except Exception as exc:  # pydantic ValidationError
                errors.append(f"{type_name}[{index}]: {exc}")
                continue
            validated += 1
            # pydantic ignores unknown keys, so a misspelled field would vanish
            # silently. Diff the re-dump to catch it.
            dumped = strip_none(model.model_dump(mode="json", by_alias=True))
            dropped = set(strip_none(entry)) - set(dumped)
            if dropped:
                errors.append(f"{type_name}[{index}]: dropped fields {sorted(dropped)}")

    if validated == 0:
        errors.append("VACUOUS: no components validated")

    return validated, errors


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("path")
    args = parser.parse_args()

    validated, errors = check(args.path)
    for error in errors:
        print(f"FAIL {error}", file=sys.stderr)
    if errors:
        return 1
    print(f"OK {validated} components validated")
    return 0


if __name__ == "__main__":
    sys.exit(main())
