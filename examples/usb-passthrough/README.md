# USB Passthrough Example

Boots a VM with `USBPassthrough`, attaches each USB device you grant it through Accessory Access, and checks that the guest enumerates it.

## Requirements

- macOS 27 and the macOS 27 SDK.
- A guest kernel built from `kernel/config-arm64` (`make -C ../../kernel`). The kernel from `make fetch-default-kernel` has no USB support.
- `bin/initfs.ext4` from `make init` at the repo root. The example builds against this checkout, so it needs a matching `vminitd`.
- An Apple Developer Program team and a provisioning profile (see below).
- A USB device to pass through.

## Signing Setup

Accessory Access requires the `com.apple.developer.accessory-access.usb` entitlement, which macOS only accepts when a provisioning profile allows it. Signed ad hoc or without a profile, the app is killed at launch. This is a one-time setup; a development profile lasts about a year.

1. **Find your signing identity and Team ID.**

   ```bash
   security find-identity -v -p codesigning
   security find-certificate -c "Apple Development: Your Name" -p | openssl x509 -noout -subject
   ```

   Use the Apple Development identity as `SIGN_IDENTITY`. The Team ID is the `OU` in the certificate's subject, which isn't always the value in parentheses in the identity name. If no identity is listed, create one in Xcode under Settings → Accounts → Manage Certificates.

2. **Register an App ID.** At [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/identifiers/list), add an explicit App ID with a bundle ID you control, such as `com.yourcompany.containerization.usb-passthrough`, and enable **Claim USB Accessory**.

3. **Register this Mac.** Under Devices, add this Mac's Provisioning UDID:

   ```bash
   system_profiler SPHardwareDataType | grep "Provisioning UDID"
   ```

4. **Create the profile.** Under Profiles, create a **macOS App Development** profile with the App ID, your certificate, and this Mac, then download it.

## Build and Run

```bash
make run SIGN_IDENTITY="Apple Development: Your Name (XXXXXXXXXX)" \
  PROVISIONING_PROFILE=path/to/profile.provisionprofile \
  TEAM_ID=YOURTEAMID BUNDLE_ID=com.yourcompany.containerization.usb-passthrough
```

This builds `bin/USBPassthrough.app`, embeds the profile, signs it with `usb-passthrough.entitlements` plus the identifier entitlements `TEAM_ID` adds, and runs the bundle's executable directly so output stays in the terminal. Override the guest paths with `KERNEL=...` and `INITFS=...`.

Once the VM is running, plug in a device and attach it to the app from the Accessory Access menu bar item. Output looks like this:

```
VM running. Boot log: /var/folders/.../usb-passthrough-example/boot.log
Accessory Access listener registered.
Attach a USB device to this app from the Accessory Access menu bar item. Ctrl-C to quit.
2341:0043: connected, attaching
2341:0043: attached as 8D1C...
  sysfs: /sys/bus/usb/devices/1-1 (Arduino Uno)
  node:  /dev/bus/usb/001/002
2341:0043: PASS, visible in guest
```

While attached, the device is unavailable to macOS. Detaching it from the menu bar item, or quitting with Ctrl-C, releases it.

## Troubleshooting

| What happens | Cause |
|---|---|
| `Killed: 9` at launch | The entitlement isn't allowed by an embedded profile: no profile, or one that doesn't match the signature |
| `Accessory Access refused this process` | The app was signed without the entitlement, e.g. `ENTITLEMENTS=../../signing/vz.entitlements` |
| `not found; build it with ...` | The kernel or initfs is missing |

To compare the signature with the profile:

```bash
make entitlements
security cms -D -i path/to/profile.provisionprofile | grep -A1 -E 'accessory-access|application-identifier'
log show --last 5m --predicate 'sender == "AppleMobileFileIntegrity" OR process == "amfid"'
```

The embedded entitlements must be allowed by the profile, and `com.apple.application-identifier` must match exactly.

## Notes

- `LinuxContainer` doesn't pass extensions to its VM, so this example uses `LinuxPod`.
- Accessory Access only works from an app that appears in the Dock, so the example runs as an app with a Dock icon.
