# NFS storage (`hexos-nfs`)

ReadWriteMany volumes on HexOS, for workloads where several pods read and
write the same files (media libraries and the like). `hexos-iscsi` stays the
cluster default for everything else. It's block storage, so it's faster for
single-pod databases and can't be shared between pods at all.

Deployed by [`../argocd/apps/democratic-csi-nfs/`](../argocd/apps/democratic-csi-nfs/application.yaml),
a second release of the same democratic-csi chart the iSCSI class uses
(`freenas-api-nfs` driver, CSI driver name `org.democratic-csi.nfs`). The
driver config lives in
[`../manifests/external-secrets-config/democratic-csi-nfs.yaml`](../manifests/external-secrets-config/democratic-csi-nfs.yaml).

There are two ways to use it:

- **Dynamic** (a new, empty volume): a PVC with `storageClassName: hexos-nfs`.
- **Static** (existing data on the NAS, such as `data/shared`): a
  hand-written PV plus a PVC bound to it. See below.

## Dynamic volumes

Each PVC gets its own ZFS dataset under `data/k8s-nfs` and its own NFS
export, both created through the TrueNAS API. In the HexOS UI, the dataset
description and the share comment both read `<namespace>/<pvc-name>`.

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: media
  namespace: example
spec:
  storageClassName: hexos-nfs
  accessModes: [ReadWriteMany]
  resources:
    requests:
      storage: 100Gi
```

How these volumes behave:

- **Size is a hard limit.** The requested size becomes the dataset's
  `refquota`, and `allowVolumeExpansion` is on, so to grow a volume, edit the
  PVC's request.
- **Any UID can write.** Exports use `maproot=root` (no root squash), and the
  dataset root starts out `0777 root:root`. A pod running as root, or as any
  other UID, can write. It can also chown files, and an init container can
  chown the volume to the app's user.
- **`fsGroup` works.** The CSIDriver sets `fsGroupPolicy: File`, so kubelet
  applies a pod's `fsGroup` to RWX volumes too. For large volumes, set
  `fsGroupChangePolicy: OnRootMismatch` so kubelet doesn't walk every file
  on each mount.
- **Deleting a PVC keeps the data.** The reclaim policy is `Retain`, like
  `hexos-iscsi`. The PV goes to `Released`, and the dataset and its export
  stay on HexOS until you delete them by hand (PV first, then the dataset
  in the HexOS UI, which also removes its share).
- **Exports are limited to the Server VLAN** (`192.168.102.0/24`), where
  every Talos node lives.
- **Mount options** (set on the StorageClass): `nfsvers=4.2`, `noatime`, and
  the same SELinux `context=` label `hexos-iscsi` uses. For why the label is
  needed, see [`../talos/README.md`](../talos/README.md) ("SELinux labels on
  iSCSI volumes"). The NFS class needed it from the start rather than as a
  later fix.

## Static PV for existing data (`data/shared`)

A dynamic volume always starts out empty. To give pods the files already on
`/mnt/data/shared` (the restored P3 Plus data, anything copied there by
hand), write a PV that points at the existing export and goes through the
same CSI driver:

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: hexos-shared-example        # one PV per consuming PVC
spec:
  capacity:
    storage: 1Ti                    # informational only; NFS doesn't enforce it
  accessModes: [ReadWriteMany]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""              # keeps dynamic provisioning out of it
  claimRef:                         # binds this PV to exactly one PVC
    namespace: example
    name: shared
  mountOptions:
    - nfsvers=4.2
    - noatime
    - context=system_u:object_r:ephemeral_t:s0
  csi:
    driver: org.democratic-csi.nfs
    volumeHandle: hexos-shared-example   # must be unique in the cluster
    fsType: nfs
    volumeAttributes:
      node_attach_driver: nfs
      server: 192.168.102.33
      share: /mnt/data/shared            # or a subdirectory of it
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: shared
  namespace: example
spec:
  storageClassName: ""
  volumeName: hexos-shared-example
  accessModes: [ReadWriteMany]
  resources:
    requests:
      storage: 1Ti
```

Put both in the consuming app's manifests. Because of `Retain`, pruning or
deleting them never touches the data. Nothing ever calls `DeleteVolume` for a
PV without a StorageClass.

Things to know about the `data/shared` export (it was created by hand, not
by democratic-csi, and its settings differ):

- **Root is squashed.** The export has no maproot, so a pod running as root
  reaches the NAS as `nobody`. Write access comes from the `shared` group
  (gid 3003): the existing folders are group-writable, setgid, and have a
  default ACL for that group. Give the pod `supplementalGroups: [3003]`,
  and ideally a non-root `runAsUser`.
- **Never set `fsGroup` on a pod that mounts this.** With
  `fsGroupPolicy: File`, kubelet would try to recursively chgrp the whole
  share (1.3 TiB, around 320k files) on every mount. Use
  `supplementalGroups` instead.
- **Mount read-only where you can.** Set `readOnly: true` on the pod's
  volume (or `csi.readOnly: true` on the PV) for apps that only read.
- **Keep the mount options identical** on every PV that points at
  `/mnt/data/shared` or a subdirectory of it. The Linux NFS client shares one
  superblock per export, and a second mount on the same node with a
  different `context=` fails with an "incompatible security settings" error.

## Verifying after a deploy

Run from rpi5-1:

```bash
kubectl -n democratic-csi get pods -l app.kubernetes.io/instance=democratic-csi-nfs
```

```bash
kubectl get csidriver org.democratic-csi.nfs && kubectl get sc hexos-nfs
```

For an end-to-end check:

1. Create a throwaway RWX PVC.
2. Run two pods on different workers that write to it. Each should see the
   other's file.
3. Confirm that `data/k8s-nfs/pvc-…` and its export exist on HexOS.
4. Mount a read-only static PV against `data/shared` and list its top-level
   folders.
5. Clean up. Before deleting the test PVC, patch its PV to
   `persistentVolumeReclaimPolicy: Delete`; the driver then removes the
   dataset and export itself, and the delete path gets tested too. Delete
   the static PV normally (with `Retain` and no StorageClass, nothing
   touches `data/shared`).

To test the quota, write incompressible data (`/dev/urandom`). Zeros
compress away on ZFS and never hit the refquota.

Last run 2026-09-25, all passing. The results are in
[`../todo/DONE.md`](../todo/DONE.md#hexos-storage).
