"""
signal_tree.py

Cross-references netlist.NET (actual net -> pin connectivity, exported from
Altium) with PortHarnessSignals.txt (which signal names are Ports/Harness
entries, on which schematic sheets they were placed, and each one's resolved
compiled PHYSICAL net name -- written by ExtractPortAndHarnessSignals.pas as
a "[Net: <name>]" annotation) to render a per-signal connectivity tree -- the
Python equivalent of the old DelphiScript "Signal Tree" section, but backed
by the real netlist instead of geometric wire-tracing.

Matching a signal to its netlist.NET entry is an EXACT string match against
the physical net name Altium itself resolved -- no normalization/fuzzy
matching, since the whole point of the "[Net: ...]" annotation is that it is
already the real net name (as opposed to this script's own display name,
which may be an auto-generated "<PortName>.<EntryName>" that differs from
the real net when a custom net label overrides it).

Each signal's net is then traced pin-to-pin: resistors, capacitors, and
inductors (designators R/C/L) are treated as jumpers -- a series passive
doesn't terminate a signal, it just hops it onto the net on its other side
-- so the report follows straight through them to the real endpoint (an IC
or connector pin). Whenever that trace runs straight into a supply or
ground net (by name, e.g. GND/VCC/+12), it's reported as a Pull-Up (PU) or
Pull-Down (PD) rather than followed further, since a rail net fans out to
the rest of the board and isn't part of this signal.

Usage:
    python signal_tree.py [--netlist PATH] [--ports-report PATH] [--out PATH]

By default all three paths are resolved next to this script.
"""

import argparse
import re
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent


def parse_netlist(path):
    """Returns (nets, pin_meta):
      nets      -- {net_name: [ "RefDes-Pin", ... ]}
      pin_meta  -- {"RefDes-Pin": {"function": str or None, "type": str or None}},
                   function is the pin's name off the netlist's own
                   pin-description field (e.g. "CANH", "P1_1", or just "2"
                   for a pin with no more descriptive name than its number).

    Only the "(  NetName  \\n  RefDes-Pin PinDesc PinType  ...  \\n  )" net
    blocks are read; the "[ ... ]" component blocks are skipped entirely --
    see parse_component_values() for those.
    """
    nets = {}
    pin_meta = {}
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    i, n = 0, len(lines)
    while i < n:
        if lines[i].strip() == "(":
            i += 1
            net_name = lines[i].strip()
            i += 1
            pins = []
            while i < n and lines[i].strip() != ")":
                token = lines[i].strip()
                if token:
                    parts = token.split()
                    pin_id = parts[0]  # "RefDes-Pin" is the first field
                    pins.append(pin_id)
                    function = parts[1].rsplit("-", 1)[-1] if len(parts) > 1 else None
                    pin_meta[pin_id] = {
                        "function": function,
                        "type": parts[2] if len(parts) > 2 else None,
                    }
                i += 1
            nets[net_name] = pins
        i += 1
    return nets, pin_meta


def parse_component_values(path):
    """Returns {refdes: value} for every component in the netlist, value
    being the component's value token (e.g. "0R", "2k") read off the
    "DESCRIPTION" field of its "[ ... ]" block ("RES 2k 1% ..." -> "2k").
    Best-effort: a component missing either field is simply absent from
    the result.
    """
    values = {}
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    i, n = 0, len(lines)
    while i < n:
        if lines[i].strip() == "[":
            i += 1
            block = []
            while i < n and lines[i].strip() != "]":
                block.append(lines[i])
                i += 1
            designator = None
            value = None
            for j, line in enumerate(block[:-1]):
                if line.strip() == "DESIGNATOR":
                    designator = block[j + 1].strip()
                elif line.strip() == "DESCRIPTION":
                    desc_parts = block[j + 1].strip().split()
                    if len(desc_parts) > 1:
                        value = desc_parts[1]
            if designator and value:
                values[designator] = value
        i += 1
    return values


SHEET_RE = re.compile(r"^=== Sheet: (.+?) ===$")
PORT_LINE_RE = re.compile(r"^    - (.+)$")
HARNESS_ENTRY_RE = re.compile(r"^        (.+)$")
NET_SUFFIX_RE = re.compile(r"\s*\[Net: (.*?)\]\s*$")


def _split_net_suffix(text):
    """Splits a trailing '   [Net: <value>]' off text. Returns (rest, value),
    value is None if there was no such suffix, or if it read '(unresolved)'.
    """
    m = NET_SUFFIX_RE.search(text)
    if not m:
        return text, None
    value = m.group(1)
    if value == "(unresolved)":
        value = None
    return text[: m.start()], value


