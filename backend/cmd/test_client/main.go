package main

import (
	"encoding/json"
	"fmt"
	"log"
	"time"

	mqtt "github.com/eclipse/paho.mqtt.golang"
	"notification-bridge/backend/internal/models"
)

func main() {
	guid := "test-verify-groups-1"
	
	// Create Subscriber (Device 2)
	optsSub := mqtt.NewClientOptions().AddBroker("tcp://localhost:1883").SetClientID("device_2_sub")
	subClient := mqtt.NewClient(optsSub)
	if token := subClient.Connect(); token.Wait() && token.Error() != nil {
		log.Fatalf("Subscriber connect error: %v", token.Error())
	}
	defer subClient.Disconnect(250)

	msgChan := make(chan mqtt.Message, 1)

	downstreamTopic := "bridge/" + guid + "/downstream"
	if token := subClient.Subscribe(downstreamTopic, 1, func(client mqtt.Client, msg mqtt.Message) {
		msgChan <- msg
	}); token.Wait() && token.Error() != nil {
		log.Fatalf("Subscriber sub error: %v", token.Error())
	}
	fmt.Println("[SUCCESS] Step 1 & 2: Subscriber 'device_2' registered for group", guid)

	time.Sleep(500 * time.Millisecond)

	// Create Publisher (Device 1)
	optsPub := mqtt.NewClientOptions().AddBroker("tcp://localhost:1883").SetClientID("device_1_pub")
	pubClient := mqtt.NewClient(optsPub)
	if token := pubClient.Connect(); token.Wait() && token.Error() != nil {
		log.Fatalf("Publisher connect error: %v", token.Error())
	}
	defer pubClient.Disconnect(250)

	payload := models.Packet{
		Type:    "notification",
		Version: 1,
		Metadata: models.PacketMetadata{
			DeviceID:   "dev-1",
			DeviceName: "Phone_A",
			GUID:       guid,
			Timestamp:  time.Now().UnixMilli(),
		},
		Data: models.PacketData{
			AppPackage: "com.whatsapp",
			Title:      "Incoming Call",
			Body:       "Missed call from Test User",
		},
	}
	b, _ := json.Marshal(payload)
	upstreamTopic := "bridge/" + guid + "/upstream"
	fmt.Println("[STEP 3]    Device 1 sending notification to", upstreamTopic)

	if token := pubClient.Publish(upstreamTopic, 1, false, b); token.Wait() && token.Error() != nil {
		log.Fatalf("Publisher pub error: %v", token.Error())
	}

	select {
	case msg := <-msgChan:
		var received models.Packet
		_ = json.Unmarshal(msg.Payload(), &received)
		fmt.Printf("\n[SUCCESS] Step 4: Device 2 received mirrored packet from downstream:\n")
		fmt.Printf("   Device Name : %s\n", received.Metadata.DeviceName)
		fmt.Printf("   App Package : %s\n", received.Data.AppPackage)
		fmt.Printf("   Content     : %s - %s\n", received.Data.Title, received.Data.Body)
	case <-time.After(3 * time.Second):
		fmt.Println("[ERROR] Timeout! Device 2 did not receive the notification.")
	}
}
