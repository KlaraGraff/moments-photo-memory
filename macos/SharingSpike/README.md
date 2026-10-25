# SharingSpike

This is a compile-only CloudKit API-shape spike for issue #14. It is a separate SwiftPM executable and is not included in the Moments Xcode project or app target.

It exercises the selected design's important shapes without contacting iCloud:

- create a custom `CKRecordZone` in the owner's private database;
- create a zone-wide `CKShare` with `publicPermission = .none`;
- accept `CKShare.Metadata` through `CKContainer.accept(_:)` (the async Swift name for the `acceptShareMetadata` SDK method);
- map `CKShare.Participant` user record IDs to the local `MemoryAuthor` labels; and
- construct a `CKSyncEngine.Configuration` for either the private or shared database and persisted engine state.

## What was not verified here

This Mac has no signing team, iCloud entitlements, configured CloudKit container, or second Apple ID. The spike therefore does not verify:

- that `iCloud.org.example.Moments` exists in a development or production environment;
- creation of the custom zone or saving records to CloudKit;
- adding exactly one private participant and generating a usable share URL;
- delivery of share metadata to a second macOS app instance;
- acceptance into the participant's shared database;
- push notifications, `CKSyncEngine` scheduling, account changes, or persisted state across relaunch;
- server-record-change conflict responses, asset upload/download, or record-zone change tokens; or
- the final entitlements, container environment, schema deployment, and native app delegate wiring.

## Manual two-account verification

1. Create a development CloudKit container named `iCloud.org.example.Moments` in the team's Apple Developer account. Enable iCloud/CloudKit and remote notifications for the macOS app target; keep the container identifier a placeholder until the team assigns the real one.
2. Run the owner build signed into Apple ID A. In the private database, save a custom zone named `moments-shared`, save a few synthetic `Trip`, `MediaItem`, and `Memory` records, create `CKShare(recordZoneID:)`, set `publicPermission` to `.none`, add Apple ID B as a private read-write participant, and save the share and records in one operation.
3. Deliver the returned share URL to Apple ID B through the system sharing UI or a test channel. Do not use a public share.
4. Run the participant build signed into Apple ID B. Handle the macOS app delegate share-metadata callback, call `CKContainer.accept(metadata)`, then configure a `CKSyncEngine` against `sharedCloudDatabase` and persist every state-update serialization.
5. Verify that the shared zone appears only in B's shared database, that B can add a memory whose author maps to B's CloudKit user record ID, and that A receives it through the private-database engine.
6. Turn off the network on each Mac in turn, create edits and favorites, restore connectivity, and verify the documented conflict rules and tombstone handling. Finally revoke B, confirm the shared zone disappears from B, and confirm that A's owner data and local originals remain intact.