def parse_port_harness_report(path):
    """Returns a list of (signal_name, sheet, tag, physical_net) occurrences,
    tag in {'Port', 'Harness'}, physical_net is the resolved compiled net name
    (or None if the script itself couldn't resolve one for that occurrence).
    """
    occurrences = []
    sheet = None
    section = None  # 'ports' | 'harness' | None

    for raw_line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        m = SHEET_RE.match(raw_line)
        if m:
            sheet = m.group(1)
            section = None
            continue

        stripped = raw_line.strip()
        if stripped == "Ports:":
            section = "ports"
            continue
        if stripped == "Harness connectors:":
            section = "harness"
            continue

        if section == "ports":
            m = PORT_LINE_RE.match(raw_line)
            if m and not m.group(1).startswith("(none)"):
                rest, physical_net = _split_net_suffix(m.group(1))
                # A "(signal-harness port, harness type: X)" entry is the
                # harness connector root itself, not a real wire -- it never
                # lands on a specific pin (its individual signals are each
                # covered by their own Harness entry below), so it doesn't
                # belong in the per-signal tree.
                if "(signal-harness port" in rest:
                    continue
                name = re.split(r"\s{2,}|\(", rest, maxsplit=1)[0].strip()
                occurrences.append((name, sheet, "Port", physical_net))
        elif section == "harness":
            # An 8-space-indented line is an individual harness signal
            # ("CAN0.TX"); a 4-space "    - PortName (Type X)" line is just
            # the connector header and is already covered by its Port entry.
            if HARNESS_ENTRY_RE.match(raw_line) and not PORT_LINE_RE.match(raw_line):
                rest, physical_net = _split_net_suffix(raw_line.strip())
                name = rest.strip()
                if name and name != "(no entries)":
                    occurrences.append((name, sheet, "Harness", physical_net))

    return occurrences


def build_signal_tree(occurrences, nets):
    # Two occurrences are the same signal if they share a display name
    # (case-insensitively) OR they share a resolved physical net -- the net
    # is ground truth (it's what Altium itself resolved), so it must be able
    # to merge two occurrences whose display names differ, which happens
    # whenever a custom net label overrides the auto-generated
    # "<PortName>.<EntryName>" name on only one of the sheets (e.g. a
    # harness entry displayed as "CAN0.RX" on one sheet and "CAN0_RX" on
    # another, both resolving to the same physical net). Union-find merges
    # transitively across both keys.
    parent = list(range(len(occurrences)))

    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    def union(a, b):
        ra, rb = find(a), find(b)
        if ra != rb:
            parent[ra] = rb

    first_by_name = {}
    first_by_net = {}
    for i, (name, sheet, tag, physical_net) in enumerate(occurrences):
        name_key = name.upper()
        if name_key in first_by_name:
            union(i, first_by_name[name_key])
        else:
            first_by_name[name_key] = i
        if physical_net:
            if physical_net in first_by_net:
                union(i, first_by_net[physical_net])
            else:
                first_by_net[physical_net] = i

    grouped = {}
    for i, (name, sheet, tag, physical_net) in enumerate(occurrences):
        entry = grouped.setdefault(find(i), {"names": [], "sheets": [], "nets": []})
        if name not in entry["names"]:
            entry["names"].append(name)
        if sheet not in entry["sheets"]:
            entry["sheets"].append(sheet)
        if physical_net and physical_net not in entry["nets"]:
            entry["nets"].append(physical_net)

    rows = []
    for entry in grouped.values():
        entry["sheets"].sort()
        entry["names"].sort(key=str.upper)
        rows.append(
            {
                "names": entry["names"],
                "sheets": entry["sheets"],
                "nets": entry["nets"],
                "pins": {net: nets.get(net) for net in entry["nets"]},
            }
        )
    rows.sort(key=lambda r: r["names"][0].upper())
    return rows


JUMPER_DESIGNATOR_RE = re.compile(r"^[RCL]\d+[A-Za-z]*$")

# Net-name heuristics for rail classification -- there's no netlist field
# that says "this is GND" or "this is a supply", so this matches common
# schematic naming conventions instead (GND/AGND/VSS..., VCC/VDD/+12/+3V3...).
GND_NET_RE = re.compile(r"^(A|D)?GND\d*$|^V(SS|EE)\d*$", re.IGNORECASE)
PWR_NET_RE = re.compile(
    r"^(V(CC|DD|BAT|IN|OUT|BUS|PP|REF|LOGIC)\d*|[+-]\d+(\.\d+)?V?\d*|\d+(\.\d+)?V\d*)$",
    re.IGNORECASE,
)


