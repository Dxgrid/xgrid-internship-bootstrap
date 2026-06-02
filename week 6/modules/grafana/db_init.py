"""
Grafana DB initialisation — run via null_resource local-exec.
Credentials are read from environment variables so no special characters
ever appear in a shell command string.
"""
import boto3, os, time, sys, base64

region   = os.environ["TF_REGION"]
project  = os.environ["TF_PROJECT"]
env_name = os.environ["TF_ENV"]
rds_host = os.environ["TF_RDS_HOST"]
db_user  = os.environ["TF_DB_USER"]
db_pass  = os.environ["TF_DB_PASS"]
gf_pass  = os.environ["TF_GF_PASS"]

# Base64-encode so the remote shell sees only [A-Za-z0-9+/=] — no quoting needed.
b64_master = base64.b64encode(db_pass.encode()).decode()
b64_gfpass = base64.b64encode(gf_pass.encode()).decode()

ec2 = boto3.client("ec2", region_name=region)
r = ec2.describe_instances(Filters=[
    {"Name": "tag:Project",         "Values": [project]},
    {"Name": "tag:Environment",     "Values": [env_name]},
    {"Name": "instance-state-name", "Values": ["running"]},
])
iid = r["Reservations"][0]["Instances"][0]["InstanceId"]
print("Instance:", iid, flush=True)

# Write master password to a .cnf file on the instance so mysql never receives
# it as a CLI argument. gf_pass is alphanumeric (special=false) so safe in SQL.
cmds = [
    "sudo dnf install -y mariadb105 2>/dev/null",
    f"echo {b64_master} | base64 -d > /tmp/_mp.txt",
    f"echo {b64_gfpass} | base64 -d > /tmp/_gp.txt",
    'printf "[client]\\npassword=" > /tmp/_db.cnf && cat /tmp/_mp.txt >> /tmp/_db.cnf && printf "\\n" >> /tmp/_db.cnf',
    (
        f"GFP=$(cat /tmp/_gp.txt); "
        f"mysql --defaults-file=/tmp/_db.cnf -h {rds_host} -u {db_user} -e \""
        "CREATE DATABASE IF NOT EXISTS grafana CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; "
        "CREATE USER IF NOT EXISTS 'grafana'@'%' IDENTIFIED BY '$GFP'; "
        "GRANT ALL PRIVILEGES ON grafana.* TO 'grafana'@'%'; "
        "FLUSH PRIVILEGES;\""
    ),
    "rm -f /tmp/_mp.txt /tmp/_gp.txt /tmp/_db.cnf",
]

ssm = boto3.client("ssm", region_name=region)
resp = ssm.send_command(
    InstanceIds=[iid],
    DocumentName="AWS-RunShellScript",
    Parameters={"commands": cmds},
)
cid = resp["Command"]["CommandId"]
print("SSM command:", cid, flush=True)

for _ in range(40):
    time.sleep(5)
    inv = ssm.get_command_invocation(CommandId=cid, InstanceId=iid)
    if inv["Status"] in ("Success", "Failed", "Cancelled", "TimedOut"):
        break

print("Status:", inv["Status"], flush=True)
if inv["Status"] != "Success":
    print(inv.get("StandardErrorContent", ""), flush=True)
    sys.exit(1)
print("Grafana DB initialized.", flush=True)
