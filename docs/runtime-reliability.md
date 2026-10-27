# Orbit runtime reliability update

## App unlock and immediate Classera saving
When app lock is disabled, AppSession starts unlocked synchronously and AppRootView never renders LockScreen for a disabled lock. This removes the first-frame flash without changing separate sensitive-action authorization.
With lock enabled, the existing five-minute monotonic session remains.

Classera subscription-mode choices and adding a disabled class save immediately through the existing revision-checked authorized PUT. The Save changes footer and extra Save confirmation are removed. Cancellation restores the saved selection; uncertain/conflicting writes perform GET recovery, never retry mutations. Name editing already saves immediately and remains separate.

## Gemini status synchronization
The live monitor currently contains12keys. Previous integrations truncated records and action IDs to10 at four layers: live reader, service adapter, native action validation and friendly display labels.
The reader now logs into the existing loopback monitor using Ubuntu-only credentials and reads its cached authenticated /api/status. It does not run check_auth per key during refresh. Epoch check times are normalized to ISO timestamps. Only safe generated key-N identifiers, generated friendly names, allowlisted states and check timestamps enter the owner API. No keys, masked keys, upstream names, notes, passwords or raw responses are returned.
Dynamic IDs are validated and numerically ordered (up to1000 bounded records). Manual actions require both a registered server callback and the current native capability. Existing30second server cache/action cooldown remains.

## PM2 logs
The server originally captured a static ID/name map at startup. PM2 IDs changed (e.g. Gemini is now4, Classera webhook15, Orbit13), so the map no longer matched.
Each log read now resolves the current PM2 list against explicit approved process names. Paths must be existing regular files under the registered PM2 log root; symlinks/external paths are rejected. Existing no-follow bounded-tail reads, redaction, owner authorization and safe failures remain. Other process names are not implicitly authorized. Docker logs remain separately unsupported.

## Template status
Legacy delivery snapshots contain no template name and cannot be backfilled from the current provider configuration. The UI must keep those records Not recorded.
No verified classera_class_ready sender, approved payload contract or Subscribe now callback was found during this update. Keep class-ready invitations disabled. Existing daily reports and verified-window plaintext are independent and remain available subject to their own controls. Do not hide the invitation warning or infer approval from webhook configuration.

## Deployment and tests
backend/install_runtime_readers.py applies only3known function changes to live server_control.py, checks expected source shapes, makes private backups, installs the safe runtime reader and updated service adapter, and does not copy live server credentials into GitHub. Reload only ios-server-control.
Backend tests use fake monitor HTTP and temporary log files. Live HTTPS checks verified12keys with12authentication timestamps, services latency0.89seconds and logs200 for Gemini Monitor/Classera webhook/Orbit, with unauthorized logs401. No log content or credentials were printed.
No real messages, Google key tests, schedule changes, template changes or provider mutations are performed.
