# stickydisk

A named disk that survives from run to run, for [runners.io](https://www.runners.io)
runners. Up to five per job.

```yaml
- uses: runners-io/stickydisk@v1
  with:
    key: ${{ github.repository }}-npm
    path: ~/.npm
```

Each key is its own ext4 volume, scoped to the repository, billed on the blocks
you actually use at the sticky-disk rate and reclaimed after seven idle days. A
trusted successful run of the default branch keeps what the job wrote; any other
build reads what was last kept and writes nothing back.

The first time a key is used, the disk is attached from the next run of the job
(the step says so); the job continues without it. If a disk is refused or cannot
be attached the step says why and the job runs cold, unless
`fail-if-unavailable: true`. On any other runner the step does nothing.

Inputs and outputs are described in [`action.yml`](action.yml). The source of this
repository lives in runners.io's own repository and is published here.
