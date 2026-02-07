
cleanup_on_failure() {
    echo "Error: $1"
    scancel ${SLURM_JOB_ID}
    exit 1
}

mkdir -p $jobWorkspace
chmod +x $runScript

# Run aggregated test
echo "Starting aggregated test..."
srun "${srunArgs[@]}" --kill-on-bad-exit=1 \
    -N $totalNodes \
    --ntasks=$totalGpus \
    --ntasks-per-node=$gpusPerNode \
    $runScript &> $jobWorkspace/run.log

echo "Aggregated test completed successfully"
echo "Total runtime: $SECONDS seconds"
