package main

import (
	"log"
	"os"
	"os/signal"
	"syscall"

	"notification-bridge/backend/internal/broker"
	"notification-bridge/backend/internal/db"
)

func main() {
	database, err := db.InitDB("bridge.db")
	if err != nil {
		log.Fatalf("Database initialization failed: %v", err)
	}
	defer database.Close()

	mqttBroker := broker.New(database)

	go func() {
		if err := mqttBroker.Start(":1883"); err != nil {
			log.Fatalf("Broker failed to start: %v", err)
		}
	}()

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
	<-sig
	log.Println("Shutting down Notification Bridge Server...")
}
