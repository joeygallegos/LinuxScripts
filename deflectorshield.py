import subprocess, requests, time, threading, ipaddress, json, socket, sys, os

CONFIG_FILE = "deflectorshield_config.json"
DRY_RUN = "--dry-run" in sys.argv
FLUSH_ONLY = "--flush" in sys.argv

def run(cmd):
    """Run or print command depending on dry-run mode."""
    if DRY_RUN:
        print(f"[DRY-RUN] {' '.join(cmd)}")
    else:
        print(f"[CMD] {' '.join(cmd)}")
        subprocess.run(cmd, check=False)

def load_config():
    with open(CONFIG_FILE) as f:
        return json.load(f)

def reset_iptables():
    """Flush and reset iptables."""
    print("[*] Flushing iptables and setting default policies to ACCEPT...")
    run(["sudo", "iptables", "-F"])
    run(["sudo", "iptables", "-X"])
    run(["sudo", "iptables", "-P", "INPUT", "ACCEPT"])
    run(["sudo", "iptables", "-P", "FORWARD", "ACCEPT"])
    run(["sudo", "iptables", "-P", "OUTPUT", "ACCEPT"])

def allow_fetch_dependencies():
    """Allow outbound DNS, HTTP(S), loopback for fetching lists."""
    run(["sudo", "iptables", "-A", "OUTPUT", "-p", "udp", "--dport", "53", "-j", "ACCEPT"])
    run(["sudo", "iptables", "-A", "OUTPUT", "-p", "tcp", "--dport", "53", "-j", "ACCEPT"])
    run(["sudo", "iptables", "-A", "OUTPUT", "-p", "tcp", "--dport", "80", "-j", "ACCEPT"])
    run(["sudo", "iptables", "-A", "OUTPUT", "-p", "tcp", "--dport", "443", "-j", "ACCEPT"])
    run(["sudo", "iptables", "-A", "INPUT", "-i", "lo", "-j", "ACCEPT"])
    run(["sudo", "iptables", "-A", "OUTPUT", "-o", "lo", "-j", "ACCEPT"])
    run(["sudo", "iptables", "-A", "INPUT", "-m", "state", "--state", "ESTABLISHED,RELATED", "-j", "ACCEPT"])

def fetch_url(url, results, idx):
    headers = {'User-Agent': 'Mozilla/5.0'}
    for attempt in range(3):
        try:
            print(f"[*] Fetching {url} (attempt {attempt+1})...")
            resp = requests.get(url, headers=headers, timeout=10)
            if resp.status_code == 200:
                lines = [line.strip() for line in resp.text.splitlines() if line.strip() and not line.startswith("#")]
                results[idx] = lines
                print(f"[+] Fetched {len(lines)} entries from {url}")
                return
            else:
                print(f"[WARN] Status {resp.status_code} from {url}")
        except Exception as e:
            print(f"[ERROR] Attempt {attempt+1} failed for {url}: {e}")
            time.sleep(1)
    results[idx] = []
    print(f"[ERROR] Failed to fetch from {url} after 3 attempts.")

def fetch_bad_ips(urls):
    print("[*] Fetching blocklists concurrently...")
    results = [None]*len(urls)
    threads = []
    for i,u in enumerate(urls):
        t = threading.Thread(target=fetch_url, args=(u,results,i))
        t.start()
        threads.append(t)
    for t in threads:
        t.join()
    all_ips=set()
    for iplist in results:
        if iplist: all_ips.update(iplist)
    print(f"[*] Total unique entries fetched: {len(all_ips)}")
    return sorted(all_ips)

def is_valid_network(value):
    try:
        ipaddress.ip_network(value, strict=False)
        return True
    except ValueError:
        return False

def resolve_hostname(addr):
    try:
        return socket.gethostbyname(addr)
    except socket.gaierror:
        print(f"[WARN] Could not resolve hostname {addr}, skipping.")
        return None

def setup_block_chain(chain):
    run(["sudo", "iptables", "-D", "INPUT", "-j", chain])
    run(["sudo", "iptables", "-F", chain])
    run(["sudo", "iptables", "-X", chain])
    run(["sudo", "iptables", "-N", chain])
    run(["sudo", "iptables", "-A", "INPUT", "-j", chain])

def apply_block_rules(chain,bad_ips,whitelist):
    whitelist_addresses={w["address"] for w in whitelist}
    print(f"[*] Adding block rules for {len(bad_ips)} IPs/subnets...")
    for ip in bad_ips:
        if not is_valid_network(ip):
            print(f"[SKIP] Invalid: {ip}")
            continue
        # skip if explicitly whitelisted (by address only)
        if ip in whitelist_addresses:
            print(f"[SKIP] Whitelisted: {ip}")
            continue
        run(["sudo", "iptables", "-A", chain, "-s", ip, "-j", "LOG", "--log-prefix", "[IPBLOCK] "])
        run(["sudo", "iptables", "-A", chain, "-s", ip, "-j", "DROP"])

def apply_whitelist_rules(whitelist):
    print(f"[*] Adding {len(whitelist)} whitelist ACCEPT rules...")
    for w in whitelist:
        addr=w["address"]
        port=w.get("port")
        if not is_valid_network(addr):
            resolved=resolve_hostname(addr)
            if not resolved: continue
            addr=resolved
        if port and str(port).isdigit():
            run(["sudo","iptables","-A","INPUT","-s",addr,"-p","tcp","--dport",str(port),"-j","ACCEPT"])
        else:
            run(["sudo","iptables","-A","INPUT","-s",addr,"-j","ACCEPT"])

def apply_allow_ports(ssh_port,ports):
    run(["sudo", "iptables", "-A", "INPUT", "-p", "tcp", "--dport", str(ssh_port), "-j", "ACCEPT"])
    for p in ports:
        run(["sudo", "iptables", "-A", "INPUT", "-p", "tcp", "--dport", str(p), "-j", "ACCEPT"])

def set_default_drop():
    run(["sudo","iptables","-P","INPUT","DROP"])

def main():
    cfg=load_config()
    if FLUSH_ONLY:
        print("[*] Flushing rules only and exiting...")
        reset_iptables()
        return

    reset_iptables()
    allow_fetch_dependencies()
    bad_ips=fetch_bad_ips(cfg["blocklist_feeds"])
    setup_block_chain(cfg["chain_name"])
    apply_whitelist_rules(cfg.get("whitelist_rules",[]))
    apply_block_rules(cfg["chain_name"],bad_ips,cfg.get("whitelist_rules",[]))
    apply_allow_ports(cfg["ssh_port"],cfg.get("allow_ports",[]))
    set_default_drop()
    print("[+] DeflectorShield applied successfully.")

if __name__=="__main__":
    main()
