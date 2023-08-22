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
- Setup shell with HCP credentials if using HCP
- Terraform 1.3.7+
- aws cli
- kubectl
- helm

## Provision Infrastructure
Use terraform to build AWS Infrastructure.  Update `my.auto.tfvars` with your SSH key pair.
```
cd quickstart/1hcp-2vpc-3eks
terraform init
terraform apply -auto-approve
```

### Connect to EKS 
Use `scripts/kubectl_connect_eks.sh`.  Pass this script the path to the terraform state file used to provision the EKS cluster.  If cwd is ./1hcp-2vpc-3eks like above then this command would look like the following:
```
source ../../scripts/kubectl_connect_eks_wProfile.sh .
```
This script connects EKS and builds some useful aliases shown in the output.

### Install AWS LB Controller on all EKS clusters
```
source ../../scripts/install_awslb_controller.sh .
```

## Install Consul
```
terraform -chdir="consul_helm_values" init
terraform -chdir="consul_helm_values" apply -auto-approve
```

### Setup Consul CLI in local shell
The Consul CLI will be used to create service policies for the Terminating GW role to attach.
```
source ../../scripts/setConsulEnv.sh .
```
The output from this script gives the URL to the Consul UI and root token to signin.

## Demo

### Quickstart/Test
To skip all steps below and configure the full demo run this script.
```
../../examples/multi-tenant-dataplane-ap-ns-tgw/deploy.sh
```
### Start - HCP / Consul UI
Login to the UI and explain how Admin Partitions support 1-1000s of K8s clusters for true multi-tenancy.
* Default/Default - 3 HCP Consul Servers
* Web/Default - Onboarding first EKS cluster to partition `web`

### Deploy Services to the first EKS context: `web1`
Use CLI or K9s and review empty EKS cluster before deploying services
```
web1
kubectl -n web get po
kubectl -n api get po
```

Deploy web and api services to the first EKS cluster connected to Consul Partition `web`
```
../../examples/multi-tenant-dataplane-ap-ns-tgw/fake-service/web/deploy.sh
```
* Review Pods in both namespaces
* Review Consul Namespaces in the UI
* Go to fake-service URL

### Verify Encryption
`web->api` traffic will go through the envoy sidecar which sends traffic on port 20000.  Verify the traffic is encrypted by attaching a debug container (nicolaka/netshoot) to the dataplane sidecar on the source service `web`.  The following tcpdump command will look at outgoing traffic on the default envoy port 20000.
```
tcpdump tcp and src $(hostname -i) and dst port 20000 -A
```
attach debug container: `kubectl debug -it --context web1 -n web $POD --target consul-dataplane --image nicolaka/netshoot`

## Deploy services to the second EKS context: `api1`
This EKS cluster is connected to the new partition `api`. Deploy a new api service and redeploy web-final so it points to both local and remote `api` services.  
* In Consul 1.16.0 the mgw needs to be bounced because web was deployed before api.  Not sure why.

```
../../examples/multi-tenant-dataplane-ap-ns-tgw/fake-service/api/deploy.sh
../../examples/multi-tenant-dataplane-ap-ns-tgw/fake-service/web-final/deploy.sh
```
* Review the EKS cluster
* Review the new Consul Partition in the UI
* Review EKS Cluster web1 to see health of restarted pods (mgw, web)

### Walk through terminating GW setup
The new EKS cluster will deploy a service called `api` that's authorized to make external requests to example.com.
```
/examples/multi-tenant-dataplane-ap-ns-tgw/terminating-gw-example.com/
```
* servicedefaults.yaml
* terminating-gw.yaml
* intentions.yaml

In the previous step, we also redeployed `web` to point to the new `api` service hosted in the second EKS cluster. This new `api` service needs to egress from the service mesh to securely access https://example.com.

### Verify `web` -> `api` -> `https-example`
Refresh browser

### Delete the https-example intention to verify authZ is required.
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
Refresh the fake-service UI to see the request to https://example.com succeed.

## Clean up
```
../../examples/multi-tenant-dataplane-ap-ns-tgw/deploy.sh -d
```