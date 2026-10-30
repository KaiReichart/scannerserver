---
title: Driverless Scanning (eSCL / AirScan)
description: How scannerserver exposes the iX500 as a driverless eSCL scanner for macOS Image Capture, Windows, iOS, and sane-airscan.
type: guide
audience: operators and maintainers
status: current
---

# Driverless Scanning (eSCL / AirScan)

Scannerserver can present the ScanSnap iX500 as a driverless network scanner using eSCL, the
protocol Apple calls AirScan and Mopria calls Mopria Scan. Clients that speak eSCL find it through
Bonjour and scan without any vendor software:

- macOS Image Capture and Preview's **Import from Scanner**
- iOS and iPadOS apps that support network scanners
- Windows 10/11 **Add a printer or scanner**
- Linux through [`sane-airscan`](https://github.com/alexpevzner/sane-airscan) (`scanimage -L`, Simple Scan, etc.)

The feature is off by default and does not change the physical-button, web, or OCR behaviour.

## Enable It

```yaml
services:
  scannerserver:
    image: ghcr.io/jollyjinx/scannerserver:latest
    network_mode: host
    user: "1000:1000"
    environment:
      WEB_PORT: "80"
      SCAN_ESCL_ENABLED: "true"
    volumes:
      - ./scans:/scans
      # Lets avahi-publish-service reach the host's Avahi daemon over D-Bus.
      - /run/dbus/system_bus_socket:/run/dbus/system_bus_socket
```

The scanner must already be set up through **Network Setup**. Until it is, the eSCL status reports
`Stopped` and new scan jobs are refused with `503`.

| Variable | Default | Meaning |
| --- | --- | --- |
| `SCAN_ESCL_ENABLED` | `false` | Serve the `/eSCL` endpoints and advertise them |
| `SCAN_ESCL_BONJOUR_ENABLED` | `true` | Advertise `_uscan._tcp` through `avahi-publish-service` (only when eSCL is enabled) |
| `SCAN_ESCL_NAME` | `ScanSnap iX500` | Name clients display for the scanner |
| `SCAN_ESCL_UUID` | derived | Fixed device UUID. By default a stable UUID is derived from the name and host name, so clients keep recognising the same scanner across restarts |

### Bonjour / Avahi

Advertisement uses the same mechanism as OCR worker discovery: an `avahi-publish-service`
subprocess that needs a reachable Avahi daemon. Most Linux hosts, including Raspberry Pi OS, already
run `avahi-daemon`; mounting the host's D-Bus system socket as shown above lets the non-root
container publish through it. Run only one Avahi daemon per host network namespace, so leave
`SCAN_ENABLE_DISCOVERY_DAEMONS` off when the host already runs one.

The host's D-Bus daemon refuses connections from a UID it cannot find in the host's
`/etc/passwd`, which shows up in the log as `Failed to create client object: An unexpected D-Bus
error occurred`. Make sure the container's UID (the `user:` value, `1000` above) exists on the
host. Minimal hosts such as Proxmox LXCs often have only `root`; add a non-login system user:

```bash
useradd --system --uid 1000 --no-create-home --shell /usr/sbin/nologin scannerserver
```

Advertisement is best-effort: if Avahi is unavailable, the endpoints still work and a client can
be pointed at them manually. For sane-airscan, add to `/etc/sane.d/airscan.conf`:

```ini
[devices]
"ScanSnap iX500" = http://SCANNER_HOST/eSCL, escl
```

To verify the advertisement from a Mac, run `dns-sd -B _uscan._tcp`; from Linux,
`avahi-browse -rt _uscan._tcp`.

## What Clients Get

| Capability | Value |
| --- | --- |
| Input | Automatic document feeder only, simplex or duplex, 50-sheet capacity |
| Colour | `RGB24` |
| Resolution | 300 dpi |
| Formats | `image/jpeg` (one image per side, streamed) and `application/pdf` (one document per job) |

These match what the iX500's Wi-Fi acquisition actually produces. Requests for other colour modes,
resolutions, intents, or scan regions are accepted and served at these settings, because the
scanner does not offer them over this protocol. Requests for the flatbed (`Platen`) or for
unsupported formats such as PNG are rejected with `409 Conflict`.

Pages are returned as the scanner captured them. Blank-page removal, automatic cropping, and OCR
are not applied, and eSCL scans are not saved to the scan directory; the client decides where the
result goes.

## Behaviour

- **Single scanner, single job.** eSCL jobs use the same single-flight scan guard as web and
  physical-button scans. While any scan is running, `POST /eSCL/ScanJobs` returns `503` with
  `Retry-After: 5`, and the web UI shows the eSCL scan as running.
- **Physical button.** An eSCL scan hands off and then resumes the button session exactly like a web
  scan. Pressing the scanner's button still starts a normal scannerserver scan to `/scans`; eSCL is
  pull-only, so the button cannot push a scan to a Mac.
- **Streaming.** JPEG jobs return each side from `NextDocument` as soon as it is captured. PDF jobs
  return once the feeder is empty. `NextDocument` waits up to 120 seconds for the next page, then
  returns `503` with `Retry-After: 1` so the client polls again.
- **Empty feeder.** A job started with no paper is aborted, `NextDocument` returns `404`, and
  `ScannerStatus` reports `ScannerAdfEmpty` until the next job starts.
- **Cancellation.** `DELETE /eSCL/ScanJobs/{id}` stops an active acquisition. Deleting a finished
  job releases it.
- **Retention.** Pages the client never fetches are held in memory and discarded five minutes
  after the job ends. At most ten finished jobs are listed in `ScannerStatus`.

## Endpoints

| Method and path | Purpose |
| --- | --- |
| `GET /eSCL/ScannerCapabilities` | Capability document |
| `GET /eSCL/ScannerStatus` | Scanner state, ADF state, and recent jobs |
| `POST /eSCL/ScanJobs` | Start a job from a `ScanSettings` XML body; `201` with the job URL in `Location` |
| `GET /eSCL/ScanJobs/{id}/NextDocument` | Next image or document; `404` when the job has no more |
| `DELETE /eSCL/ScanJobs/{id}` | Cancel or release a job |

The endpoints are unauthenticated, like the rest of the LAN web interface.

## Implementation

- `ESCLScanService` (actor) owns eSCL jobs, buffered pages, and status. It starts each acquisition
  through `ScanJobActor.start(trigger: .escl, operation:)`, so the button lifecycle receives the
  same `started`/`finished` events as for web scans and prepares the acquisition session before
  the operation consumes it.
- The operation calls `ScanSnapWiFiAcquiring.acquire` with a page handler and builds its request
  with the same environment-derived factory as `NativeScanPipeline`.
- `registerESCLRoutes` is the Hummingbird adapter; `ESCLDocuments` renders the XML.
- `ESCLBonjourPublisher` owns the cancellable `avahi-publish-service` subprocess.

## Hardware Validation

1. Enable eSCL and confirm the log shows `Advertising eSCL scanner`.
2. On a Mac, run `dns-sd -B _uscan._tcp` and confirm the scanner appears; open Image Capture and
   select it.
3. Load ten sheets, choose duplex, and scan. Confirm 20 images arrive in order and the web UI shows
   the scan running and then done.
4. Press the physical button afterwards and confirm a normal scan to `/scans` starts without a
   container restart.
5. Start an eSCL scan with an empty feeder and confirm the client reports no paper, then load
   paper and confirm the next eSCL scan works.
6. On Linux with sane-airscan, run `scanimage -L`, then
   `scanimage --source "ADF Duplex" --format=jpeg --batch=page%d.jpg` and confirm every side is
   written.
