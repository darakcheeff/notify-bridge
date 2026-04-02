# MQTT Protocol & Payload Specifications

All messages transmitted over MQTT within the Notification Bridge system are strictly JSON serialized.

## Packet Structure

Every JSON payload incorporates mandatory root definitions and metadata alongside dynamic operational data.

### Root Fields
- `type` (String): Discriminator for the event type. Acceptable values: `notification`, `link_test`.
- `version` (Integer): Protocol revision version (currently `1`).
- `metadata` (Object): Contains context relating to device origins and group boundaries.
  - `device_id` (String): A persistent arbitrary or hardware-based unique id of the initiating device.
  - `device_name` (String): The consumer-friendly designation of the client device (e.g. "Pixel 7").
  - `guid` (String): The common group UUID separating hubs.
  - `timestamp` (Integer): Unix timestamp (ms) recording event inception.
- `data` (Object): Supplementary event payload. Contains contextual keys depending on `type`.

### `notification` Data
Utilized exclusively when `type == "notification"`.
- `app_package` (String): Bundle identifier of the original app (e.g., `com.whatsapp`).
- `title` (String): The summary text of the pushed alert.
- `body` (String): Elongated paragraph contents of the alert.

### `link_test` Data
Utilized when `type == "link_test"`. Does not contain standardized parameters, can remain effectively empty depending on diagnostic implementations.

## Example Payload

```json
{
  "type": "notification",
  "version": 1,
  "metadata": {
    "device_id": "device-uuid-xxx",
    "device_name": "Pixel 7 Pro",
    "guid": "c71120f2-70b7-4a00-98d9-2efabbfbaf0f",
    "timestamp": 1712053806000
  },
  "data": {
    "app_package": "com.whatsapp",
    "title": "Incoming Message",
    "body": "Hello, world!"
  }
}
```
