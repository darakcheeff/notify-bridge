package broker

import (
	"bytes"
	"encoding/json"
	"log"
	"strings"
	"sync"
	"time"

	"notification-bridge/backend/internal/db"
	"notification-bridge/backend/internal/models"

	mqtt "github.com/mochi-co/mqtt/v2"
	"github.com/mochi-co/mqtt/v2/hooks/auth"
	"github.com/mochi-co/mqtt/v2/listeners"
	"github.com/mochi-co/mqtt/v2/packets"
)

type Broker struct {
	server *mqtt.Server
	db     *db.DB
}

type BridgeHook struct {
	mqtt.HookBase
	db               *db.DB
	server           *mqtt.Server
	groupSubscribers map[string]int
	mu               sync.Mutex
}

func New(database *db.DB) *Broker {
	server := mqtt.New(nil)
	
	// Allow all connections (no password per specs)
	_ = server.AddHook(new(auth.AllowHook), nil)

	bh := &BridgeHook{
		db:               database,
		server:           server,
		groupSubscribers: make(map[string]int),
	}
	_ = server.AddHook(bh, nil)

	return &Broker{
		server: server,
		db:     database,
	}
}

func (b *Broker) Start(addr string) error {
	tcp := listeners.NewTCP("t1", addr, nil)
	if err := b.server.AddListener(tcp); err != nil {
		return err
	}
	log.Printf("MQTT Broker started on %s", addr)
	return b.server.Serve()
}

func (h *BridgeHook) ID() string {
	return "bridge-hook"
}

func (h *BridgeHook) Provides(b byte) bool {
	return bytes.Contains([]byte{
		mqtt.OnSubscribed,
		mqtt.OnUnsubscribed,
		mqtt.OnPublish,
	}, []byte{b})
}

func (h *BridgeHook) OnSubscribed(cl *mqtt.Client, pk packets.Packet, reasonCodes []byte) {
	for _, filter := range pk.Filters {
		parts := strings.Split(filter.Filter, "/")
		if len(parts) == 3 && parts[0] == "bridge" && parts[2] == "downstream" {
			guid := parts[1]
			h.mu.Lock()
			h.groupSubscribers[guid]++
			subs := h.groupSubscribers[guid]
			h.mu.Unlock()

			// Auto provision group on subscribe
			_ = h.db.AutoProvisionGroup(guid)

			// Delivery of persistent pending messages if leader reconnects
			if subs == 1 {
				go h.deliverPending(guid)
			}
		}
	}
}

func (h *BridgeHook) OnUnsubscribed(cl *mqtt.Client, pk packets.Packet) {
	for _, filter := range pk.Filters {
		parts := strings.Split(filter.Filter, "/")
		if len(parts) == 3 && parts[0] == "bridge" && parts[2] == "downstream" {
			guid := parts[1]
			h.mu.Lock()
			if h.groupSubscribers[guid] > 0 {
				h.groupSubscribers[guid]--
			}
			h.mu.Unlock()
		}
	}
}

func (h *BridgeHook) OnPublish(cl *mqtt.Client, pk packets.Packet) (packets.Packet, error) {
	parts := strings.Split(pk.TopicName, "/")
	if len(parts) == 3 && parts[0] == "bridge" && len(parts) > 2 && parts[2] == "upstream" {
		guid := parts[1]

		// Auto provision group
		_ = h.db.AutoProvisionGroup(guid)

		// Print notification log
		var packet models.Packet
		if err := json.Unmarshal(pk.Payload, &packet); err == nil {
			if packet.Type == "notification" {
				log.Printf("[GROUP %s] From %s: %s - %s\n", guid, packet.Metadata.DeviceName, packet.Data.AppPackage, packet.Data.Title)
			}
		} else {
			log.Printf("[GROUP %s] JSON Unmarshal error: %v | Raw: %s\n", guid, err, string(pk.Payload))
		}

		h.mu.Lock()
		subs := h.groupSubscribers[guid]
		h.mu.Unlock()

		// Change topic to downstream allowing Mochi to route natively
		pk.TopicName = "bridge/" + guid + "/downstream"

		// Offline Leader Queueing
		if subs == 0 {
			_ = h.db.SaveMessage(guid, pk.Payload)
		}
	}

	return pk, nil
}

func (h *BridgeHook) deliverPending(guid string) {
	time.Sleep(150 * time.Millisecond) // Let mochi wrap subscription internally

	msgs, err := h.db.GetPendingMessages(guid)
	if err != nil || len(msgs) == 0 {
		return
	}

	var deliveredIDs []int
	for _, msg := range msgs {
		downstreamTopic := "bridge/" + guid + "/downstream"
		err := h.server.Publish(downstreamTopic, []byte(msg.Payload), false, 1)
		if err == nil {
			deliveredIDs = append(deliveredIDs, msg.ID)
		} else {
			log.Printf("Failed to deliver queued message %d: %v", msg.ID, err)
		}
	}

	if len(deliveredIDs) > 0 {
		_ = h.db.MarkDelivered(deliveredIDs)
	}
}
