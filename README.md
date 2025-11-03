# mock-ai-topology

This project makes use of [containerlab](https://github.com/srl-labs/containerlab) and kind and iWARP to mock a network topology for AI cluster

## installation

1. [install containerlab](https://containerlab.dev/install/)

`bash -c "$(curl -sL https://get.containerlab.dev)"`

2. do not install mellanox's OFED, which conflicts with iWARP ko

3. docker and kind

## get started

```bash

# setup the cluster
cd simple-topoloty
./setup.sh deploy --http-proxy "http://10.64.1.179:7890"

# show containers
docker ps
        CONTAINER ID   IMAGE                                    COMMAND                  CREATED         STATUS                   PORTS                                                                                  NAMES
        9ab4a6136daa   kindest/node:v1.32.2                     "/usr/local/bin/entr…"   2 minutes ago   Up 2 minutes                                                                                                    ai-kind-rdma-cluster-worker
        d1bba4638d4f   kindest/node:v1.32.2                     "/usr/local/bin/entr…"   2 minutes ago   Up 2 minutes                                                                                                    ai-kind-rdma-cluster-worker2
        77e255e9652d   kindest/node:v1.32.2                     "/usr/local/bin/entr…"   2 minutes ago   Up 2 minutes                                                                                                    ai-kind-rdma-cluster-worker4
        aedace9c2a92   kindest/node:v1.32.2                     "/usr/local/bin/entr…"   2 minutes ago   Up 2 minutes                                                                                                    ai-kind-rdma-cluster-worker3
        7d3b187f3d57   kindest/node:v1.32.2                     "/usr/local/bin/entr…"   2 minutes ago   Up 2 minutes             127.0.0.1:5829->6443/tcp                                                               ai-kind-rdma-cluster-control-plane
        1a1b97dcb01c   ghcr.io/nokia/srlinux:25.7               "/tini -- /usr/local…"   2 minutes ago   Up 2 minutes                                                                                                    clab-ai-kind-rdma-storage-switch
        43dbe97178f3   ghcr.io/nokia/srlinux:25.7               "/tini -- /usr/local…"   2 minutes ago   Up 2 minutes                                                                                                    clab-ai-kind-rdma-leaf5
        1431202c8c72   ghcr.io/nokia/srlinux:25.7               "/tini -- /usr/local…"   2 minutes ago   Up 2 minutes                                                                                                    clab-ai-kind-rdma-leaf3
        bcf3803bda49   ghcr.io/nokia/srlinux:25.7               "/tini -- /usr/local…"   2 minutes ago   Up 2 minutes                                                                                                    clab-ai-kind-rdma-leaf6
        45fb9c79be95   ghcr.io/nokia/srlinux:25.7               "/tini -- /usr/local…"   2 minutes ago   Up 2 minutes                                                                                                    clab-ai-kind-rdma-spine1
        f53c40c7e699   ghcr.io/nokia/srlinux:25.7               "/tini -- /usr/local…"   2 minutes ago   Up 2 minutes                                                                                                    clab-ai-kind-rdma-leaf1
        07c8607062ee   ghcr.io/nokia/srlinux:25.7               "/tini -- /usr/local…"   2 minutes ago   Up 2 minutes                                                                                                    clab-ai-kind-rdma-leaf8
        054e1a5a9b43   ghcr.io/nokia/srlinux:25.7               "/tini -- /usr/local…"   2 minutes ago   Up 2 minutes                                                                                                    clab-ai-kind-rdma-leaf4
        8908c46e49ac   ghcr.io/nokia/srlinux:25.7               "/tini -- /usr/local…"   2 minutes ago   Up 2 minutes                                                                                                    clab-ai-kind-rdma-leaf7
        19d8a45f0775   ghcr.io/nokia/srlinux:25.7               "/tini -- /usr/local…"   2 minutes ago   Up 2 minutes                                                                                                    clab-ai-kind-rdma-leaf2
        0ca93c68a1ea   debian:12                                "bash"                   2 minutes ago   Up 2 minutes                                                                                                    clab-ai-kind-rdma-storage-host

# show neighbor on each node
./setup.sh show

# destroy
./setup.sh destroy

```

## to-do

- more complex topology 
- mock server for scale up 
- connect the control-plane port of the switch with the K8s node
- an agent generate tcp packets to trigger metrics in switches


