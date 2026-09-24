"""Summarize AI telemetry: shot quality, suppression, positioning, AP use.

    python tools/extract_telemetry.py --all      # refresh the JSONL first
    python tools/analyze_telemetry.py            # campaign only (arena sessions dropped)
    python tools/analyze_telemetry.py --arena    # keep AI-vs-AI arena sessions
    python tools/analyze_telemetry.py --legacy   # also parse old PrintAttack blocks from logs_archive

AP values are displayed AP (GBO3 const.Scale.AP = 100, ~10x vanilla).
"""
import argparse
import collections
import json
import math
import os
import re
import statistics as st

GAME_DIR = os.path.join(os.environ.get("APPDATA", ""), "Jagged Alliance 3")
DEFAULT_IN = os.path.join(GAME_DIR, "RatoTelemetry", "ai_telemetry.jsonl")
ARCHIVE_DIR = os.path.join(GAME_DIR, "RatoTelemetry", "logs_archive")
BUCKETS = ((0, 10), (10, 30), (30, 60), (60, 101))
LOW_CTH = 10
PLAYER_SIDES = ("player1", "player2")


def load(path):
    with open(path, encoding="utf-8") as fh:
        return [json.loads(line) for line in fh if line.strip()]


def arena_sessions(recs):
    """A session where a player side took AI turns is an AI-vs-AI arena run."""
    return {r["sess"] for r in recs if r.get("ev") == "turn" and r.get("side") in PLAYER_SIDES}


