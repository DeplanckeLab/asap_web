# Adding SLURM compute nodes

**Concurrency on a single machine:** if you have one node but want **several jobs at once**, the blocker is often `SelectType=select/linear` (whole-node allocation). See **`SLURM_CONCURRENT_JOBS.md`**.

This cluster uses **Slurm on the host** (controller + `slurmd`), with the Rails app submitting jobs via client tools (see `slurm/MIGRATION_TO_HOST.md`). Adding throughput means registering **additional machines** that run `slurmd` and are listed in `slurm.conf` on the **control host**.

## Why one job filled the node

With a **single** `NodeName` in the default partition, Slurm can only place jobs on that host. Pending jobs with reason `(Resources)` are waiting for **CPU/RAM** (or the **whole node** if requests are large) to become free. **More nodes** give more concurrent allocations.

## Prerequisites on every new compute node

1. **Same OS family and Slurm major version** as `slurmctld` (e.g. RHEL 9 packages matching the controller).
2. **Munge**: the **same** `/etc/munge/munge.key` as on the controller (and existing nodes). Without it, `slurmd` will not authenticate.
3. **Network**
   - From node → controller: Slurm ports (typically **6817** for `slurmctld`, **6819** if the node must talk to `slurmdbd` depending on your layout).
   - Controller → node: **6818** for `slurmd`.
   - From node → **Docker registry** and any hosts needed for `docker pull` / `docker run` used by pipelines.
4. **Shared project data**: ASAP runs use paths under `USER_DATA_DIR` (e.g. `/data/asap2_test/...`). Each compute node must see the **same files** as the website (NFS or equivalent). Local disk-only copies are not enough unless you change the architecture.
5. **Docker**: Jobs are often launched as `docker run` on the **compute node**. Install Docker, grant the Slurm job user access to the **docker socket** where appropriate, and ensure **ASAP_RUN_DOCKER_NETWORK** (or your compose network) is consistent so containers can reach Postgres and other services.
6. **Hostname/DNS**: `NodeName` in `slurm.conf` must resolve (or use `NodeAddr`) from the controller.

## Steps (outline)

### 1. Install packages on the new node

Example (RHEL-like):

```bash
sudo dnf install -y slurm slurm-slurmd munge munge-libs
```

Align **Slurm package versions** with the controller.

### 2. Copy `slurm.conf` from the controller

The node needs a `slurm.conf` consistent with the cluster (same `AuthType`, `PluginDir`, accounting settings, and **full** `NodeName` / `PartitionName` blocks). Copy from `/etc/slurm/slurm.conf` on the control machine after you edit it (step 4).

### 3. Install the munge key

```bash
sudo install -d -o munge -g munge -m 0700 /etc/munge
sudo install -o munge -g munge -m 0400 /path/from/controller/munge.key /etc/munge/munge.key
sudo systemctl enable --now munge
```

### 4. Register the node on the controller

On the machine where **`slurmctld`** runs, edit `slurm.conf` (the repo file is `slurm/slurm.conf`; production is usually `/etc/slurm/slurm.conf`):

- Add a line:

  `NodeName=<short-or-fqdn> NodeAddr=<ip> CPUs=... RealMemory=... State=UNKNOWN`

  Use `scontrol show node` on an existing node as a template for CPU/memory fields, or use `slurm/configure_resources.sh` patterns. **RealMemory** is in megabytes.

- Extend the partition so jobs can run there, for example:

  `PartitionName=debug Nodes=node1,node2 Default=YES MaxTime=INFINITE State=UP`

  The Rails app does not set `#SBATCH --partition` by default; it uses the **default** partition (`SlurmService#build_slurm_script`).

Then reload the controller (typical):

```bash
sudo scontrol reconfigure
# if needed:
sudo systemctl restart slurmctld
```

### 5. Start `slurmd` on the new node

```bash
sudo systemctl enable --now slurmd
```

### 6. Verify

From the controller or any client:

```bash
sinfo -Nel
scontrol show node <new-node-name>
```

The node should reach **IDLE** (or mixed), not **DOWN** / **NOT_RESPONDING**.

## Repo template

See commented examples at the bottom of `slurm/slurm.conf`. Replace placeholders with real hostnames, IPs, and hardware counts before enabling.

## Optional: separate partition for production

You can define e.g. `PartitionName=compute Nodes=...` and keep `debug` for one host. Then you must pass `--partition=compute` in job scripts (would require an application change in `SlurmService` unless you change which partition is `Default=YES`).

## Rollback

Remove the node from `PartitionName` and `NodeName` lines, `scontrol reconfigure`, then stop `slurmd` on that host.
