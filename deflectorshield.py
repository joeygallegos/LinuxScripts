import ipaddress
import json
import subprocess
import sys
import threading
import time

import requests

CONFIG_FILE = "deflectorshield_config.json"
DRY_RUN = "--dry-run" in sys.argv
FLUSH_ONLY = "--flush" in sys.argv
FIREWALLS = [
    ("iptables", "IPv4"),
    ("ip6tables", "IPv6"),
]
DEFAULT_BLOCK_CIDRS = False
DEFAULT_MINIMUM_SCORE = 3


def run(cmd):
    """Run or print command depending on dry-run mode."""
    if DRY_RUN:
        print(f"[DRY-RUN] {' '.join(cmd)}")
    else:
        print(f"[CMD] {' '.join(cmd)}")
        subprocess.run(cmd, check=False)


def run_with_input(cmd, input_text):
    """Run a command with stdin, or summarize it in dry-run mode."""
    if DRY_RUN:
        line_count = len(input_text.splitlines())
        print(f"[DRY-RUN] {' '.join(cmd)} < {line_count} generated lines")
        if line_count <= 50:
            print(input_text, end="")
    else:
        print(f"[CMD] {' '.join(cmd)} < generated rules")
        subprocess.run(cmd, input=input_text, text=True, check=False)


def load_config():
    with open(CONFIG_FILE) as f:
        return json.load(f)


def reset_managed_rules(chain):
    """Remove only DeflectorShield's chain and keep default policies open."""
    print("[*] Resetting DeflectorShield rules and setting default policies to ACCEPT...")
    for firewall, _ in FIREWALLS:
        run(["sudo", firewall, "-P", "INPUT", "ACCEPT"])
        run(["sudo", firewall, "-P", "FORWARD", "ACCEPT"])
        run(["sudo", firewall, "-P", "OUTPUT", "ACCEPT"])
        for _ in range(10):
            run(["sudo", firewall, "-D", "INPUT", "-j", chain])
        run(["sudo", firewall, "-F", chain])
        run(["sudo", firewall, "-X", chain])


def parse_feed_lines(text):
    return [
        line.strip()
        for line in text.splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]


def parse_feed_entry(entry):
    parts = entry.split()
    if not parts:
        return None, None
    score = None
    if len(parts) > 1:
        try:
            score = int(parts[1])
        except ValueError:
            score = None
    return parts[0], score


def fetch_url(url, results, idx):
    headers = {"User-Agent": "DeflectorShield/1.0"}
    for attempt in range(3):
        try:
            print(f"[*] Fetching {url} (attempt {attempt + 1})...")
            resp = requests.get(url, headers=headers, timeout=10)
            if resp.status_code == 200:
                results[idx] = parse_feed_lines(resp.text)
                print(f"[+] Fetched {len(results[idx])} entries from {url}")
                return
            print(f"[WARN] Status {resp.status_code} from {url}")
        except Exception as e:
            print(f"[ERROR] Attempt {attempt + 1} failed for {url}: {e}")
            time.sleep(1)
    results[idx] = []
    print(f"[ERROR] Failed to fetch from {url} after 3 attempts.")


def fetch_bad_ips(urls):
    urls = [u for u in urls if u]
    print("[*] Fetching blocklists concurrently...")
    results = [None] * len(urls)
    threads = []
    for i, url in enumerate(urls):
        t = threading.Thread(target=fetch_url, args=(url, results, i))
        t.start()
        threads.append(t)
    for t in threads:
        t.join()
    all_ips = set()
    for iplist in results:
        if iplist:
            all_ips.update(iplist)
    print(f"[*] Total unique raw entries fetched: {len(all_ips)}")
    return sorted(all_ips)


def normalize_network(value):
    try:
        return ipaddress.ip_network(value, strict=False)
    except ValueError:
        return None


def setup_block_chain(chain):
    for firewall, label in FIREWALLS:
        print(f"[*] Creating {label} block chain {chain}...")
        run(["sudo", firewall, "-N", chain])
        run(["sudo", firewall, "-D", "INPUT", "-j", chain])
        run(["sudo", firewall, "-I", "INPUT", "-j", chain])


def is_host_network(network):
    return network.prefixlen == network.max_prefixlen


def collect_block_networks(
    entries,
    block_cidrs=DEFAULT_BLOCK_CIDRS,
    minimum_score=DEFAULT_MINIMUM_SCORE,
):
    print(f"[*] Normalizing and deduplicating {len(entries)} fetched entries...")
    networks = set()
    skipped = 0
    skipped_cidrs = 0
    skipped_score = 0
    duplicates = 0
    for entry in entries:
        address, score = parse_feed_entry(entry)
        if score is not None and score < minimum_score:
            print(f"[SKIP] Low score {score}: {address}")
            skipped_score += 1
            continue
        network = normalize_network(address)
        if not network:
            print(f"[SKIP] Invalid: {entry}")
            skipped += 1
            continue
        if not block_cidrs and not is_host_network(network):
            print(f"[SKIP] CIDR disabled: {entry}")
            skipped_cidrs += 1
            continue
        if network in networks:
            duplicates += 1
            continue
        networks.add(network)

    print(
        f"[*] Prepared {len(networks)} distinct IPs/subnets "
        f"({duplicates} duplicates removed)."
    )
    print(
        f"[*] Skipped {skipped} invalid entries, {skipped_cidrs} CIDR entries, "
        f"and {skipped_score} low-score entries."
    )
    return sorted(networks, key=lambda n: (n.version, int(n.network_address), n.prefixlen))


def apply_block_rules(chain, networks, log_blocked_ips=False):
    print(f"[*] Creating source-only block rules for {len(networks)} distinct IPs/subnets...")

    for firewall, label in FIREWALLS:
        version = 4 if firewall == "iptables" else 6
        rules = ["*filter"]
        applied = 0
        for network in networks:
            if network.version != version:
                continue
            if log_blocked_ips:
                rules.append(f'-A {chain} -s {network} -j LOG --log-prefix "[IPBLOCK] "')
                applied += 1
            rules.append(f"-A {chain} -s {network} -j DROP")
            applied += 1
        rules.append("COMMIT")
        print(f"[*] Loading {applied} {label} block rules in one batch...")
        if applied:
            run_with_input(
                ["sudo", f"{firewall}-restore", "-n"],
                "\n".join(rules) + "\n",
            )


def main():
    cfg = load_config()
    chain = cfg.get("chain_name", "BADIPS")

    if FLUSH_ONLY:
        reset_managed_rules(chain)
        print("[+] DeflectorShield rules flushed. Host firewall policies are ACCEPT.")
        return

    bad_ips = fetch_bad_ips(cfg.get("blocklist_feeds", []))
    networks = collect_block_networks(
        bad_ips,
        cfg.get("block_cidrs", DEFAULT_BLOCK_CIDRS),
        cfg.get("minimum_score", DEFAULT_MINIMUM_SCORE),
    )
    reset_managed_rules(chain)
    setup_block_chain(chain)
    apply_block_rules(chain, networks, cfg.get("log_blocked_ips", False))
    print("[+] DeflectorShield block rules applied successfully.")


if __name__ == "__main__":
    main()