def legacy_attacks():
    """Rebuild attack events from Rato Dev PrintAttack blocks, for logs recorded before the attack event existed."""
    out = []
    if not os.path.isdir(ARCHIVE_DIR):
        return out
    for f in sorted(os.listdir(ARCHIVE_DIR)):
        cur = None
        with open(os.path.join(ARCHIVE_DIR, f), encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if "Attack (RatoDev)" in line:
                    cur = {}
                    out.append(cur)
                    continue
                m = re.match(r"-- (.+?)\s+=\s+(.*)", line)
                if m and cur is not None:
                    cur[m.group(1)] = m.group(2).strip()
                elif "last_results" in line:
                    cur = None
    res = []
    for a in out:
        try:
            parts = [p.strip() for p in a.get("Hit part per shot", "").split("|") if p.strip()]
            res.append({
                "ev": "attack", "legacy": True,
                "ai": ":" in a["Attacker"],  # AI session ids look like Squad:Sector:Class:N
                "unit": a["Attacker"], "target": a.get("Target"),
                "action": a["Action ID"], "weapon": a.get("Weapon"),
                "aim": int(a.get("Aim Level", 0)), "dist": int(a.get("Distance", 0)),
                "cth": int(a["Chance to Hit"]),
                "cths": [0] * max(1, len(parts)),
                "hits": sum(1 for p in parts if "miss" not in p),
                "mods": {k[4:]: int(v) for k, v in a.items() if k.startswith("CTH_") and v.lstrip("-").isdigit()},
            })
        except (KeyError, ValueError):
            pass
    return res


def pct(a, b):
    return f"{100 * a / b:.0f}%" if b else "-"


def attacks_report(atks):
    print("\n## Attacks")
    melee = ("HyenaBite", "HyenaCharge", "MeleeAttack", "UnarmedAttack")
    for label, group in (("AI", [a for a in atks if a.get("ai")]), ("player", [a for a in atks if not a.get("ai")])):
        L = [a for a in group if a.get("cth") is not None and a.get("action") not in melee]
        if not L:
            continue
        print(f"\n### {label}: {len(L)} ranged attacks, mean dist {st.mean(a.get('dist') or 0 for a in L):.1f} tiles,"
              f" mean Marksmanship term {st.mean(a['mods'].get('Stat', 0) for a in L):.0f},"
              f" hits/attack {sum(a['hits'] for a in L) / len(L):.2f}")
        print(f"{'CTH':>8} {'attacks':>8} {'bullets':>8} {'hits':>6} {'hits/att':>9}")
        for lo, hi in BUCKETS:
            B = [a for a in L if lo <= a["cth"] < hi]
            bullets = sum(len(a.get("cths") or [0]) for a in B)
            h = sum(a["hits"] for a in B)
            print(f"{lo:>3}-{hi - 1:<4} {len(B):>8} {bullets:>8} {h:>6} {h / len(B) if B else 0:>9.2f}")
        low = [a for a in L if a["cth"] < LOW_CTH]
        print(f"under {LOW_CTH}%: {pct(len(low), len(L))} of attacks;"
              f" spotter-only (NoLineOfSight) {sum(1 for a in low if 'NoLineOfSight' in a['mods'])};"
              f" at <=2%: {sum(1 for a in L if a['cth'] <= 2)}")
        if not any(a.get("legacy") for a in L):
            own = [a for a in L if a.get("own")]
            print(f"own turn {len(own)}, reactions (overwatch/interrupt) {len(L) - len(own)};"
                  f" own-turn under {LOW_CTH}%: {sum(1 for a in own if a['cth'] < LOW_CTH)}")
            supp = collections.Counter(a["action"] for a in L if a.get("supp"))
            print("suppression applied:", dict(supp) or "none",
                  "| AutoFire attacks:", sum(1 for a in L if a["action"] == "AutoFire"))
            planned = [a for a in own if a.get("plan_cth") is not None]
            if planned:
                d = [a["cth"] - a["plan_cth"] for a in planned]
                print(f"plan vs roll CTH (own turn): mean delta {st.mean(d):+.1f}, |delta|>15 in {sum(1 for x in d if abs(x) > 15)}/{len(d)}")
        print("low-CTH actions:", collections.Counter(a["action"] for a in low).most_common(6))
        print("low-CTH weapons:", collections.Counter(a.get("weapon") for a in low).most_common(8))
        worst = collections.defaultdict(list)
        for a in low:
            for k, v in a["mods"].items():
                if k != "Stat":
                    worst[k].append(v)
        top = sorted(((st.mean(v), k, len(v)) for k, v in worst.items()), key=lambda x: x[0])[:5]
        print("biggest penalties on low-CTH shots:", ", ".join(f"{k} {m:.0f} (n={n})" for m, k, n in top))


def turns_report(recs):
    T = [r for r in recs if r.get("ev") == "turn" and r.get("side") not in PLAYER_SIDES and r.get("side") != "ally"]
    if not T:
        return
    print(f"\n## AI turns ({len(T)} records)")
    print("archetypes:", collections.Counter(r.get("arch") for r in T).most_common())
    print("signature chosen:", collections.Counter(r.get("sig") for r in T).most_common(8))
    last = {}
    for r in T:
        last[(r["sess"], r["turn"], r.get("unit"))] = r
    L = list(last.values())
    # pos0 is captured after the move, so movement is measured turn to turn
    prev, moved = {}, []
    for k in sorted(last, key=lambda k: (k[0], k[1] or 0)):
        r = last[k]
        p = r.get("pos1") or r.get("pos0")
        u = (k[0], k[2])
        if p and u in prev and prev[u][0] == (k[1] or 0) - 1:
            a = prev[u][1]
            moved.append((round(math.hypot(p["x"] - a["x"], p["y"] - a["y"]) / 1200), r))
        prev[u] = (k[1] or 0, p)
    if moved:
        still = [r for m, r in moved if m == 0]
        print(f"stationary turns {len(still)}/{len(moved)} (enemy visible in {sum(1 for r in still if r.get('enemies_vis'))});"
              f" median move {st.median(m for m, _ in moved)} tiles")
        by_arch = collections.defaultdict(list)
        for m, r in moved:
            by_arch[r.get("arch")].append(m)
        print("median move by archetype:", {k: st.median(v) for k, v in sorted(by_arch.items(), key=lambda x: -len(x[1]))})
    left = [r for r in L if r.get("ap1") is not None and not r.get("dead")]
    if left:
        heavy = [r for r in left if r["ap1"] >= 40]
        print(f"turns ending with >=40 displayed AP: {len(heavy)}/{len(left)}"
              f" (enemy visible in {sum(1 for r in heavy if r.get('enemies_vis'))});"
              f" by arch {collections.Counter(r.get('arch') for r in heavy).most_common(5)}")
    cp = [r["cth_plan"] for r in L if r.get("cth_plan") is not None]
    if cp:
        print(f"planned attack CTH under {LOW_CTH}%: {sum(1 for c in cp if c < LOW_CTH)}/{len(cp)}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("path", nargs="?", default=DEFAULT_IN)
    ap.add_argument("--arena", action="store_true", help="keep AI-vs-AI arena sessions")
    ap.add_argument("--legacy", action="store_true", help="also parse PrintAttack blocks from logs_archive")
    args = ap.parse_args()

    recs = load(args.path)
    if not args.arena:
        drop = arena_sessions(recs)
        recs = [r for r in recs if r.get("sess") not in drop]
        print(f"{len(drop)} arena session(s) dropped")
    atks = [r for r in recs if r.get("ev") == "attack"]
    for a in atks:
        a["mods"] = a.get("mods") or {}
    if args.legacy:
        atks += legacy_attacks()  # legacy blocks carry no session, so --arena does not filter them
    print(f"{len(recs)} records, {len(atks)} attacks")
    attacks_report(atks)
    turns_report(recs)


if __name__ == "__main__":
    main()
