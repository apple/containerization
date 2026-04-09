# Single File Mounts

In Containerization, what is analogous to bind mounts goes over virtiofs. virtiofs can only
share directories, not individual files. To support mounting a single file from the host into
a container, Containerization shares the file's parent directory via virtiofs and then bind
mounts the specific file to its final destination inside the container.

## How it works

1. **Detection**: During mount preparation, each virtiofs mount source is stat'd. If it's a
   regular file (not a directory), it enters the single-file mount path. Symlinks are
   resolved to the real file first.

2. **Parent directory share**: The file's parent directory is shared via virtiofs into the
   guest VM. If multiple single-file mounts reference files in the same parent directory,
   only one virtiofs share is created.

3. **Guest holding mount**: After the VM starts, the parent directory share is mounted to a
   holding location in the guest.

4. **Bind mount**: When the container starts, a bind mount is created from
   the holding location to the requested destination path inside the container.

### Example

Mounting `/Users/dev/config/app.toml` to `/etc/app.toml` in the container:

```
Host:      /Users/dev/config/       (shared via virtiofs)
Guest VM:  /temporary/holding/spot/ (virtiofs mount of parent dir)
Container: /etc/app.toml            (bind mount of /temporary/holding/spot/app.toml)
```

## Trade-offs

Sharing the parent directory means that sibling files in that directory are visible to the
guest VM at the holding mount point under `/run`. The bind mount into the container only
exposes the specific file requested, but the full parent directory contents are accessible
from inside the VM itself. This is a deliberate trade-off for reliability. Prior attempts
at supporting single file mounts using temporary directories with hardlinks were fragile
across filesystem boundaries and with certain host filesystem configurations.

## Alternatives to single file mounts

If exposing the parent directory to the guest VM is not acceptable for your use case, you
can avoid single-file mounts entirely:

- **Mount the whole directory**: Instead of mounting a single file, mount the directory that
  contains it. This is functionally equivalent (the directory is shared either way) but makes
  the behavior explicit and gives the container access to the full directory at the
  destination path.

- **Stage files into a dedicated directory**: Copy the files you need into a dedicated
  directory on the host and mount that directory instead. This gives you full control
  over what is visible to the guest.
