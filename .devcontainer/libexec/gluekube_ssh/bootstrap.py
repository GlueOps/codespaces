"""Ansible-shell bootstrap: runs INSIDE the container via exec() of $GLUEKUBE_BOOTSTRAP_PY.
Reads: AUTOGLUE_ENDPOINT, AUTOGLUE_API_KEY, AUTOGLUE_ORG_ID, GLUEKUBE_SSH_KEY_IDS, GLUEKUBE_SSH_CONFIG,
GLUEKUBE_INVENTORY_YML, GLUEKUBE_ANSIBLE_CFG, GLUEKUBE_CLUSTER_NAME, GLUEKUBE_WORK_MOUNTED."""
import json, os, subprocess, sys, urllib.request

home = os.path.expanduser("~")
endpoint = os.environ["AUTOGLUE_ENDPOINT"]

def api(path):
    req = urllib.request.Request(endpoint + path, headers={
        "X-API-KEY": os.environ["AUTOGLUE_API_KEY"],
        "X-Org-ID": os.environ["AUTOGLUE_ORG_ID"]})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)

ssh_dir = os.path.join(home, ".ssh")
os.makedirs(ssh_dir, mode=0o700, exist_ok=True)

key_ids = os.environ["GLUEKUBE_SSH_KEY_IDS"].split()
failed = []
failed_idx = []
for i, kid in enumerate(key_ids):
    try:
        key = (api("/ssh/%s?reveal=true" % kid).get("private_key") or "").strip()
        if not key:
            raise ValueError("empty private_key in response")
        fd = os.open(os.path.join(ssh_dir, "gluekube_%d" % i),
                     os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(key + "\n")
    except Exception as exc:
        failed.append("%s (%s)" % (kid, exc))
        failed_idx.append(i)

with open(os.path.join(ssh_dir, "config"), "w") as f:
    f.write(os.environ["GLUEKUBE_SSH_CONFIG"])
os.chmod(os.path.join(ssh_dir, "config"), 0o600)

with open(os.path.join(home, "inventory.yml"), "w") as f:
    f.write(os.environ["GLUEKUBE_INVENTORY_YML"])
with open(os.path.join(home, ".ansible.cfg"), "w") as f:
    f.write(os.environ["GLUEKUBE_ANSIBLE_CFG"])

# Pre-warm the shared control socket: open ONE connection to the bastion and
# leave it running in the background. ControlMaster=auto does not serialize
# master creation, so without this every ansible fork finds no socket and dials
# the bastion at the same instant - a burst that trips sshd's MaxStartups and
# blows through a per-source connection rate limit (`ufw limit ssh` refuses the
# 6th new connection in 30s), which is what left the bastion itself UNREACHABLE
# while the nodes rode the connection the burst eventually established.
# With the socket already up, a whole run costs ONE connection to the bastion.
# Best-effort: if it fails, ssh falls back to dialing per connection as before.
prewarm = subprocess.run(
    ["ssh", "-fN", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
     "cluster@" + os.environ["GLUEKUBE_BASTION_HOST"]],
    stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)

# Shell niceties: cluster name in the prompt (red = prod endpoint, green =
# nonprod, mirroring get_gh_org's endpoint test) + terminal title + helpers.
# Appended so it wins over anything the image's stock .bashrc sets.
cluster = os.environ.get("GLUEKUBE_CLUSTER_NAME", "?")
color = "31" if "glueopshosted.com" in endpoint else "32"
ps1 = (r"\[\e]0;ansible: %s\a\]\[\e[2m\]ansible\[\e[0m\] \[\e[1;%sm\]%s\[\e[0m\] "
       r"\[\e[1;34m\]\w\[\e[0m\] \$ ") % (cluster, color, cluster)
with open(os.path.join(home, ".bashrc"), "a") as f:
    f.write("""
# --- gluekube_ssh ansible shell ---
alias inv='ansible-inventory --graph'
raw() { local g="$1"; shift; ansible "$g" -m raw -a "$*"; }
PS1='%s'
""" % ps1)

groups = json.loads(os.environ["GLUEKUBE_INVENTORY_YML"])["all"]["children"]
counts = "  ".join("%s(%d)" % (g, len(v.get("hosts", {})))
                   for g, v in sorted(groups.items()))

print()
print("GlueKube Ansible shell - %s" % os.environ.get("GLUEKUBE_CLUSTER_NAME", "?"))
print("Groups: %s" % counts)
if prewarm.returncode != 0:
    print("NOTE: could not pre-open the shared bastion connection (%s);"
          % (prewarm.stderr.decode(errors="replace").strip().splitlines() or ["unknown"])[-1])
    print("      runs still work, but each one dials the bastion more often.")
if failed:
    # If EVERY key failed, the shell is unusable - every ansible run would fail
    # "Permission denied (publickey)", and the API key is scrubbed below so keys
    # can't be re-fetched in-container. Fail loudly instead, matching how this
    # bootstrap already exits on an empty inventory or empty key list.
    # Key 0 is the bastion's (bash orders it first) whenever the bastion has
    # one. Its loss is as fatal as losing them all: every hop is a ProxyJump
    # through the bastion, so nothing would be reachable.
    bastion_key_failed = os.environ.get("GLUEKUBE_BASTION_KEY_FIRST") == "1" and 0 in failed_idx
    if len(failed) == len(key_ids) or bastion_key_failed:
        what = "the BASTION SSH key" if bastion_key_failed else "ANY SSH key"
        print("ERROR: could not fetch %s (%s)." % (what, ", ".join(failed)))
        print("Every ansible run would fail with 'Permission denied' - check the "
              "API key/permissions and re-run. Not starting a broken shell.")
        sys.exit(1)
    print("WARNING: could not fetch SSH key(s): %s" % ", ".join(failed))
    print("         SSH to the affected host(s) will fail.")
print("""
Nodes have no python3, so stick to modules that work over plain SSH:
  ansible all     -m raw    -a 'uptime'
  ansible workers -m raw    -a 'df -h /'
  ansible masters -m script -a './somescript.sh'
  ansible-playbook site.yml              # use gather_facts: false + raw/script""")
# The raw/inv helpers live in ~/.bashrc, which only an interactive bash reads -
# a headless piped shell (gluekube_ssh ... --ansible <<< "...") never defines
# them, so only advertise them when stdin is a TTY.
if sys.stdin.isatty():
    print("Helpers: raw <group> <cmd...>  (e.g. raw workers uptime)   inv  (inventory graph)")
if os.environ.get("GLUEKUBE_WORK_MOUNTED") == "1":
    print("Your working directory is mounted read-write at /work (the current dir).")
print("Type exit to leave.")
print()

for var in ("AUTOGLUE_API_KEY", "GLUEKUBE_BOOTSTRAP_PY", "GLUEKUBE_INVENTORY_YML",
            "GLUEKUBE_SSH_CONFIG", "GLUEKUBE_ANSIBLE_CFG"):
    os.environ.pop(var, None)
os.environ["ANSIBLE_CONFIG"] = os.path.join(home, ".ansible.cfg")
# CPython ignores SIGPIPE (SIG_IGN), and that disposition survives exec - so the
# exec'd bash and its children would print spurious "Broken pipe" errors instead
# of dying silently in pipelines like `grep -r x /work | head`. Restore default.
import signal
signal.signal(signal.SIGPIPE, signal.SIG_DFL)
sys.stdout.flush()
os.execvp("bash", ["bash"])
