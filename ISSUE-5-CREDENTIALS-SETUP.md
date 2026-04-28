# Issue #5: Jenkins Pipeline — Credential Setup Guide

## Overview

The `Jenkinsfile` requires three credentials stored securely in Jenkins:

1. **AWS Access Key ID** (for Terraform)
2. **AWS Secret Access Key** (for Terraform)  
3. **EC2 SSH Private Key** (for deployment and audit)

This guide walks you through adding each credential to Jenkins.

---

## Step 1: Access Jenkins Credentials

1. Open Jenkins: **http://localhost:8080**
2. Log in with your admin account
3. Navigate to: **Manage Jenkins** → **Credentials** → **System** → **Global credentials (unrestricted)**

---

## Step 2: Add AWS Access Key ID

1. Click **+ Add Credentials** (top left)
2. Kind: **Secret text**
3. Scope: **Global (Jenkins, builds, queue, plugins)**
4. Secret: `<your-aws-access-key-id>`
5. ID: `aws-access-key-id` ← **Use exactly this ID**
6. Description: `AWS Access Key ID for Terraform`
7. Click **Create**

---

## Step 3: Add AWS Secret Access Key

1. Click **+ Add Credentials** again
2. Kind: **Secret text**
3. Scope: **Global (Jenkins, builds, queue, plugins)**
4. Secret: `<your-aws-secret-access-key>`
5. ID: `aws-secret-access-key` ← **Use exactly this ID**
6. Description: `AWS Secret Access Key for Terraform`
7. Click **Create**

---

## Step 4: Add EC2 SSH Private Key

This is the most important step — it allows Jenkins to SSH into your EC2 instance without storing credentials in plain text.

### Option A: Upload Your Existing Key (Recommended)

If you already have `xgrid-key.pem` on your Mac:

1. Click **+ Add Credentials**
2. Kind: **SSH Username with private key**
3. Scope: **Global (Jenkins, builds, queue, plugins)**
4. Username: `ubuntu` ← **For Ubuntu AMI**  
   (If using Amazon Linux 2, use `ec2-user`)
5. Private Key: **Enter directly** (radio button)
6. Click the **Key** text area and paste the contents of your `.pem` file:
   ```
   cat ~/.ssh/xgrid-key.pem | pbcopy  # macOS: copies to clipboard
   ```
   Then paste.
7. ID: `ec2-ssh-key` ← **Use exactly this ID**
8. Description: `EC2 SSH Key for Deployment`
9. Leave Passphrase empty (unless your key is encrypted)
10. Click **Create**

### Option B: Generate a New Key in Jenkins (Alternative)

If you don't have the key or want Jenkins to manage it:

1. On your Mac terminal:
   ```bash
   ssh-keygen -t rsa -b 4096 -f /tmp/jenkins-key -N ""
   cat /tmp/jenkins-key  # private key
   cat /tmp/jenkins-key.pub  # public key
   ```

2. In Jenkins, add the private key as SSH Username with private key (same steps as Option A)

3. Update your Terraform `variables.tf`:
   ```hcl
   variable "key_pair_name" {
     description = "EC2 Key Pair Name"
     default     = "xgrid-key"  # or create a new one with the public key
   }
   ```

---

## Step 5: Verify Credentials Are Stored

After all three are created, your Credentials page should show:

```
✓ aws-access-key-id
✓ aws-secret-access-key
✓ ec2-ssh-key
```

Click on each to verify the ID matches exactly — the Jenkinsfile uses these IDs to reference the credentials:

- `credentialsId: 'aws-access-key-id'`
- `credentialsId: 'aws-secret-access-key'`
- `credentials: ['ec2-ssh-key']`

---

## Step 6: Create a Multibranch Pipeline Job

Now that credentials are stored, create the Jenkins job:

1. Jenkins home → **New Item**
2. Enter name: `xgrid-week2-pipeline`
3. Type: **Multibranch Pipeline**
4. Click **Create**

### Configure Branch Sources

1. **Branch Sources** section → **Add source** → **Git**
2. Project Repository: `https://github.com/Dxgrid/xgrid-internship-bootstrap.git`
3. Credentials: (leave as "- none -" for public repo, or add GitHub credentials if private)
4. Save

### Configure Pipeline

1. Scroll to **Pipeline** section
2. Definition: **Pipeline script from SCM**
3. SCM: **Git**
4. Repository URL: `https://github.com/Dxgrid/xgrid-internship-bootstrap.git`
5. Branches: `*/main` (or your default branch)
6. Script Path: `Jenkinsfile` ← This is the file we just created
7. Click **Save**

---

## Step 7: Run the Pipeline

1. Go to your job: **xgrid-week2-pipeline**
2. Click **Scan Multibranch Pipeline Now** (top left) — or just click **Build Now**
3. Watch the pipeline execute:
   - ✅ Terraform provisions EC2
   - ✅ Pipeline waits for SSH readiness
   - ✅ App files are transferred
   - ✅ Docker image is built and deployed
   - ✅ System audit runs and validates health

---

## Troubleshooting

### "No such credential: aws-access-key-id"
- Double-check the credential ID exactly matches the string in the Jenkinsfile
- Verify the credential is in **Global credentials** (not folder-scoped)

### "SSH: Permission denied (publickey)"
- Verify the private key is correct and matches the public key in your EC2 key pair
- Ensure the Username matches your AMI (ubuntu / ec2-user)

### "Pipeline stuck at 'SSH not ready yet — retrying'"
- This is normal — EC2 can take 60-90 seconds to boot
- If it stays stuck after 5+ minutes, check AWS console to see if the instance started at all
- Verify Terraform applied successfully in the Jenkins logs

### "Audit FAILED: system_audit.sh exited 1"
- Check the SSH output above for which audit check failed (disk, ports, container, health endpoint)
- Fix the issue on the EC2 instance and retry

---

## Security Best Practices

✅ **DO:**
- Store credentials in Jenkins Credentials Manager, not in `Jenkinsfile` or env vars
- Use `withCredentials()` and `sshagent()` blocks to scope credential exposure
- Regenerate AWS keys after deployment if they were temporary
- Rotate SSH keys regularly for long-lived infrastructure

❌ **DON'T:**
- Paste secrets directly into the `Jenkinsfile`
- Check `.pem` files into Git
- Disable `StrictHostKeyChecking` for production long-lived servers (the Jenkinsfile uses it for ephemeral EC2 created each run, which is acceptable)

---

## Next Steps

Once the pipeline runs successfully:

1. **Iterate**: Make changes to the Python app (`week 2/app/`), push to GitHub, and the pipeline auto-rebuilds
2. **Upgrade**: Add more stages (unit tests, Docker registry push, blue-green deployment)
3. **Monitor**: Check Jenkins build history and logs to track infrastructure deployments

---

**Week 2 Sprint Complete! 🎉**

You now have:
- ✅ Issue #2: Terraform infrastructure
- ✅ Issue #3: Containerized Python API
- ✅ Issue #4: System audit script
- ✅ Issue #1: Jenkins controller
- ✅ Issue #5: End-to-end CI/CD pipeline

The full automation loop is now in place.
