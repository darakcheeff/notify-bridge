# Database Schema

The backend uses SQLite to manage notification groups and an internal message queue to guarantee delivery (QoS 1).

## Tables

### `groups`
Used to track the existence and last activity of notification groups.

| Column | Type | Constraints | Description |
| :--- | :--- | :--- | :--- |
| `group_id` | TEXT | PRIMARY KEY | The GUID v4 identifier for the group. |
| `last_activity`| DATETIME | | Timestamp of the last interaction within the group. |

### `message_queue`
Used to persist messages temporarily while ensuring delivery to offline or disconnected clients.

| Column | Type | Constraints | Description |
| :--- | :--- | :--- | :--- |
| `id` | INTEGER | PRIMARY KEY AUTOINCREMENT | Unique ID for the stored message. |
| `group_id` | TEXT | | The target group's GUID. |
| `payload` | BLOB / TEXT| | The JSON notification payload. |
| `created_at` | TIMESTAMP | DEFAULT CURRENT_TIMESTAMP | When the message was added to the queue. |
| `is_delivered`| BOOLEAN | DEFAULT FALSE | Delivery success flag. |

## Indices
- An index on `group_id` in the `message_queue` table is required to swiftly query pending notifications for a reconnecting group or subscriber.

## Lifecycle Logic
1. **Queuing**: Upon receiving a message on the `upstream` topic, it is immediately recorded in the `message_queue`.
2. **Delivery**: The message is subsequently published to the `downstream` topic.
3. **Acknowledgment**: Once the MQTT broker acknowledges successful delivery (satisfying QoS 1), the corresponding message in the `message_queue` should be either deleted (to conserve disk space) or strictly flagged as `is_delivered = TRUE`.
