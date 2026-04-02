#!/bin/bash
GUID="test-guid-555"

echo "Subscribing (Device 2) to bridge/$GUID/downstream..."
mosquitto_sub -d -h localhost -p 1883 -t "bridge/$GUID/downstream" -q 1 -C 1 > /tmp/out.json 2>&1 &
SUB_PID=$!

sleep 1

echo "Publishing notification from Device 1 to bridge/$GUID/upstream..."
PAYLOAD='{"type":"notification","version":1,"metadata":{"device_id":"dev-001","device_name":"Device 1","guid":"'"$GUID"'","timestamp":1000},"data":{"app_package":"com.test","title":"Test","body":"Hello"}}'
mosquitto_pub -d -h localhost -p 1883 -t "bridge/$GUID/upstream" -q 1 -m "$PAYLOAD"

echo "Waiting for Device 2 to receive message..."
wait $SUB_PID
echo "Received JSON payload:"
cat /tmp/out.json
