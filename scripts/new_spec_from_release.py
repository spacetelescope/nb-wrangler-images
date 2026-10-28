#!/usr/bin/env python3
"""Create a wrangler spec for a roman_notebooks release from the latest one.

Used by the roman_notebooks delivery workflow so releases do not need a human
to copy and hand-edit a spec.  The new spec starts from the newest
specs/roman/RomanNexus-<calver>.yaml, changes only the identity fields and the
roman_notebooks ref, and leaves everything else (packages, data, `out:`) alone.
`curate.yml` runs `--spec-reset` first, so stale `out:` pins are discarded there.

  calver:  <prefix>-2026.2.4.yaml   (kernel <prefix>-2026.2)
  semver:  <prefix>-dev.yaml        (moving dev channel, never a release)

The prefix is RomanNexus for real releases.  A proving-ground repo passes a
different one so its images and specs can never carry a release name.

Anything the spec downloads from nb-wrangler-images itself (post-start hook,
server extensions) is pinned to --assets-ref when given, so a push to that
repo's main cannot change what an already-generated release builds.

Requires: pip install ruamel.yaml  (keeps comments and key order)
"""
import argparse
import datetime as dt
import re
import sys
from pathlib import Path

from ruamel.yaml import YAML
from ruamel.yaml.scalarstring import SingleQuotedScalarString as Q

CALVER = re.compile(r"^(\d{4})\.(\d+)\.(\d+)$")
SEMVER = re.compile(r"^v\d+\.\d+\.\d+$")
SPEC_NAME = re.compile(r"^RomanNexus-(\d{4})\.(\d+)\.(\d+)\.yaml$")
PREFIX = re.compile(r"^[A-Za-z][A-Za-z0-9]{0,30}$")
SHA = re.compile(r"^[0-9a-f]{40}$")
ASSETS_REPO = "spacetelescope/nb-wrangler-images"
VALID_DAYS = 182  # matches 2026-08-17 -> 2027-02-15 in RomanNexus-2026.2.1


# The template is the highest-numbered RomanNexus-YYYY.M.N.yaml already in specs/roman.
def latest_template(spec_dir: Path) -> Path:
    found = []
    for path in spec_dir.glob("RomanNexus-*.yaml"):
        m = SPEC_NAME.match(path.name)
        if m:
            found.append((tuple(int(g) for g in m.groups()), path))
    if not found:
        sys.exit(f"No RomanNexus-<calver>.yaml template found in {spec_dir}")
    return max(found)[1]


def main() -> None:
    # Command line.
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--spec-dir", required=True, type=Path, help="e.g. specs/roman")
    ap.add_argument("--kind", required=True, choices=["calver", "semver"])
    ap.add_argument("--version", required=True, help="2026.2.4 or v0.0.70")
    ap.add_argument("--ref", required=True, help="roman_notebooks tag or SHA to pin")
    ap.add_argument("--notebooks-url", help="override repositories.roman_notebooks.url")
    ap.add_argument("--template", type=Path, help="default: newest RomanNexus-<calver>.yaml")
    ap.add_argument("--name-prefix", default="RomanNexus", help="image and kernel name prefix (default RomanNexus)")
    ap.add_argument("--assets-ref", help="40-character commit SHA to pin nb-wrangler-images assets to")
    ap.add_argument("--today", help="YYYY-MM-DD, for reproducible output/tests")
    args = ap.parse_args()

    # Validate everything that ends up in a file name or in the spec before using it.
    if not PREFIX.match(args.name_prefix):
        sys.exit(f"Invalid name prefix: {args.name_prefix}")
    if args.assets_ref and not SHA.match(args.assets_ref):
        sys.exit(f"--assets-ref must be a 40-character lowercase commit SHA: {args.assets_ref}")
    prefix = args.name_prefix

    # Derive the names. A CalVer release gets its own permanent spec; the dev channel reuses one.
    if args.kind == "calver":
        m = CALVER.match(args.version)
        if not m:
            sys.exit(f"Not a CalVer version: {args.version}")
        year, major = m.group(1), m.group(2)
        image_name = f"{prefix}-{args.version}"
        kernel_name = f"{prefix}-{year}.{major}"
        display = f"Roman Research Nexus {year}.{major}"
        description = f"Roman Research Nexus release {args.version}\n"
    else:
        if not SEMVER.match(args.version):
            sys.exit(f"Not a SemVer tag: {args.version}")
        image_name = kernel_name = f"{prefix}-dev"
        display = "Roman Research Nexus (dev)"
        description = f"Development channel, roman_notebooks {args.version}\n"

    # Load the template.
    template = args.template or latest_template(args.spec_dir)
    out = args.spec_dir / f"{image_name}.yaml"
    # A release spec is a permanent record; only the moving dev-channel spec
    # may be regenerated in place.
    if out.exists() and args.kind == "calver":
        sys.exit(f"Refusing to overwrite existing spec: {out}")

    # ruamel.yaml rather than PyYAML: it keeps comments, quoting and key order, so the new spec diffs cleanly against the old one.
    yaml = YAML()
    yaml.preserve_quotes = True
    yaml.width = 4096
    yaml.indent(mapping=2, sequence=4, offset=2)
    data = yaml.load(template.read_text(encoding="utf-8"))

    # Identity fields: names, dates and the notebooks commit being delivered. Everything else is left as it was.
    today = dt.date.fromisoformat(args.today) if args.today else dt.datetime.now(dt.timezone.utc).date()
    header = data["image_spec_header"]
    header["image_name"] = image_name
    header["kernel_name"] = kernel_name
    header["display_name"] = display
    header["description"] = description
    header["valid_on"] = Q(today.isoformat())
    header["expires_on"] = Q((today + dt.timedelta(days=VALID_DAYS)).isoformat())

    repo = data["repositories"]["roman_notebooks"]
    repo["ref"] = Q(args.ref)
    if args.notebooks_url:
        repo["url"] = args.notebooks_url

    # Pin what the spec downloads from nb-wrangler-images (hook scripts, server extensions) to one commit.
    if args.assets_ref:
        pinned = 0
        for asset in data.get("assets") or []:
            if ASSETS_REPO in str(asset.get("repo", "")):
                asset["ref"] = Q(args.assets_ref)
                pinned += 1
        if pinned == 0:
            sys.exit(f"--assets-ref given but no assets from {ASSETS_REPO} found in the template")

    # Release specs must be reproducible: dev overrides stay switched off.
    if "dev_overrides" in data:
        keys = list(data.keys())
        data.insert(keys.index("dev_overrides"), "deactivated_dev_overrides", data["dev_overrides"])
        del data["dev_overrides"]

    # LF line endings, so the output is identical on every platform.
    with out.open("w", encoding="utf-8", newline="\n") as fh:
        yaml.dump(data, fh)
    # The caller learns the file name from this.
    print(out)


if __name__ == "__main__":
    main()
