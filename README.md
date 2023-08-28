# aws-hcp-consul-tg
This repo builds the required AWS Networking, EKS clusters, and HCP Consul 1.16.0 resources to demo the following service mesh use cases.
* Use Admin Partitions to manage multiple EKS clusters
* Support K8s namespaces with Consul namespaces 1/1.
* Implement a terminating gateway to securely egress from the service mesh.

In this repo you will provision the initial infrastructure, and validate 3 use cases. First, setup a single EKS cluster svc to svc use case, then a multi cluster svc to svc use case, and finally show how a terminating gateway is required for a service to securely egress from the service mesh.
![Architecture](https://github.com/ppresto/aws-hcp-consul-tg/blob/main/architecture.png?raw=true)

## Pre Reqs
- Consul Enterprise License `./files/consul.lic`
- Setup shell with AWS credentials 
- Setup [HCP service principle](https://support.hashicorp.com/hc/en-us/articles/4404391219091-Managing-Service-Principal-Credentials-in-HCP)
- Terraform 1.3.7+
- aws cli
- kubectl
- helm

## Provision Infrastructure
Use terraform to build the AWS and HCP Infrastructure. First setup your shell with the following variables to access HCP and AWS.
```
export HCP_CLIENT_ID=""
export HCP_CLIENT_SECRET=""
export AWS_SECRET_ACCESS_KEY=
export AWS_ACCESS_KEY_ID=
```

Update `my.auto.tfvars` **with your SSH key pair.**
```
cd quickstart/1hcp-2vpc-3eks
terraform init
terraform apply -auto-approve
```

### Connect to EKS 
Use `scripts/kubectl_connect_eks.sh` to authenticate to EKS clusters and create context aliases.  Pass this script the path to the terraform state file used to provision the EKS cluster.  If cwd is ./1hcp-2vpc-3eks like above then source this script with the current working directory `.` as the first param like below:
```
source ../../scripts/kubectl_connect_eks_wProfile.sh .
```
This script connects EKS and builds some useful kubectl aliases shown in the output.

### Install AWS LB Controller on all EKS clusters
The Terraform created the necesary policies to support this controller. The full helm chart installation is possible in Terraform but was commented out because the helm/kubectl providers require specific EKS credentials making it hard to manage multipe EKS clusters in a single run.  This shouldn't be an issue in most workflows, but that said, Helm installs are often managed with a different CI/CD tool in your pipeline.  Install the AWS LB Controller to enable the HCP Consul helm chart to build NLB.  Internal NLB will be used to route all service mesh traffic on the internal network through Consul Mesh gateways.
```
source ../../scripts/install_awslb_controller.sh .
```

## Install Consul dataplane
This repo uses Terraform's Helm provider to install the Consul dataplane because it can easily pull the necessary HCP Consul and EKS values from the terraform.tfstate.  In addition it creates the helm values.yaml template that anyone running Helm on the CLI or using other CI/CD tools would probably want to use.  These templates can be found in `./consul_helm_values/yaml/`
```
terraform -chdir="consul_helm_values" init
terraform -chdir="consul_helm_values" apply -auto-approve
```

### Setup Consul CLI in local shell
Consul has many different ways it can be configured (for example the UI, CRD, API, and CLI). For example, this repo will use the Consul CLI to create service policies for the Terminating GW role to attach.  To use the Consul CLI to configure HCP Consul first setup the local shell environment.  If cwd is ./1hcp-2vpc-3eks then source this script with the current working directory `.` as the first param like below:
```
source ../../scripts/setConsulEnv.sh .
```
The output from this script gives the URL to the Consul UI and root token.  Use this to login to Consul with your browser.
Additionally, test the CLI is setup properly by listing the consul members `consul members`.

## Configure Consul
### Start - HCP / Consul UI
Login to the UI and review the Admin Partitions drop down. Partitions support 1-1000s of K8s clusters providing true multi-tenancy for each one.
* default(Admin Partition) / default(Consul Namespace) - Hosts the HCP Consul Cluster (1-3 servers)
* web / default - `web` is the partition where the first EKS cluster is connected.
Read the docs to learn more about [Admin Partitions](https://developer.hashicorp.com/consul/docs/enterprise/admin-partitions).

### Deploy Services to the first EKS context: `web1`
Use CLI or K9s and review the empty EKS cluster before deploying services.  If using the scripts in this repo the K8s cluster should have a context alias `web1`.  In the first EKS cluster 2 services will be deployed in their own K8s namespaces to simulate what a large multi-tenant cluster might look like with every service having its own namespace.
```
web1
kubectl -n web get po
kubectl -n api get po
```

Deploy web and api services to the first EKS cluster connected to Consul Partition named `web`.
```
../../examples/multi-tenant-dataplane-ap-ns-tgw/fake-service/web/deploy.sh
```
While deploying api and web services the script above also configures the ingress-gateway to route to web.  This will allow a local browser (external to the mesh) to access web. View the ingress-gateway configuration in `../../multi-tenant-dataplane-ap-ns-tgw/fake-service/web/init-consul-config/ingressGW.yaml`.  This gateway was initially configured in the helm values which can be reviewed in any file here: `./consul_helm_values/yaml/`.  The ingress-gateway is mapped to a K8s service which is using an internet facing load balancer on port 8080 and can be looked up with kubectl.  FYI:  Need to upgrade this config to use the [api-gateway](https://developer.hashicorp.com/consul/docs/api-gateway) instead!
```
web1
kubectl -n consul get svc -l component=ingress-gateway
```
* Go to fake-service URL that was output from the script above to see the fake-service UI.  The DNS propogation may take a couple minutes so be patient.
* Review Pods in both namespaces
```
web1
kubectl get po -A -l service=fake-service
```
* Review Consul Admin Partition `web`.  The ingress-gw was configured to access fake-service, and the mesh-gw will be used to connect to the second EKS cluster.  The terminating-gw is not actually being used here.
* Review Consul Namespaces in the Admin Partition `web`.  These will be automatically created and map 1/1 to the K8s namespaces you see in our terminal.  Read the docs to learn more about using [Namespaces](https://developer.hashicorp.com/consul/docs/enterprise/namespaces).


### Verify Encryption (optional)
`web->api` traffic will go through the envoy sidecar which sends traffic on port 20000.  Verify the traffic is encrypted by attaching a debug container (nicolaka/netshoot) to the dataplane sidecar on the source service `web`.  The following tcpdump command will look at all outgoing traffic on the default envoy port 20000.  Attach a debug container with a command something like this `kubectl debug -it --context web1 -n web $POD --target consul-dataplane --image nicolaka/netshoot`.  Once inside the debug container run tcpdump.
```
tcpdump tcp and src $(hostname -i) and dst port 20000 -A
```
With the above command running generate traffic by refreshing the fake-service browser tab.  The tcpdump should show all encrypted traffic.

## Deploy services to the second EKS context: `api1`
This EKS cluster is using a context alias of `api1` and its connected to a new partition called `api`. In this step you will deploy a new api service that has permissions to access an external endpoint `https://example.com`.   Once completed, go back to the first EKS cluster `web1` and redeploy a new version of the web service that will point to its local `api` service like before and to the new  `api` services running on the second EKS cluster `api1`.  Run the following scripts to complete the new deployments.

```
../../examples/multi-tenant-dataplane-ap-ns-tgw/fake-service/api/deploy.sh
../../examples/multi-tenant-dataplane-ap-ns-tgw/fake-service/web-final/deploy.sh
```
During this deployment and our previous deployment both EKS clusters configured their proxydefaults to route all requests through their 'local' mesh-gateway.  If a service is not located on the same EKS cluster but is part of the service mesh on a different EKS cluster, any requests to that service will first be directed to the local mesh-gateway. From there, the requests will be routed to the mesh-gateway of the remote EKS cluster, which will then forward the requests to the intended service.  This is the recommended design, but it can be set for remote only, and for none depending on your design requirements.
Consult the documentation to gain further insights into [mesh-gateways](https://developer.hashicorp.com/consul/docs/connect/gateways#mesh-gateways).

* Review the new Consul Partition in the UI `api` which is the EKS cluster `api1`.  Notice in this cluster the api service is deployed into the default K8s namespace.
```
api1
kubectl get po -A -l service=fake-service
```

* Review the EKS Cluster `web1` to verify the health of the restarted pods.
```
web1
kubectl get po -A
```
Note: The EKS node may be at the pod ip limit so the web-final/deploy.sh is removing the deployment and redeploying.  This can cause some delay while the CNI driver is allocating an available IP.
### Walk through the terminating GW setup
The new EKS cluster `api1` will deploy a service called api that's authorized to make external requests to `https://example.com`.  In the api deployment script above 3 CRDs were used to configure Consul's terminating-gateway.  Review them below.
```
/examples/multi-tenant-dataplane-ap-ns-tgw/terminating-gw-example.com/
```
* servicedefaults.yaml - define the virtual service as https-example
* terminating-gw.yaml - link the virtual service to the terminating gateway
* intentions.yaml      - authorize the local api service to access the virtual service linked to the terminating gateway

In the previous step, we also redeployed `web` to point to the new `api` service hosted in the second EKS cluster. This new `api` service needs to egress through the service mesh terminating-gateway to securely access https://example.com.

### Verify `web` -> `api` -> `https-example`
Refresh fake-service in the browser tab.  The `web` service should be pointing to both `api` services successfully with the new service showing successfully accessing its external upstream https://example.com.  If the web panel is red or not responding this may mean K8s needs a little more time to complete the recent deployments so be patient.

### Delete the https-example intention to verify authZ is required.
Consul uses Intentions by default to enforce authorization.  By removing the intention below the `api` service will no longer be able to get to `https://example.com`.
```
api1
kubectl delete -f ../../examples/multi-tenant-dataplane-ap-ns-tgw/terminating-gw-example.com/intention.yaml
```
Refresh the fake-service UI to see the request to https://example.com fail.

### Add the intention back
```
api1
kubectl apply -f ../../examples/multi-tenant-dataplane-ap-ns-tgw/terminating-gw-example.com/intention.yaml
```
Refresh the fake-service UI to see the request to https://example.com succeed.  Click on this link to learn more about the [terminating-gateway](https://developer.hashicorp.com/consul/docs/connect/gateways#terminating-gateways).

## Clean up
```
../../examples/multi-tenant-dataplane-ap-ns-tgw/deploy.sh -d
```

### Quickstart/Test
To skip all steps below and configure the full environment run this script.
```
../../examples/multi-tenant-dataplane-ap-ns-tgw/deploy.sh
```