def classify_rail(net_name):
    """Returns 'GND', 'PWR', or None for a net name, by naming convention."""
    if GND_NET_RE.match(net_name):
        return "GND"
    if PWR_NET_RE.match(net_name):
        return "PWR"
    return None


def is_jumper_pin(pin_id):
    """A resistor/capacitor/inductor is treated as a jumper (series
    pass-through) rather than a real signal endpoint -- its designator
    (R/C/L + digits) is the only reliable signal for this in a netlist."""
    refdes = pin_id.split("-", 1)[0]
    return bool(JUMPER_DESIGNATOR_RE.match(refdes))


def build_jumper_edges(nets):
    """Returns {net_name: [(other_net, refdes), ...]} -- for every two-pin
    R/C/L component whose both pins land in the netlist, an edge bridging
    the nets on either side of it, labelled with the component's refdes.
    Components with any other pin count (should not happen for R/C/L, but
    a netlist can always surprise you) are skipped rather than guessed at.
    """
    pins_by_refdes = {}
    net_of_pin = {}
    for net_name, pins in nets.items():
        for pin_id in pins:
            net_of_pin[pin_id] = net_name
            refdes = pin_id.split("-", 1)[0]
            if is_jumper_pin(pin_id):
                pins_by_refdes.setdefault(refdes, []).append(pin_id)

    edges = {}
    for refdes, pins in pins_by_refdes.items():
        if len(pins) != 2:
            continue
        net_a, net_b = net_of_pin[pins[0]], net_of_pin[pins[1]]
        if net_a == net_b:
            continue
        edges.setdefault(net_a, []).append((net_b, refdes))
        edges.setdefault(net_b, []).append((net_a, refdes))
    return edges


def trace_signal_path(start_net, nets, edges_by_net):
    """Walks outward from start_net across any R/C/L jumpers, returning:
      endpoints  -- sorted list of every non-jumper pin reached (i.e. where
                    the signal actually lands -- ICs, connectors, etc.)
      jumpers    -- sorted list of refdes for every jumper component crossed
      pull_hits  -- list of (refdes, 'PU'|'PD', rail_net) for every jumper
                    that leads straight to a supply or ground net -- a rail
                    net is a dead end for tracing (it fans out to the rest
                    of the board, not this signal), so it's reported but not
                    explored further.
    """
    visited_nets = {start_net}
    endpoints = set()
    jumpers = set()
    pull_hits = []
    queue = [start_net]
    while queue:
        net = queue.pop(0)
        for pin_id in nets.get(net, []):
            if not is_jumper_pin(pin_id):
                endpoints.add(pin_id)
        for other_net, refdes in edges_by_net.get(net, []):
            if other_net in visited_nets:
                continue
            visited_nets.add(other_net)
            rail = classify_rail(other_net)
            jumpers.add(refdes)
            if rail:
                pull_hits.append((refdes, "PU" if rail == "PWR" else "PD", other_net))
            else:
                queue.append(other_net)
    return sorted(endpoints), sorted(jumpers), pull_hits


def pin_label(pin_id, pin_meta):
    function = pin_meta.get(pin_id, {}).get("function") or pin_id.rsplit("-", 1)[-1]
    return f"{pin_id} [{function}]"


