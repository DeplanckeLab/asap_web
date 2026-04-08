# Concurrent jobs and fair scheduling (Slurm)

**Restarting Docker Compose or Slurm:** see **[RESTART_DOCKER_AND_SLURM.md](RESTART_DOCKER_AND_SLURM.md)**.

## Parallel runs on one server

The repo template `slurm/slurm.conf` uses **consumable** CPU and memory on each node so **multiple jobs can run at once** on the same machine:

```conf
SelectType=select/cons_tres
SelectTypeParameters=CR_Core_Memory
SchedulerParameters=bf_continue
```

- **`select/cons_tres`** schedules by requested `--cpus-per-task` and `--mem` (from `SlurmService`), not whole nodes.
- **`CR_Core_Memory`** tracks cores and RAM from each `NodeName` line (`CPUs=`, `RealMemory=`).
- **`bf_continue`** lets the backfill scheduler yield so queued work is re-evaluated as resources free up.

**Deploy** the edited file to the controller (and nodes if you maintain copies), then:

```bash
sudo scontrol reconfigure
# If the daemon ignores the change:
sudo systemctl restart slurmctld
sudo systemctl restart slurmd   # on each compute node
```

**Check:** submit two small test jobs; both should reach **R** on the same `NODELIST` while resources allow.

### Cgroups and Docker

The template may keep `LaunchParameters=disable_cgroup` and `ProctrackType=proctrack/pgid` for compatibility with `docker run` inside jobs. Slurm can still **place** several jobs using requested TRES; **hard** CPU/RAM enforcement is stronger with `proctrack/cgroup`, `task/cgroup`, and a tested `cgroup.conf`. Adjust only after validating ASAP pipelines.

## Fairness between users (not strict round-robin)

Slurm does **not** implement “job A from user 1, then job B from user 2, strictly alternating” as a built-in mode. The supported approach is **multifactor priority** with a **strong fair-share** component on **associations** (accounts), e.g. `user_123` from `#SBATCH --account=user_123`.

The template sets:

```conf
PriorityType=priority/multifactor
PriorityFlags=FAIR_TREE
PriorityWeightFairShare=50000
PriorityWeightAge=5000
PriorityWeightPartition=100
PriorityWeightJobSize=50
```

- **Fair-share** deprioritizes accounts that have **recently used more** CPU time (so a heavy user does not keep winning the queue forever).
- **Age** helps long-waiting jobs.
- **Job size** has lower weight so huge `--mem` requests do not always beat fair-share.

For fair-share to apply per ASAP user, each Slurm job should use a **distinct account** (the app already passes `--account=user_<id>` in `SlurmService` when `user_id` is set). Ensure **`slurmdbd`** accounting is working and, if needed, define associations in **`sacctmgr`** (user/account/cluster, fairshare values). Without associations, priority may fall back to other factors only.

### Optional: stricter per-user caps

To limit blast radius (e.g. max running jobs per user), use **QOS** or **association limits** in `sacctmgr`, not `slurm.conf` alone. That is policy-specific.

## Why `select/linear` blocked concurrency

With `SelectType=select/linear`, Slurm allocates **whole nodes**. On a **one-node** cluster, only **one** job ran at a time regardless of `#SBATCH` requests. Use `select/cons_tres` (above) or add more nodes.

## Troubleshooting: nothing runs after switching to `cons_tres` (all jobs PD)

That is **not** the expected outcome. `cons_tres` should still run **at least one** job when the node is healthy and the job fits. If **every** job stays pending and **none** reach **R**, treat it as a cluster or resource definition problem, not ASAP queue text.

**Why it looked fine with `linear`:** whole-node allocation hides many mistakes. Slurm gave the **entire node** to one job, so a bad `#SBATCH --mem` line or an approximate `RealMemory=` in `slurm.conf` often still worked. With **`CR_Core_Memory`**, Slurm schedules from **declared** CPUs and RAM on each `NodeName` line and from each job’s `--cpus-per-task` and `--mem` (`SlurmService`). If the math does not add up, jobs can sit in **PD** forever.

**Check in order:**

1. **Pending reason (most important)**  
   For a stuck job id:
   ```bash
   squeue -j JOBID -o "%.18i %.2t %20R %30r"
   ```
   Read the **REASON** / **NODELIST(REASON)** field. Typical values:
   - **`Resources`** / **`ReqNodeNotAvail`**: job wants more CPU or RAM than Slurm thinks any node in the partition can offer, or nodes are not usable.
   - **`PartitionConfig`**, **`QOS` limits**, **`AssocMax`**: limits or accounting; fix associations or QOS in `sacctmgr`.
   - **Empty reason but PD**: often node state or controller not scheduling (see below).

2. **Node state and slurmd**  
   ```bash
   sinfo -N -l
   scontrol show node NODENAME
   ```
   Nodes must be **IDLE**, **ALLOC**, or **MIXED**, not **DOWN**, **DRAIN**, or stuck **UNKNOWN** without a running **slurmd**. After changing `SelectType`, restart **`slurmctld`** and **`slurmd`** on each compute host (not only `scontrol reconfigure`).

3. **`RealMemory` and job `--mem`**  
   ASAP submits `#SBATCH --mem=<MB>M` from predicted RAM (`SlurmService`). If **`RealMemory=`** on the node line is too low, or the prediction is huge, **no** slot may satisfy the request. Compare the job script under the project’s step directory (`slurm_<run_id>.sh`) to `RealMemory=` and host RAM.

4. **Accounting**  
   If **`slurmdbd`** is down or associations are missing, some sites block scheduling. Check `sacctmgr show assoc` and controller logs for accounting errors.

**Summary:** “Before reconfigure one job at a time, after reconfigure none run” usually means **node not schedulable**, **`RealMemory`/CPU vs `--mem`/`--cpus` mismatch**, or **pending reason** pointing at **Resources** / limits. Fix that on the Slurm side; the web app only submits the same style of `sbatch` script as before.

## Quick reference

| Goal | Action |
|------|--------|
| More jobs on **one** host | `select/cons_tres` + `CR_Core_Memory` (in repo template) |
| More jobs by hardware | Add nodes (`SLURM_ADD_COMPUTE_NODES.md`) |
| Fairness between ASAP users | Fair-share weights + `FAIR_TREE` + accounting + `user_*` accounts |
