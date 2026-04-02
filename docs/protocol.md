# Notification Bridge Protocol

## Overview
Notification Bridge constitutes an MQTT-based system designed to transparently broadcast notifications between Android devices.
The server operates as a transparent hub processing messages, isolating device groups using a unique GUID v4. There is no password-based mechanism; security relies entirely on the secrecy of the shared GUID.

## Addressing & Routing

Devices within the same notification sharing group use the same `GUID`.
The transparent nature of the server means that it listens for any incoming payloads on the upstream track and blindly relays them onto the corresponding downstream track for the given GUID.

### MQTT Topics

1. **Upstream (Send to Server):**
   - Topic: `bridge/{GUID}/upstream`
   - **Role:** Devices publish notifications to this topic.
   - **Access:** Publish-only for devices (Subscribe-only for the server hub).

2. **Downstream (Receive from Server):**
   - Topic: `bridge/{GUID}/downstream`
   - **Role:** Devices receive notifications from this topic.
   - **Access:** Subscribe-only for devices (Publish-only for the server hub).

## Payload Format

All messages transmitted over MQTT should be formatted as JSON strings.

### Notification Message Example

```json
{
  "message_id": "c71120f2-70b7-4a00-98d9-2efabbfbaf0f",
  "sender_id": "device-uuid-xxx",
  "timestamp": 1712053806000,
  "notification": {
    "title": "Incoming Message",
    "text": "Hello, world!",
    "package_name": "com.whatsapp"
  }
}
```

### Flow of Execution
1. Sender device generates a notification.
2. Sender wraps it in JSON and publishes to `bridge/{GUID}/upstream`.
3. Server receives the JSON from `bridge/{GUID}/upstream`.
4. Server immediately publishes the exact same JSON configuration to `bridge/{GUID}/downstream`.
5. All devices subscribed to `bridge/{GUID}/downstream` within the same group (including or excluding the sender, subject to client logic) receive the payload.
