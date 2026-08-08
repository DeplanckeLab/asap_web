# Concurrent jobs and fair scheduling (Slurm)

**Restarting Docker Compose or Slurm:** see **`docs/RESTART_DOCKER_AND_SLURM.md.example`** (site-specific copies without `.example` are gitignored).

## Parallel runs on one server

ASAP sets `#SBATCH --mem` **only when `pred_max_ram` is present**. If there is no prediction model yet, the batch script omits `--mem` on purpose (no memory constraint from the app).

With `SelectTypeParameters=CR_Core_Memory`, Slurm’s default for a missing `--mem` is to reserve **the whole node’s RAM**, which blocks other jobs. Set **`DefMemPerCPU`** so “no prediction” jobs get a modest per-CPU default instead, while jobs that do have a prediction still reserve their predicted `--mem`:

```conf
SelectType=select/cons_tres
SelectTypeParameters=CR_Core_Memory
DefMemPerCPU=4096
SchedulerParameters=bf_continue
```

| Job | ASAP script | Slurm packing |
|-----|-------------|-----------------|
| No `pred_max_ram` | omit `--mem` | `DefMemPerCPU × CPUs` (not whole node) |
| Has `pred_max_ram` | `#SBATCH --mem=<predicted>M` | that amount |

`ConstrainRAMSpace=no` means these values are **scheduling reservations**, not hard cgroup kills.

**Deploy** to the controller, then reconfigure/restart as needed:

```bash
sudo cp -a /etc/slurm/slurm.conf /etc/slurm/slurm.conf.bak.$(date +%Y%m%d_%H%M%S)
# keep CR_Core_Memory; uncomment/set DefMemPerCPU (MB per CPU), e.g.:
sudo sed -i 's/^#DefMemPerCPU=0/DefMemPerCPU=4096/' /etc/slurm/slurm.conf
sudo scontrol reconfigure
```

**Check:** `scontrol show config | grep DefMemPerCPU`. Two jobs without `--mem` should both reach **R** while CPUs allow.

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

- **Fair-share** deprioritizes accounts that have **recently used more** CPU time.
- **Age** helps long-waiting jobs.

For fair-share per ASAP user, jobs use `--account=user_<id>` (`SlurmService`). Ensure **`slurmdbd`** and associations in **`sacctmgr`**.

### Optional: stricter per-user caps

Use **QOS** or **association limits** in `sacctmgr`.

## Why `select/linear` blocked concurrency

With `SelectType=select/linear`, Slurm allocates **whole nodes**. On a **one-node** cluster, only **one** job ran at a time. Use `select/cons_tres` (above) or add more nodes.

## Troubleshooting: jobs stuck PENDING (Resources)

1. **Pending reason**
   ```bash
   squeue -j JOBID -o "%.18i %.2t %20R %30r"
   scontrol show job JOBID | grep -E 'JobState|Reason|TRES|MinMemory|NumCPUs'
   ```
   - **`Resources`** with `mem=` equal to full `RealMemory` and no `#SBATCH --mem` in the script: missing **`DefMemPerCPU`** under `CR_Core_Memory`.
   - **`Resources`** with a large predicted `--mem`**: not enough free RAM in Slurm’s accounting (or prediction too high).
   - **`Resources`** with high CPU request: not enough free CPUs.

2. **Node state** — `sinfo -N -l`; nodes must be IDLE/ALLOC/MIXED.

3. **Accounting** — `slurmdbd` / associations.

## Quick reference

| Goal | Action |
|------|--------|
| No prediction → no app `--mem`, still parallel | `CR_Core_Memory` + **`DefMemPerCPU`** |
| Prediction set → reserve predicted RAM | ASAP `pred_max_ram` → `#SBATCH --mem` |
| More jobs by hardware | Add nodes (`SLURM_ADD_COMPUTE_NODES.md`) |
| Fairness between ASAP users | Fair-share + `user_*` accounts |
