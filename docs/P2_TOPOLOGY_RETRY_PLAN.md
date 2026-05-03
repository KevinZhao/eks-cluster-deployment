# P2 — Topology retry loop + best-effort strategy

## Background

P1 (merged as branch `feat/placement-group-and-topology-gate`) added:
- Auto-creating cluster placement groups per (AZ, purchase_option)
- LT `Placement.GroupName` injection
- Post-ACTIVE topology gate with strict/warn/off modes

Real-machine test on 2026-05-03 (Stage 6 R1b preflight) revealed:
1. **Cluster PG does NOT guarantee same-leaf (L3)** on p5en.48xlarge in
   us-west-2c. Two Spot instances, both admitted to the same PG, landed
   on different L3 leaves.
2. P1's strict-mode gate correctly detected the L3 mismatch and scaled
   the NG to 0 — but the operator then had to manually retry (which is
   P1's designed behavior).

Getting same-leaf is therefore a **probabilistic event** at Spot
time. To reach bench-quality placement reliably, we need an automated
retry loop.

## P2 scope

1. **Retry logic in `verify_topology`**:
   - New env: `GPU_TOPOLOGY_RETRIES` (default: `3`)
   - New env: `GPU_TOPOLOGY_RETRY_DELAY_SEC` (default: `60`)
   - On strict-mode failure: instead of just scaling NG to 0, do:
     a) Scale to 0 (release the misplaced instances)
     b) Wait for instances to fully terminate
     c) Scale back to original desired
     d) Wait for new instances InService
     e) Re-run topology verification
     f) If still fails: decrement retry counter, loop
     g) If retries exhausted: final strict-mode fail (NG=0, return 1)

2. **Best-effort strategy**:
   - `GPU_PG_STRATEGY=cluster_best_effort` (already defined in P1 but
     not implemented). Behavior:
     - Try to create NG with PG first
     - If `InsufficientInstanceCapacity` from ASG events in first N min:
       auto-update LT to drop Placement → create new version → update NG
     - Accept cross-leaf as fallback
   - `GPU_PG_STRATEGY=cluster` (strict, existing default): fail if capacity
     not available with PG

3. **Gate level auto-degrade**:
   - Optional: `GPU_TOPOLOGY_GATE_LEVEL=auto` — try L3 first for N retries,
     fallback to L2, finally L1
   - Useful for workloads that want "best available same-topology" not
     "require same-leaf or die"

4. **Retry telemetry**:
   - Log to `/tmp/topology-retry-<ng>.json` each retry's instance IDs,
     L1/L2/L3 nodes, and decision
   - Report total retries used at end
   - Useful for tracking "AZ X gives us 60% same-leaf rate, AZ Y gives 20%"

## Out of scope for P2 (defer to P3)

- Cross-AZ fallback (if all retries fail in AZ X, try AZ Y)
- SPS-driven dynamic AZ selection
- NG size splitting (desired > PG capacity)
- PG cleanup on teardown automation

## Implementation sketch

```bash
# Extended verify_topology (replaces current body after strict-mode fires)
verify_topology_with_retry() {
    local ng_name=$1 gate=$2 level=$3
    local retries_left=${GPU_TOPOLOGY_RETRIES:-3}
    local delay=${GPU_TOPOLOGY_RETRY_DELAY_SEC:-60}

    # Save original desired for restore
    local original_desired=$(aws eks describe-nodegroup ... \
        --query 'nodegroup.scalingConfig.desiredSize' --output text)

    local attempt=0
    while :; do
        attempt=$((attempt + 1))
        echo "Topology attempt ${attempt}/$((retries_left + 1))..."

        if verify_topology "${ng_name}" "warn" "${level}"; then
            echo "  ✅ Topology gate passed on attempt ${attempt}"
            return 0
        fi

        if [ "${retries_left}" -le 0 ]; then
            echo "  ❌ Exhausted retries. Final scale to 0."
            if [ "${gate}" = "strict" ]; then
                aws eks update-nodegroup-config ... --scaling-config \
                    "minSize=0,maxSize=1,desiredSize=0"
                return 1
            fi
            return 0  # warn mode eats it
        fi

        echo "  Retry: scaling NG to 0, waiting ${delay}s, re-scaling to ${original_desired}"
        # Scale to 0
        aws eks update-nodegroup-config ... --scaling-config \
            "minSize=0,maxSize=1,desiredSize=0" >/dev/null
        # Wait for termination
        aws eks wait nodegroup-active --nodegroup-name "${ng_name}" ...
        sleep 30  # let ASG settle
        # Scale back
        aws eks update-nodegroup-config ... --scaling-config \
            "minSize=0,maxSize=${original_desired},desiredSize=${original_desired}" >/dev/null
        # Wait for new instances
        sleep "${delay}"
        aws eks wait nodegroup-active ... 2>/dev/null || true
        # Loop retry

        retries_left=$((retries_left - 1))
    done
}
```

## Test plan

1. **Unit**: shell functions with stubs for aws cli, verify retry count and early-exit on pass
2. **Offline**: parse a sequence of topology JSONs simulating 2 fails → 1 pass; verify correct behavior
3. **Real**: create NG with desired=2 in us-west-2c, observe whether retries actually flip leaves (AWS Spot scheduler may give same leaves repeatedly — this test itself is a data point on the AWS scheduler)

## Cost budget

Real test: 2x p5en spot × ~3 min per retry × (1 pass + up to 3 retries)
= ~24 min GPU = ~$18 max. Abort after 3 retries in test run to cap cost.

## Status tracking

P2 is deferred pending operator approval. P1 is sufficient for bench
pipelines that can accept manual retry. P2 is needed for fully
autonomous CI / scheduled benches.
