package models

// Packet represents the common envelope for all MQTT JSON payloads
// transitioning through the Notification Bridge.
type Packet struct {
	Type     string         `json:"type"`    // Action discriminator: "notification", "link_test"
	Version  int            `json:"version"` // Protocol version: e.g. 1
	Metadata PacketMetadata `json:"metadata"`
	Data     PacketData     `json:"data"`    // Type-specific operational payload
}

// PacketMetadata conveys origin telemetry and grouping variables.
type PacketMetadata struct {
	DeviceID   string `json:"device_id"`
	DeviceName string `json:"device_name"` // "Pixel 7 Pro"
	GUID       string `json:"guid"`        // Isolation Group ID
	Timestamp  int64  `json:"timestamp"`   // Unix timestamp in milliseconds
}

// PacketData contains specific details corresponding to the Type discriminant.
// Fields are marked omitempty since "link_test" usage may not supply them.
type PacketData struct {
	AppPackage string `json:"app_package,omitempty"` // Example: com.whatsapp
	Title      string `json:"title,omitempty"`
	Body       string `json:"body,omitempty"`
}
