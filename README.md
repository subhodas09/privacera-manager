# Privacera Manager Self-Managed No-SSL Deployment Guide

## 📋 Overview

This guide provides complete step-by-step instructions for deploying Privacera Self-Managed application with a Snowflake connector using the **`main`** branch.

## 🚀 Step-by-Step Setup Guide

### Step 1: Register for Snowflake Trial Account

Before setting up the infrastructure, you'll need a Snowflake account for the connector configuration. Follow these steps to register for a free trial:

#### **1.1 Visit Snowflake Trial Registration**
1. Go to [Snowflake's Free Trial Registration](https://signup.snowflake.com/)
2. Click **"Start for free"** or **"Try Snowflake for free"**

#### **1.2 Complete Registration Form**
1. **Account Information**:
   - Choose your preferred cloud provider (AWS, Azure, or Google Cloud)
   - Select your preferred region
   - Choose your preferred edition (Standard is sufficient for this exercise)

2. **Personal Information**:
   - Enter your email address
   - Create a strong password
   - Provide your name and company information

3. **Account Setup**:
   - Choose your account name (this will be your unique Snowflake URL)
   - Accept the terms and conditions
   - Click **"Create Account"**

#### **1.3 Verify and Access Your Account**
1. Check your email for the verification link
2. Click the verification link to activate your account
3. Log in to your Snowflake account at: `https://YOUR_ACCOUNT_NAME.snowflakecomputing.com` or: `https://app.snowflake.com/ACCOUNT/Name/#/homepage`

#### **1.4 Note Your Account Details**
Keep the following information handy for later configuration:
- **Account URL**: `https://YOUR_ACCOUNT_NAME.snowflakecomputing.com`
- **Username**: Your registered email
- **Password**: Your account password
- **Account Name**: Your chosen account name

**Important**: Your trial account includes $400 in credits and is valid for 30 days, which is sufficient for testing the Privacera-Snowflake integration.

### Step 2: Create EKS Cluster

Follow the [AWS EKS Getting Started Guide](https://docs.aws.amazon.com/eks/latest/userguide/getting-started.html) to create an EKS cluster with the following specifications as per [Privacera's AWS Cloud Resources documentation](https://docs.privacera.com/get-started/base-installation/self-managed/prerequisites/aws-cloud-resources.html#aws-eks-cluster-for-running-privacera-software):

**Required EKS Cluster Configuration:**
- **Cluster name**: `privacera-cluster`
- **Kubernetes version**: Check Privacera release notes for supported version
- **Node type**: r5.2xlarge or similar
- **Auto-scaling node group**: min 0 to max 3 nodes
- **Storage**: Use EBS for this exercise (no EFS or Load Balancer Controller required)

**Additional Requirements:**
- Internet access for pulling images from `hub2.privacera.com`
- Access to GitHub for repository operations
- Proper IAM roles and security groups configured

**Verify Cluster Setup:**
```bash
# Verify kubectl access
kubectl cluster-info
kubectl get nodes
```

### Step 3: GitHub Repository Setup

#### **3.1 Clone and Copy to Your Own Repository**
```bash
# Step 1: Clone only the main branch
git clone -b main https://github.com/nbhargav879/privacera-manager.git
cd privacera-manager

# Step 2: Create your own repository on GitHub
# 1. Go to https://github.com/new
# 2. Create a new repository named "privacera-manager" (or your preferred name)
# 3. Make it public or private as needed
# 4. DO NOT initialize with README, .gitignore, or license

# Step 3: Remove git history and prepare for your own repo
rm -rf .git
git init

# Step 4: Add all files to your new repository
git add .

# Step 5: Make initial commit
git commit -m "Initial commit - Privacera Manager deployment configuration (main branch)"

# Step 6: Add your repository as remote and push
git remote add origin https://github.com/YOUR_USERNAME/YOUR_REPO_NAME.git
git branch -M main
git push -u origin main

# Step 7: Verify your repository is set up correctly
git remote -v
git status
```







### Step 4: GitHub Actions Runner Setup

**Before starting:** Make sure you have set the `GITHUB_ACTIONS_NAMESPACE` variable at the top of this document to your preferred namespace.

#### **4.1 Enable GitHub Actions for Private Repository**
1. **Navigate to Repository Settings:**
   - Go to your GitHub repository
   - Click on **"Settings"** tab

2. **Access Actions Settings:**
   - In the left sidebar, click on **"Actions"** → **"General"**

3. **Configure Actions Permissions:**
   - Under **"Actions permissions"**, select **"Allow all actions and reusable workflows"**
   - This enables GitHub Actions to run in your private repository

4. **Enable Workflow Permissions:**
   - Scroll down to **"Workflow permissions"**
   - Select **"Read and write permissions"**
   - Check **"Allow GitHub Actions to create and approve pull requests"**
   - Click **"Save"**

5. **Verify Actions are Enabled:**
   - Go to the **"Actions"** tab in your repository
   - You should see the "Privacera Manager Install" workflow listed
   - If not visible, refresh the page

#### **4.2 Create GitHub Personal Access Token (PAT)**
```bash
# 1. Go to GitHub.com → Settings → Developer settings → Personal access tokens → Tokens (classic)
# 2. Click "Generate new token (classic)"
# 3. Give it a descriptive name (e.g., "Privacera Manager Runner")
# 4. Set expiration (recommended: 90 days or custom)
# 5. Select the following scopes:
#    - repo (Full control of private repositories)
#    - workflow (Update GitHub Action workflows)
#    - admin:org (Full control of organizations and teams)
# 6. Click "Generate token"
# 7. Copy the token immediately (you won't see it again)
#
# Note: Use your own GitHub account to create this token for your own repository
```

#### **4.3 Install GitHub Actions Runner Controller**

**Prerequisites:**
- Ensure you have a valid GitHub Personal Access Token (PAT) with appropriate permissions
- Update the `github_actions_values.yml` file with your preferred namespace and GitHub token
- For detailed prerequisites, refer to the [Actions Runner Controller Documentation](https://github.com/actions-runner-controller/actions-runner-controller#deploying)

```bash
# Add the actions-runner-controller Helm repository
helm repo add actions-runner-controller https://actions-runner-controller.github.io/actions-runner-controller

# Install the actions-runner-controller using Helm with custom values
helm upgrade --install --namespace $GITHUB_ACTIONS_NAMESPACE --create-namespace \
             --values github_actions_values.yml \
             actions-runner-controller actions-runner-controller/actions-runner-controller

# Verify the controller is running
kubectl get pods -n $GITHUB_ACTIONS_NAMESPACE
```

#### **4.4 Create Kubernetes Secret for GitHub Token**
```bash
# Create a Kubernetes secret for the GitHub token
kubectl create secret generic github-token \
  --from-literal=token=YOUR_GITHUB_TOKEN \
  -n $GITHUB_ACTIONS_NAMESPACE

# Verify the secret was created
kubectl get secret github-token -n $GITHUB_ACTIONS_NAMESPACE
```

#### **4.5 Update Runner Configuration**
Edit the `github-self-hosted-runner.yaml` file and update the repository information and namespace:

```yaml
apiVersion: actions.summerwind.dev/v1alpha1
kind: RunnerDeployment
metadata:
  name: privacera-manager-deploy
  namespace: YOUR_NAMESPACE  # Replace with your namespace (e.g., $GITHUB_ACTIONS_NAMESPACE)
spec:
  replicas: 1
  template:
    spec:
      repository: YOUR_USERNAME/YOUR_REPOSITORY  # Replace with your actual repository
      labels:
        - self-hosted
        - k8s  
        - linux
      resources:
        limits:
          memory: "2Gi"
          cpu: "1000m"
        requests:
          memory: "1Gi"
          cpu: "500m"
      dockerdWithinRunnerContainer: false
      image: summerwind/actions-runner:latest
      env:
        - name: GITHUB_TOKEN
          valueFrom:
            secretKeyRef:
              name: github-token
              key: token
```

**Important Updates Required:**
1. **Namespace**: Replace `YOUR_NAMESPACE` with the namespace you used in step 4.3 (e.g., `$GITHUB_ACTIONS_NAMESPACE`)
2. **Repository**: Replace `YOUR_USERNAME/YOUR_REPOSITORY` with your actual GitHub repository path

#### **4.6 Deploy Self-Hosted Runner**
```bash
# Apply the runner deployment
kubectl apply -f github-self-hosted-runner.yaml

# Verify the runner deployment
kubectl get runnerdeployment -n $GITHUB_ACTIONS_NAMESPACE

# Check runner pod status
kubectl get pods -n $GITHUB_ACTIONS_NAMESPACE | grep privacera
```

#### **4.7 Validate Runner Setup**

**Command Line Validation:**
```bash
# Check if runner is registered and ready
kubectl get runner -n $GITHUB_ACTIONS_NAMESPACE

# Verify runner labels are correct
kubectl describe runner -n $GITHUB_ACTIONS_NAMESPACE

# Check runner logs for any issues
kubectl logs -n $GITHUB_ACTIONS_NAMESPACE -l app=runner
```

**GitHub GUI Validation:**

1. **Check Runner Registration:**
   - Go to your GitHub repository
   - Navigate to **Settings** → **Actions** → **Runners**
   - Verify your self-hosted runner appears in the list
   - Check that runner status shows "Idle" or "Busy"

2. **Verify Runner Labels:**
   - In the Runners section, click on your runner name
   - Verify the following labels are present:
     - `self-hosted`
     - `k8s`
     - `linux`

3. **Check Runner Details:**
   - Click on your runner to see detailed information
   - Verify the runner is connected and responsive
   - Check the "Last used" timestamp to ensure recent activity

4. **Test Runner Functionality:**
   - Go to **Actions** tab in your repository
   - Create a new workflow or use an existing one
   - Add the following to your workflow:
   ```yaml
   runs-on: [self-hosted, k8s, linux]
   ```
   - Run the workflow and verify it executes on your self-hosted runner

5. **Monitor Runner Activity:**
   - In the Actions tab, check workflow runs
   - Verify jobs are being assigned to your self-hosted runner
   - Check the runner status during job execution

### Step 5: Privacera Configuration



#### **5.1 Configure Snowflake Connector**

##### **5.1.1 Snowflake Prerequisites Setup**
Follow the [Snowflake Prerequisites Guide](https://docs.privacera.com/connectors/snowflake/access/prerequisites.html) to set up:

1. **Create Snowflake Role**: `PRIVACERA_POLICYSYNC_ROLE`
2. **Create Snowflake Warehouse**: `PRIVACERA_POLICYSYNC_WH`
3. **Grant Audit Permissions**: Access to Snowflake audit logs
4. **Create Database**: `PRIVACERA_DB` for security functions
5. **Create User**: `PRIVACERA_POLICYSYNC_USER`

> **⚠️ Snowflake Free Trial Note**: If you're using Snowflake's free trial account, you may encounter the following error when granting permissions:
> ```
> 391811 (0A000): Unsupported feature GRANT/REVOKE APPLY ROW ACCESS POLICY ON ACCOUNT'.
> ```
> This error occurs when running:
> ```sql
> GRANT APPLY ROW ACCESS POLICY ON ACCOUNT TO ROLE "PRIVACERA_POLICYSYNC_ROLE";
> ```
> **You can safely ignore this error for our use cases** - it's a limitation of the free trial account and doesn't affect the core functionality needed for Privacera integration.
>
> **⚠️ Warehouse Creation Note**: When creating the `PRIVACERA_POLICYSYNC_WH` warehouse, **remove** the `SCALING_POLICY = 'ECONOMY'` line from the warehouse creation command. The correct command should be:
> ```sql
> CREATE WAREHOUSE IF NOT EXISTS "PRIVACERA_POLICYSYNC_WH"
> WITH
>     WAREHOUSE_SIZE = 'XSMALL',
>     WAREHOUSE_TYPE = 'STANDARD',
>     AUTO_SUSPEND = 600,
>     AUTO_RESUME = TRUE,
>     MIN_CLUSTER_COUNT = 1,
>     MAX_CLUSTER_COUNT = 1;
> ```



##### **5.1.2 Update Snowflake Connector Configuration**
```bash
# Edit the Snowflake connector configuration file
nano custom-vars/connectors/snowflake/test/vars.connector.snowflake.yml

# Update the following configuration values:
# CONNECTOR_SNOWFLAKE_JDBC_URL: "jdbc:snowflake://your-account.snowflakecomputing.com"
# CONNECTOR_SNOWFLAKE_JDBC_USERNAME: "PRIVACERA_POLICYSYNC_USER"
# CONNECTOR_SNOWFLAKE_JDBC_PASSWORD: "Snowflake2024!@#"
# CONNECTOR_SNOWFLAKE_DEFAULT_USER_PASSWORD: "Snowflake2024!@#"
```




### Step 6: GitHub Secrets Configuration





#### **6.1 Add Secrets to GitHub**
1. Go to: **GitHub Repository** → **Settings** → **Secrets and variables** → **Actions**
2. Click **"New repository secret"**
3. Add each of the 5 required secrets:

| Secret Name | Secret Type | Description |
|-------------|-------------|-------------|
| `PRIVACERA_HUB_USER` | Privacera Hub | Your Privacera Hub username |
| `PRIVACERA_HUB_PASSWORD` | Privacera Hub | Your Privacera Hub password |
| `ANSIBLE_VAULT_PASSWORD` | Security Passwords | Strong password for Ansible vault (min 12 chars) |
| `GLOBAL_DEFAULT_SECRETS_KEYSTORE_PASSWORD` | Security Passwords | Strong password for keystore (min 12 chars) |
| `EKS_CLUSTER_NAME` | Infrastructure | Your EKS cluster name |



### Step 7: Running the Deployment

#### **7.1 Access GitHub Actions**
1. Go to your GitHub repository
2. Click on **"Actions"** tab
3. Find **"Privacera Manager Install"** workflow

#### **7.2 Manual Workflow Execution**
1. Click on **"Privacera Manager Install"**
2. Click **"Run workflow"** button
3. Select the branch: **`main`** (or your default branch)
4. Configure parameters:
   - **Deployment Type**: AWS (default)
   - **AWS Region**: us-east-1 (default)
   - **Skip Helm Validation**: false (default)
   - **Debug Mode**: false (recommended: true for first run)
5. Click **"Run workflow"**

#### **7.3 Monitor Execution**
1. Click on the running workflow
2. Monitor each step:
   - ✅ **Checkout code**
   - ✅ **Load configuration from variables.env**
   - ✅ **Validate configuration**
   - ✅ **Verify GitHub secrets**
   - ✅ **Set up kubeconfig**
   - ✅ **Install dependencies**
   - ✅ **Login to Privacera Hub**
   - ✅ **Download and extract Privacera Manager**
   - ✅ **Use custom configurations from repository**
   - ✅ **Generate Helm charts**
   - ✅ **Deploy to Kubernetes**

### Step 8: Verification

#### **8.1 Check Deployment Status**
```bash
# Check pods in your deployment namespace
kubectl get pods -n candidate-test

# Check services
kubectl get svc -n candidate-test

# Check ingress (if using ALB)
kubectl get ingress -n candidate-test
```

#### **8.2 Verify Configuration**
```bash
# Check if custom configurations were applied
kubectl get configmap -n candidate-test

# Check secrets
kubectl get secrets -n candidate-test
```

#### **8.3 Validate Privacera Portal Access**
```bash
# Port forward to access Privacera portal locally
kubectl port-forward -n candidate-test svc/portal 6868:6868
```

**Portal Access Validation:**
1. **Access the Portal**: Open your browser and navigate to:
   - **Local access**: `http://localhost:6868` (if using port-forward)

2. **Login with Default Credentials**:
   - **Username**: `padmin`
   - **Password**: `padmin`

3. **Verify Successful Login**:
   - ✅ You should see the Privacera Portal
   - ✅ All services should be running (green status indicators)
   - ✅ No error messages on the login page

**Troubleshooting Portal Access:**
```bash
# If portal is not accessible, check pod logs
kubectl get -n candidate-test pods

```

## 🔧 Troubleshooting Guide

### **Common Issues and Solutions**

#### **Issue 1: PVC Creation Failures**

**Symptoms:**
- Pods stuck in `Pending` status
- Error: `persistentvolumeclaim "xxx-pvc" not found`
- Error: `persistentvolumeclaims "xxx-pvc" is forbidden: may only update PVC status`

**Root Cause:**
Service account permissions issue. Components using the `default` service account cannot create PVCs.

**Diagnosis:**
```bash
# Check service account permissions
kubectl auth can-i create persistentvolumeclaims --as=system:serviceaccount:candidate-test:default -n candidate-test
# Result: no

kubectl auth can-i create persistentvolumeclaims --as=system:serviceaccount:candidate-test:privacera-sa -n candidate-test
# Result: yes
```

**Solution:**
1. **Patch the deployment to use privacera-sa:**
   ```bash
   kubectl patch deployment mariadb -n candidate-test -p '{"spec":{"template":{"spec":{"serviceAccountName":"privacera-sa"}}}}'
   ```

2. **Create the missing PVC manually:**
   ```bash
   cat <<EOF | kubectl apply -f -
   apiVersion: v1
   kind: PersistentVolumeClaim
   metadata:
     name: candidate-test-mariadb-pvc
     namespace: candidate-test
   spec:
     storageClassName: candidate-test-store-privacera-mariadb
     accessModes:
     - ReadWriteOnce
     resources:
       requests:
         storage: 2048M
   EOF
   ```

3. **Verify the fix:**
   ```bash
   kubectl get pvc -n candidate-test
   kubectl get pods -n candidate-test | grep mariadb
   ```

**Additional Components with PVC Issues:**

**Note:** Storage class names follow the pattern `candidate-test-store-<component-name>`. If a PVC creation fails, verify the correct storage class name exists in your cluster.

**For connector-snowflake-test:**
```bash
# Create missing PVC
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: candidate-test-connector-snowflake-test-rocksdb-pvc
  namespace: candidate-test
spec:
  storageClassName: candidate-test-store-connector-snowflake-test
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 1024M
EOF
```

**For diagnostics-server:**
```bash
# Create missing PVC
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: candidate-test-diagnostics-server-pvc
  namespace: candidate-test
spec:
  storageClassName: candidate-test-store-diagnostics-server
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 1024M
EOF
```

**For grafana-candidate-test:**
```bash
# Create missing PVC
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: grafana-candidate-test
  namespace: candidate-test
spec:
  storageClassName: candidate-test-store-privacera-grafana
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 1024M
EOF
```



### **Prevention Best Practices**

1. **Always use `privacera-sa`** for components that need PVC creation
2. **Verify service account permissions** before deployment
3. **Monitor Helm installation** for partial failures
4. **Check PVC creation** immediately after deployment
5. **Use consistent service account** across all components

### **Useful Commands for Troubleshooting**

```bash
# Check all resources in namespace
kubectl get all -n candidate-test

# Check PVCs
kubectl get pvc -n candidate-test

# Check service accounts
kubectl get serviceaccount -n candidate-test

# Check RBAC permissions
kubectl get rolebinding -n candidate-test
kubectl get role -n candidate-test

# Check pod events
kubectl get events -n candidate-test --sort-by='.lastTimestamp'

# Check Helm releases
helm list -n candidate-test
helm status <release-name> -n candidate-test

# Check service account permissions
kubectl auth can-i create persistentvolumeclaims --as=system:serviceaccount:candidate-test:<sa-name> -n candidate-test
```

## 📚 Documentation Links

### **Official Privacera Documentation**
- **[Privacera Prerequisites](https://docs.privacera.com/get-started/base-installation/privaceracloud-data-plane/prerequisites.html)**
- **[Privacera Documentation Hub](https://docs.privacera.com/)**
- **[Base Installation Guide](https://docs.privacera.com/get-started/base-installation/)**

### **Technical References**
- **[GitHub Actions Documentation](https://docs.github.com/en/actions)**
- **[Kubernetes Documentation](https://kubernetes.io/docs/)**
- **[AWS EKS Documentation](https://docs.aws.amazon.com/eks/)**

---