def render_report(rows, netlist_path, report_path, nets, edges_by_net, pin_meta, component_values):
    lines = []
    lines.append("Signal Tree")
    lines.append(f"Netlist       : {netlist_path}")
    lines.append(f"Ports report  : {report_path}")
    lines.append("-" * 70)

    for row in rows:
        # Prefer the resolved physical net as the headline -- it's the
        # ground truth -- falling back to the first display name when the
        # net is unresolved or mismatched. The local display names (which
        # may differ per sheet, e.g. a custom net label override) are
        # listed in brackets whenever there's more than one of them.
        header = row["nets"][0] if len(row["nets"]) == 1 else row["names"][0]
        if len(row["names"]) > 1:
            header += "  [" + ", ".join(row["names"]) + "]"
        lines.append(f"  {header}")
        lines.append(f"      Sheets: {', '.join(row['sheets'])}")

        if not row["nets"]:
            lines.append("      Net: (unresolved -- see ExtractPortAndHarnessSignals.pas output)")
        elif len(row["nets"]) > 1:
            lines.append(f"      Net: MISMATCH across sheets -- {', '.join(row['nets'])}")
        else:
            net = row["nets"][0]
            pins = row["pins"][net]
            if pins is None:
                lines.append("      Pins: (net not found in netlist.NET)")
            else:
                # Trace through any resistor/capacitor/inductor jumpers to
                # find where the signal actually lands -- a series R/C/L
                # doesn't break the signal path, it just hops it onto
                # another net, so the real endpoint is on the far side.
                # Endpoints are numbered independently of Sheets above: the
                # netlist has no record of which schematic sheet a component
                # like J1 or U1 is drawn on, only which sheet the port LABEL
                # sat on -- so the two lists can't be reliably paired up.
                endpoints, jumpers, pull_hits = trace_signal_path(net, nets, edges_by_net)
                if endpoints:
                    for idx, pin_id in enumerate(endpoints, start=1):
                        lines.append(f"      SIGNAL_{idx}: {pin_label(pin_id, pin_meta)}")
                else:
                    lines.append("      (no endpoint pins found)")

                def _comps(refdes_list):
                    return ", ".join(
                        f"{refdes} ({component_values[refdes]})" if component_values.get(refdes) else refdes
                        for refdes in refdes_list
                    )

                pull_groups = {}
                for refdes, kind, rail in pull_hits:
                    pull_groups.setdefault((kind, rail), []).append(refdes)
                for (kind, rail), refdes_list in sorted(
                    pull_groups.items(), key=lambda kv: (kv[0][0] != "PU", kv[0][1])
                ):
                    label = f"Pull-Up ({rail})  " if kind == "PU" else f"Pull-Down ({rail})"
                    lines.append(f"      {label}: {_comps(refdes_list)}")

                # A resistor/cap/inductor that dead-ends into a rail is a
                # pull-up/pull-down, not a signal pass-through -- it's
                # already reported above, so it's excluded here.
                pull_refdes = {refdes for refdes, _, _ in pull_hits}
                series = [refdes for refdes in jumpers if refdes not in pull_refdes]
                if series:
                    lines.append(f"      Series components: {_comps(series)}")

    lines.append("-" * 70)
    lines.append(f"Signals total       : {len(rows)}")
    lines.append(f"Signals with a net  : {sum(1 for r in rows if len(r['nets']) == 1)}")
    lines.append(f"Signals unresolved  : {sum(1 for r in rows if not r['nets'])}")
    lines.append(f"Signals mismatched  : {sum(1 for r in rows if len(r['nets']) > 1)}")
    lines.append(
        f"Signals cross-sheet : {sum(1 for r in rows if len(r['sheets']) > 1)}"
    )
    return "\n".join(lines) + "\n"


def resolve_netlist_path(explicit_path):
    """Returns the netlist path to use: the explicit --netlist value if one
    was given, otherwise the sole *.NET file found next to this script. Exits
    with an error message if zero or multiple candidates are found, since
    there's no reliable way to guess which one the user means.
    """
    if explicit_path is not None:
        return explicit_path

    candidates = sorted(SCRIPT_DIR.glob("*.NET")) + sorted(SCRIPT_DIR.glob("*.net"))
    # De-duplicate in case a case-insensitive filesystem matched both globs
    # to the same file.
    seen = set()
    unique_candidates = []
    for candidate in candidates:
        if candidate not in seen:
            seen.add(candidate)
            unique_candidates.append(candidate)

    if len(unique_candidates) == 1:
        return unique_candidates[0]
    if not unique_candidates:
        raise SystemExit(
            f"No .NET file found in {SCRIPT_DIR}. Pass one explicitly with --netlist."
        )
    listing = "\n".join(f"  - {c.name}" for c in unique_candidates)
    raise SystemExit(
        f"Multiple .NET files found in {SCRIPT_DIR}; pass one explicitly with --netlist:\n{listing}"
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--netlist", type=Path, default=None,
        help="Path to the Protel netlist (.NET) file "
             "(default: auto-detect the sole *.NET file next to this script)",
    )
    parser.add_argument(
        "--ports-report", type=Path, default=SCRIPT_DIR / "PortHarnessSignals.txt",
        help="Path to PortHarnessSignals.txt",
    )
    parser.add_argument(
        "--out", type=Path, default=SCRIPT_DIR / "SignalTree.txt",
        help="Output report path",
    )
    args = parser.parse_args()
    args.netlist = resolve_netlist_path(args.netlist)

    nets, pin_meta = parse_netlist(args.netlist)
    edges_by_net = build_jumper_edges(nets)
    component_values = parse_component_values(args.netlist)
    occurrences = parse_port_harness_report(args.ports_report)
    rows = build_signal_tree(occurrences, nets)
    report = render_report(
        rows, args.netlist, args.ports_report, nets, edges_by_net, pin_meta, component_values
    )

    args.out.write_text(report, encoding="utf-8")
    print(report)
    print(f"Saved to {args.out}")


if __name__ == "__main__":
    main()
